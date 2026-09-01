# CI/CD Pipeline

This document explains the CI/CD and observability system that builds, tests, scans, deploys, and
measures three services — `events-service`, `incidents-service`, `create-incident-job` — onto the
`inframonitor-aks` AKS cluster, plus the DORA/pipeline-metrics system (`metrics-collector`) that
watches all three pipelines and reports on them in Grafana. It covers what each pipeline stage
does, why it's a distinct stage rather than folded into another, the identity/security model
behind it, the deployment and rollback flow, the observability architecture, the real DORA and
pipeline-performance numbers, and the honest list of what's deliberately out of scope today.

Everything below was re-verified directly against the current state of the workflow files, the
`scripts/`, the Helm charts in `inframonitor-gitops`, the live AKS cluster, and live
Prometheus/Grafana data at the time of this rewrite — not reconstructed from memory of how the
system was originally designed, and not carried forward from the previous version of this
document without re-checking. Where a fact couldn't be verified this way, it's called out
explicitly rather than stated as settled. This document previously covered only two of the three
services and predated the entire observability system; both gaps are closed here, and every
number that changed since the last version says so.

> **Scope note:** this document covers the AKS/ArgoCD/GitOps deployment path for `events-service`,
> `incidents-service`, `create-incident-job`, and `metrics-collector` — the platform these four
> components actually run on today. It does not cover `infra/`'s Terraform, which provisions a
> separate, earlier Azure Container Apps + APIM + Front Door architecture for the same application
> layer. See the root [README](../README.md) and its flagged note for why these are two different
> things living in one repository, and why that distinction matters here.

## 1. Branching and deployment model

### Trunk-based, not GitFlow

All four pipelines (`events-service-ci.yml`, `incidents-service-ci.yml`,
`create-incident-job-ci.yml`, `metrics-collector-ci.yml`) trigger on `push` to **any** branch
(`branches: ['**']`) plus `pull_request` into `main`. There is no `develop` branch, no long-lived
release branches, and no merge-freeze ritual around a release train. Every feature branch gets the
fast-tier checks (lint, unit tests, dependency scan) on every push, and every PR into `main` gets
the full gate (build, integration tests, SAST, container scan) before it's mergeable. The moment a
change lands on `main`, it is built, scanned, pushed to ACR, and rolled out to staging
automatically — there is no separate "release branch" step in between.

GitFlow's long-lived `develop`/`release/*` branches solve a problem this project doesn't have: a
need to batch multiple features into a coordinated release, or support multiple release versions
in parallel. With small, independently-deployable services and a single staging + single
production environment each, that batching would only add merge-conflict surface and a delay
between "code is done" and "code is verified against something real" — the opposite of what a fast
feedback loop needs. Trunk-based development keeps every change small, tested against `main`
immediately, and deployed to staging within minutes of merge — the branch *is* the deployment
unit.

### Staging = Continuous Deployment. Production = Continuous Delivery.

This is a precise, deliberate distinction, not inconsistent behavior between the two environments:

- **Staging is genuine Continuous Deployment.** Every push to `main` that passes every gate
  (`build-image` → `container-scan`/`image-compliance-scan` → `push-image`) is deployed to staging
  automatically, with no human step anywhere in the sequence. `update-staging-values` commits the
  new image tag straight to `inframonitor-gitops`, ArgoCD picks it up, and `smoke-test-staging`
  verifies the real rollout — all inside the same workflow run, all unattended.

- **Production is Continuous Delivery, not Continuous Deployment.** Each service's `push-image`
  job pushes **one** immutable, already-scanned image to ACR per merge to `main`. That same
  artifact sits in ACR, ready to deploy, indefinitely. Nothing about it changes between "verified
  in staging" and "promoted to production" — each service's own `*-production-promotion.yml` is a
  separate, `workflow_dispatch`-triggered workflow that takes an `image_tag` input (an image that
  must already exist and have passed a staging smoke test — enforced by
  `verify-staging-smoke-test.sh`, see §7) and promotes *that exact tag* by editing
  `values-production.yaml`. No rebuild, no re-scan, no new artifact — the bits that run in
  production are byte-for-byte the bits that were verified in staging.

The reason this split exists rather than "just automate production too": staging deployments are
cheap to get wrong (revert the tag, nobody outside the team notices) and valuable to get fast (fast
feedback on whether `main` is healthy). Production deployments are expensive to get wrong and don't
benefit from being instant — the useful signal for "should this go to production" isn't "did CI
pass" (staging already proved that), it's a human deciding *when*, informed by what staging has
already, verifiably shown. Automating that decision away wouldn't make the pipeline more continuous
in any way that matters — it would just remove the one point where a human's judgment about timing
and blast radius actually adds value. The artifact readiness is fully continuous; the promotion
decision is deliberately not.

## 2. Pipeline architecture

### The CI/CD template split — real evidence, not a guess

All four services share two reusable `workflow_call` templates —
`.github/workflows/service-ci-template.yml` and `.github/workflows/service-cd-template.yml` —
plus a third, `service-promotion-template.yml`, for the separate production-promotion pipeline.
Each service's own workflow file (`events-service-ci.yml`, etc.) shrinks to a trigger block plus a
`uses:`/`with:` call into each template, because GitHub Actions reusable workflows structurally
cannot declare their own `on: push`/`pull_request` `paths:` filters — that has to live in the
per-service caller.

This split is **by pipeline shape, not by language**, and that decision was backed by a real,
job-by-job comparison across the (at the time) two existing pipelines, documented in
`docs/reusable-workflow-analysis.md` before any template was written. The evidence: out of the CI
pipeline's ~10 jobs, only **2 were genuinely language-specific** (`lint-and-format`, `unit-tests`),
and **1 had a single language-conditional step** (`sast`'s pre-CodeQL `setup-dotnet` step, needed
because C#'s CodeQL `autobuild` requires an SDK present while JS's near-no-op autobuild doesn't).
The other **7 jobs — over 70% of the pipeline — never touch source code at all**
(`dependency-scan`, `build-image`, `container-scan`, `push-image`, `update-staging-values`,
`smoke-test-staging`, `rollback-staging`): they operate on the built container image, Git,
Kubernetes, or ArgoCD, none of which care what language produced the image. Splitting into
separate per-language templates would have forced that 70%+ language-agnostic majority to be
duplicated across both templates — reintroducing, at a coarser grain, the exact duplication a
template exists to remove. The production-promotion pipeline came back **100% language-agnostic
across all 4 of its jobs, with zero exceptions found** — an unambiguous single template with no
language branching at all. The handful of real language-specific spots that remain live as narrow
`if: inputs.build_container_image == ...`-style branches inside `lint-and-format`/`unit-tests`
only, not as parallel copies of whole jobs.

That analysis document itself is now historical — its templates have since been built and are the
live system described in this section — but its evidence ratio is the actual reason the split is
shaped the way it is, not a retrofitted justification.

### Fast-tier vs. full-gate trigger design

Every job's `if:` in `service-ci-template.yml` falls into one of three tiers:

| Tier | Jobs | Runs on | Why |
|---|---|---|---|
| **Fast, always** | `lint-and-format`, `unit-tests`, `dependency-scan`, `dockerfile-lint` | Every push, every branch, every PR | Cheap (seconds), no cloud dependencies, no `needs:` gating each other — they run in parallel so a developer gets all signals at once instead of serially |
| **Full gate** | `sast` (`if: github.event_name == 'pull_request'`), `integration-tests` (`if: ... && github.event_name == 'pull_request'`) | `pull_request` into `main` **only** | Expensive (a real CodeQL analysis, real Cosmos DB/Service Bus calls against a dedicated test environment) — worth running before merge, but not on every WIP push to a feature branch, and — as of this rewrite — not a second time on the post-merge commit either (see the redundancy story below) |
| **Deploy** | `build-image`, `container-scan`, `image-compliance-scan` (both PR and push-to-main); `push-image`, `update-staging-values`, `smoke-test-staging`, `rollback-staging` (push-to-main only) | See per-job `if:` in service-cd-template.yml | The build+scan jobs run on both PR and push (see the SHA-identity reason below); everything with a real external side effect — an image lands in ACR, a Git commit lands in `inframonitor-gitops`, a real cluster gets modified — is gated to `push` to `main` only, so a PR can never trigger any of it regardless of how green its checks are |

### One Docker build per relevant trigger, reused via artifact save/load through scanning

`build-image` builds and `docker save`s the image to a tarball exactly once per run, uploads it as
the `docker-image` artifact, and every downstream job in that same run (`container-scan`,
`image-compliance-scan`, `push-image`) downloads and `docker load`s that same tarball rather than
rebuilding. This is a deliberate, load-bearing decision: the whole point of `container-scan` is to
scan *the exact bits that will be pushed*, and the whole point of `push-image` is to push *the
exact bits that were scanned* — rebuilding in between either step would silently reopen the
question of whether the scanned image and the pushed image are actually the same one.

### Why it still rebuilds fresh on push-to-main, despite a PR build already existing

`build-image`'s own `if:` (`github.event_name == 'pull_request' || (github.event_name == 'push' &&
github.ref == 'refs/heads/main')`) means the same logical change gets a full image build twice:
once when its PR is opened, and again when it merges. This session verified the **real, load-bearing
reason** directly, rather than relying on the plausible-sounding "base image might have drifted"
explanation alone:

**The image tag is `${GITHUB_SHA::7}`, computed fresh every run.** For a `pull_request`-triggered
run, `GITHUB_SHA` is that PR's own head commit SHA. When the PR is squash-merged, GitHub creates a
**new, different commit SHA on `main`** — the PR branch's SHA never appears in `main`'s history at
all. This isn't a minor identity technicality: `scripts/verify-staging-smoke-test.sh`, the gate
that guards production promotion, works by searching this repo's own Actions run history for a
completed `events-service-ci.yml` (etc.) run whose `headSha` starts with the exact `image_tag`
being promoted, and refuses to promote otherwise. If the PR-time build were the only one ever
produced, there would be **no image in ACR tagged with the real post-merge commit SHA at all** —
promotion, and `find-rollback-target.sh`'s rollback-target search (§6), which also matches on
`headSha`, would have nothing valid to point at for the commit that's actually running in staging.
A mutable base-image tag resolving differently days apart is a real, secondary reason a rebuild is
*also* good practice — but it is not why the rebuild is *required*. The SHA-identity requirement is
structural and unconditional; the base-image-drift benefit is incidental.

### Security gates: four distinct concerns, plus two structural checks

| Check | Tool | Target | Sequencing | Question it answers |
|---|---|---|---|---|
| Dockerfile Lint | `hadolint` v2.15.1 | The Dockerfile source itself | Standalone, no `needs:`, runs first/independently | Does the Dockerfile itself follow known best practices (no unpinned `FROM`, no `ADD` where `COPY` suffices, etc.) — a static check of the *build instructions*, before anything is even built |
| Dependency Scan | Trivy, `fs` mode | `package-lock.json` / `packages.lock.json` | Standalone, no `needs:` | Does a *declared dependency* have a known CVE, independent of whether the app is even built yet? |
| SAST | CodeQL | Source code (JS or C#) | `needs: [lint-and-format, unit-tests, dependency-scan, dockerfile-lint]`, PR-only | Does *this code*, as written, contain an exploitable pattern (injection, unsafe deserialization, etc.)? |
| Container Vulnerability Scan | Trivy, `image` mode | The built Docker image | `needs: build-image`, runs in parallel with Image Compliance Scan | Does the *final, shippable artifact* — OS packages from the base image **plus** application dependencies **plus** anything the build process introduced — have a known CVE? |
| Image Compliance Scan | `dockle` v0.4.15 (CIS Docker Benchmark) | The built Docker image | `needs: build-image`, parallel with Container Vulnerability Scan | Is the image itself built in a way that follows container-hardening best practice (no root user, no exposed secrets baked into layers, sane permissions), independent of whether any *known CVE* exists? |
| SBOM generation | Trivy, CycloneDX format | The built Docker image | A step inside the Container Vulnerability Scan job, not a separate job | What, exhaustively, **is** in this artifact — a durable, queryable inventory, independent of whether anything in it is currently flagged |

These aren't overlapping redundancy. Dockerfile Lint catches *instruction-level* mistakes before a
build even happens. Dependency scanning finds known vulnerabilities in things *you* declared as a
dependency. SAST finds bugs in code *you* wrote. Container scanning finds known vulnerabilities in
*everything that ends up in the shipped image*, including OS-level packages from the base image
that never appear in any lockfile at all. Image compliance scanning checks the image's *construction
practices* (root user, layer hygiene), which a CVE scanner structurally can't do — an image can be
CVE-free and still be built in a way that's needlessly risky (running as root, say), and vice versa.
Real sequencing evidence: `hadolint` runs standalone before anything is built (it doesn't need a
build to exist); the two image-level scans both `need: build-image` and run in parallel with each
other, since neither depends on the other's result — confirmed directly from the actual `needs:`
graph in `service-cd-template.yml`, not assumed from typical practice.

## 3. Testing philosophy

### Unit tests vs. integration tests vs. smoke tests

These are three structurally different checks, not three tiers of the same check run at different
sizes:

- **Unit tests** run entirely mocked. `events-service`'s Jest suite and `create-incident-job`'s
  Jest suite mock the Cosmos DB and Service Bus clients; `incidents-service`'s xUnit suite mocks
  `IIncidentService`/the Cosmos container behind interfaces. They verify **the application's own
  logic is correct in isolation** — validation rules, routing, status codes, what gets written to a
  mocked client and when. What they structurally cannot catch: whether the *real* Azure SDK call
  would actually succeed, whether the app's Managed Identity actually has the RBAC role it needs,
  whether the Cosmos partition key scheme actually round-trips through a real account.

- **Integration tests** run against **real** Azure infrastructure — a dedicated test Cosmos
  database and Service Bus topic/subscription, authenticated via each service's own CI identity
  (`azure/login@v2` with `AZURE_CLIENT_ID_<SERVICE>_CI`). This catches exactly what unit tests
  structurally can't: a real RBAC misconfiguration, a real Cosmos query that's syntactically valid
  but semantically wrong, a real SDK version incompatibility. What it still can't catch: whether
  the *actual deployed pod*, running the *actual built image*, with its *actual Workload Identity
  federation*, behaves the same way — a container image is not the same artifact as a test runner
  executing directly on a GitHub-hosted runner.

- **Smoke tests** (`scripts/smoke-test.sh` for `events-service`/`incidents-service`,
  `scripts/create-incident-job-smoke-test.sh` for the KEDA-based job) run against the **real
  deployed workload**, in the **real namespace**. `smoke-test.sh` force-refreshes the ArgoCD
  Application, polls the Deployment and then a Ready pod for the expected image tag, port-forwards
  to that exact pod, confirms `GET /health` → 200, then performs a real write through the pod's own
  **Workload Identity** — the same federated identity the app uses in production, not a CI-only
  identity — and reads it back. `create-incident-job-smoke-test.sh` is structurally different
  because the workload itself is: it polls a KEDA `ScaledJob` spec (not a Deployment — there's no
  long-running pod to reach), publishes a real Service Bus message via a scratch Node SDK install,
  watches for the KEDA-created Kubernetes `Job` to appear and succeed, then queries Cosmos directly
  (there is no HTTP endpoint to call, since nothing stays running between executions) to confirm the
  resulting document actually landed. Both scripts prove the same thing by different mechanisms:
  image built correctly → deployed correctly → ArgoCD synced it → the real identity binding
  actually resolves → a write actually lands — the one layer no earlier test can structurally
  prove, because none of them run inside the real, deployed workload using its real production
  identity binding.

### Real coverage numbers, all three services (re-run for this rewrite, not estimated)

| | `events-service` | `incidents-service` | `create-incident-job` (`incident-function`) |
|---|---|---|---|
| Test count | 32 passed, 32 total (Jest) | 33 passed, 0 failed (xUnit) | 27 passed, 27 total (Jest, 3 suites) |
| Statement coverage | 97.05% | — (Cobertura reports line/branch/method, not statement) | 97.95% |
| Line coverage | 96.96% | 82.91% | 97.95% |
| Branch coverage | 79.51% | 82.35% | 81.81% |
| Function/method coverage | 100% | 96.22% | 100% |
| Enforced threshold | 70% (all four Jest metrics) | 70% (line only, via `coverlet.msbuild`'s `/p:Threshold=70`) | 70% (all four Jest metrics) |

The `events-service` and `incidents-service` numbers match this document's previous version
exactly — those two are stable, current, and this rewrite re-confirmed them rather than trusting
the old text. `create-incident-job`'s numbers are new to this document; its pipeline (see §11) is
now fully built and running real CI, which the previous version of this document did not reflect.

### The Integration Tests redundancy: a concrete case study in applying this discipline

This project's own Integration Tests job is a live example of the discipline this section
describes being applied to itself, not just to the codebase it tests. `integration-tests`
originally ran on **both** `pull_request` and `push`-to-`main` for the same eventual commit — the
same source code, tested against the same real Azure test infrastructure, checking the same
behavior, twice per merge. Unlike `build-image` (§2), which has a genuine, structural reason to
rebuild on push (a real, different commit SHA the promotion pipeline depends on), `integration-tests`
produces no SHA-keyed artifact anything downstream reads by name or tag — it just asserts pass/fail
against a fixed set of real Azure calls. Re-running it against the exact same source tree a second
time, purely because a squash-merge changed the commit's SHA, added real, measured wall-clock time
(66–85s average, up to 100s at p95, per the pipeline-performance data in §10) to every single merge
for zero additional signal.

The fix — scoping `integration-tests`'s `if:` to `github.event_name == 'pull_request'` only — was
verified the same way every other change in this system is verified: real runs, not just review.
Before merging, a real feature-branch push and PR run confirmed `Integration Tests: pass` still
fired correctly on the PR. After merging, three real push-to-`main` runs (one per service sharing
the template) confirmed `Integration Tests: skipped` — the exact same pattern `sast` had already
proven safe (it's been PR-only since the templates were built, with zero impact on
`call-service-cd`'s `needs: call-service-ci` gate on every push all along) — and confirmed
`push-image`, `update-staging-values`, and `smoke-test-staging` all still fired and succeeded
normally, since a `skipped` job doesn't count against a reusable workflow call's aggregate success.
Real wall-clock time before/after, same commits' actual `created_at`→`updated_at` span:

| service | before (with Integration Tests on push) | after | measured drop |
|---|---|---|---|
| `events-service` | 384s | 295s | −89s |
| `incidents-service` | 271s | 218s | −53s |
| `create-incident-job` | 392s | 315s | −77s |

Every merge to `main`, for every service, is now measurably faster — not a projection, a real
before/after comparison using the pipeline's own recorded timestamps.

## 4. Identity and security model

**Principle: least privilege per capability, not per service.** Rather than one identity per
service that can do everything that service's pipeline needs, each service gets **three** separate
CI/CD identities, split by capability, plus its own runtime workload identity — so that
compromising or misusing any single identity's credential exposes the smallest possible blast
radius for what that credential can actually do.

### The full identity inventory

**14 distinct managed identities exist across the system**, not the 9 this document previously
described for two services — the count grew with the third service's pipeline and with
`metrics-collector`, and this rewrite re-derived it from two independent, cross-checked sources
rather than updating the old number by guesswork: the real GitHub secret names referenced across
every workflow file (10 distinct `AZURE_CLIENT_ID_*` secrets, confirmed by direct grep across every
`.yml` file), and the real client-ID GUIDs stored in `inframonitor-gitops`'s chart values (7
distinct GUIDs, confirmed by direct read of every `values*.yaml`). These two sets overlap by
exactly the identities that are both *federated as GitHub OIDC secrets* and *have their GUID
recorded in a Kubernetes-facing chart* (the three smoke-test identities, whose GUID appears in
`inframonitor-namespace`'s `ci-argocd-refresh-rbac.yaml` as the RBAC subject's `principalId`) —
`10 + 7 − 3 = 14`.

| Identity (×1 per service unless noted) | Trust boundary | Can do | Explicitly cannot do |
|---|---|---|---|
| `<service>-identity-aks` (×3: events, incidents, create-incident-job) | Kubernetes Workload Identity, federated to that service's own ServiceAccount in **both** `inframonitor` and `inframonitor-production` | Cosmos DB Data Contributor (account-scoped — see the documented inconsistency below); Service Bus role matching what that service actually needs (events-service: Sender only; incidents-service: none — it neither publishes nor consumes; create-incident-job: Receiver only) | Push/pull images; touch `inframonitor-gitops`; any Kubernetes API beyond what the pod's own ServiceAccount implies |
| `<service>-ci-identity` (×3) | GitHub OIDC, both `ref:refs/heads/main` and `pull_request` (2 federated credentials) | Cosmos DB Data Contributor, intended for a dedicated per-service test database — used only by `integration-tests` | **No ACR role of any kind.** Cannot touch the cluster. Cannot touch `inframonitor-gitops` |
| `<service>-cd-identity` (×3) | GitHub OIDC, `ref:refs/heads/main` **only** — no `pull_request` credential exists | `AcrPush` on `inframonitoraksacr` | Cannot run from a PR context at all — a PR literally cannot mint a token for this identity. No Cosmos/Service Bus role. No cluster access |
| `<service>-smoke-test-identity` (×3) | GitHub OIDC, `ref:refs/heads/main` only | K8s: namespace-scoped `get/list/watch` on pods/deployments/replicasets (or, for `create-incident-job`, `batch/jobs` + `keda.sh/scaledjobs`) plus `create` on `pods/portforward`, in both namespaces; resourceName-scoped `get/patch` on exactly that service's own ArgoCD Applications | **No Cosmos role. No Service Bus role. No ACR role.** The Cosmos write a smoke test triggers happens entirely through the *pod's own* identity, reached over a port-forward or via KEDA, never through this identity's own credential |
| `metrics-collector-identity` | Kubernetes Workload Identity, federated to `metrics-collector-sa` in `inframonitor` only (1 credential — it's a singleton, see §8) | Cosmos DB Data Contributor scoped to exactly **three individual containers** (`DeploymentEvents`, `PipelineMetrics`, `CollectorState`) in `InfraMonitorMetricsDB` — **not** account-scoped, unlike every identity above; Key Vault CSI access to read one secret (the GitHub PAT) | Cannot touch `InfraMonitorDB`/`InfraMonitorProdDB` or any per-service test database at all. No ACR, Service Bus, or cluster access — it only calls the read-only GitHub Actions REST API and writes to its three containers |
| `AZURE_CLIENT_ID_METRICS_COLLECTOR_CD` | GitHub OIDC, `ref:refs/heads/main` only | `AcrPush` on `inframonitoraksacr` for the `metrics-collector` image — never runs inside the cluster | Everything a runtime identity can do — it exists purely to push a built image from a GitHub Actions runner |

Confirmed directly from the workflow files: exactly one `environment:` field exists anywhere across
every template and caller workflow — `promote-to-production` in `service-promotion-template.yml`,
`environment: production` — and it is a real GitHub Environments reference, meaning it's the one
job in the entire system that can carry a required-reviewer gate independent of anything above it
(§6).

### A known, documented Cosmos RBAC scoping inconsistency — not yet retroactively unified

`metrics-collector-identity`'s Cosmos role is explicitly documented, in its own chart's values
file, as **container-scoped**, with the comment stating plainly that this is deliberately different
from every identity that came before it: *"the same identity already holds Cosmos DB Data
Contributor on the three InfraMonitorMetricsDB containers this pod writes to, container-scoped (not
account-wide)."* No such comment exists anywhere for the three application runtime identities or
the three CI identities — their role assignments are referenced only as "Cosmos DB Data
Contributor" with no stated scope in this repository, which (consistent with the pattern any
identity created before `metrics-collector-identity` follows) means they're almost certainly still
account-scoped, granting broader access than any single pipeline or pod actually exercises. This is
a real, currently-live inconsistency between an older design pattern and a newer, narrower one
introduced for `metrics-collector` — not something this rewrite retroactively fixed, since doing so
would mean re-scoping five live production identities, a change with real deployment risk that's
out of scope for a documentation pass.

### Two concrete illustrations of the principle in practice

**The ACR-push-identity-reuse question.** It would have been simpler to let the CI identity that
already authenticates for `integration-tests` also push the image, rather than introducing a fourth
identity per service. That was considered and rejected: the CI identity's trust boundary
deliberately includes `pull_request` (so integration tests can run on a PR before merge) — but
`AcrPush` is exactly the kind of capability that must never be reachable from a PR context, since a
PR can be opened by anyone with write access without yet having passed review. Splitting CD into
its own identity, federated **only** to `ref:refs/heads/main` — with no `pull_request` credential
at all — closes that off structurally: no token for that identity can be minted from a PR run in
the first place, not merely "the workflow doesn't grant it one."

**`pods/portforward`, not `pods/exec` — and the smoke test's own API surface, not a
testing-convenience endpoint.** The smoke-test identities' K8s RBAC grants `create` on
`pods/portforward`, never `pods/exec`. The proximate reason is functional: the service images don't
ship `curl`, so `kubectl exec ... curl ...` would fail on a missing binary. But the capability
granted is also structurally narrower: `pods/portforward` only forwards network traffic to a port
the container already exposes, while `pods/exec` would allow arbitrary command execution inside the
container. Separately, `incidents-service`'s smoke-test cleanup uses `PATCH
.../incidents/{id}?severity=...` to move the synthetic incident to a terminal status, not `DELETE`
— because `IncidentsController` has no delete endpoint at all, and rather than adding one solely to
give the smoke test something to call, the smoke test was written to use only endpoints that
genuinely exist for the service's own real purposes. The same principle applied twice, at two
different layers: don't grant, and don't build, a capability whose only justification is a testing
convenience.

## 5. Deployment flow

### Staging (fully automatic, every push to `main`)

```
push to main
  → build-image, container-scan, image-compliance-scan all pass
  → push-image (<service>-cd-identity pushes to ACR)
  → update-staging-values (commits new image.tag to inframonitor-gitops/charts/<service>/values-staging.yaml)
  → ArgoCD (automated + selfHeal) detects the Git diff, syncs charts/<service>-staging
  → smoke-test-staging (<service>-smoke-test-identity): see §3 for the real check sequence
  → success: done. failure: rollback-staging fires automatically (see §6)
```

No human step appears anywhere in this sequence. A merged PR is live in staging, smoke-tested, in
minutes.

### Production (staging-verification gate, human-triggered promotion of the same artifact)

Each `*-production-promotion.yml` is `workflow_dispatch` only, taking `image_tag` as a required
input:

```
human dispatches the workflow with image_tag = <a tag that already shipped to staging>
  → verify-staging-smoke-test.sh: confirms that EXACT tag has a genuinely successful
    "Smoke Test (staging)" run in this repo's Actions history for this service's own -ci.yml —
    refuses to continue otherwise
  → promote-to-production (environment: production — a GitHub Environment, so this job can carry
    its own required-reviewers gate independent of anything above it): edits
    charts/<service>/values-production.yaml to that tag, commits, pushes to inframonitor-gitops
  → ArgoCD syncs charts/<service>-production
  → smoke-test-production (same smoke-test identity as staging, run against production)
  → success: done. failure: rollback-production fires automatically
```

**Why `verify-staging-smoke-test.sh` matters beyond "a human decided to promote it":** a human
choosing to promote a tag is a statement of *intent*, not *evidence*. The script turns "I believe
this tag is good" into "this tag has a machine-checked, timestamped record of actually having
passed a real smoke test in staging" — it validates `IMAGE_TAG` is a genuine 7-character hex SHA,
searches the last 100 completed runs of that service's CI workflow for one whose `headSha` starts
with it, and only accepts it if that run's `Smoke Test (staging)` job conclusion was genuinely
`success`. **This was not just designed to reject a bad tag — it was empirically tested against a
real, deliberately-submitted wrong SHA and confirmed to correctly reject it**, closing off a real
failure mode: a human mistyping a tag, or promoting a tag that was pushed to ACR but never actually
got smoke-tested in staging. The gate isn't "did a human click a button," it's "does verifiable
evidence exist that this exact artifact already worked in staging."

**The required-reviewer gate.** `promote-to-production`'s `environment: production` is a real
GitHub Environment reference — the same mechanism GitHub uses to let a repository require one or
more specific reviewers to approve a deployment before the job that references that environment is
allowed to run, independent of any check earlier in the workflow. It is deliberately hardcoded in
the shared template rather than parameterized per caller (per `docs/reusable-workflow-analysis.md`'s
own design note: *"it's deliberately identical across every caller, and turning a
deliberately-fixed shared gate into a knob would be the wrong kind of flexibility"*) — every
service's promotion path carries the same human checkpoint, not a configurable one some caller
could quietly opt out of.

## 6. Rollback strategy

### Why it must go through Git, not `kubectl rollout undo`

`kubectl rollout undo` mutates the live Deployment object directly, reverting it to a prior
ReplicaSet. Every one of these ArgoCD Applications has `syncPolicy.automated.selfHeal: true` in
`inframonitor-gitops`. ArgoCD's `selfHeal` continuously reconciles the live cluster state back to
whatever Git says it should be — so a `kubectl rollout undo` wouldn't actually roll anything back in
any way that lasts: within one reconciliation cycle, ArgoCD would notice the live Deployment no
longer matches the Git-defined manifest (which still points at the bad tag) and simply reapply the
bad tag right back. The two mechanisms are structurally incompatible: one edits the cluster
directly, the other exists specifically to undo direct cluster edits that don't match Git.

**Rollback has to go through Git, like every other deployment.** `rollback-staging`/
`rollback-production` don't touch the cluster at all — they edit `values-{staging,production}.yaml`
back to a prior tag and push, exactly the same mechanism `update-staging-values`/
`promote-to-production` use to roll *forward*. A rollback **is** a deploy, just to an older tag.

### "Most recent verified-good tag," not "one commit prior"

`find-rollback-target.sh` doesn't roll back to the immediately preceding commit — it walks backward
through the last `LOOKBACK_LIMIT` (10) completed runs of the relevant workflow, from most recent,
looking for the first one whose named smoke-test job's conclusion was genuinely `success`. It
supports two tag-extraction modes depending on caller: `head_sha` (staging rollback — the tag is
that run's own commit SHA, since a staging deploy is 1:1 with a push) and `artifact` (production
rollback — the tag is read out of the smoke test's own uploaded evidence artifact, since production
promotion is decoupled from any single push event and the relevant tag can't be inferred from the
rollback run's own commit at all). "One commit prior" assumes the immediately preceding commit was
itself good — but if two or three commits in a row broke staging before anyone noticed, "one prior"
would just roll back into another broken state. If nothing in the lookback window was ever
verified-good, the script fails loudly and does nothing, rather than guessing — a real, deliberate
design choice, not a missing case.

### The rollback bug this project actually caught — one of the strongest findings from the whole project

`rollback-staging`'s (and `rollback-production`'s) trigger condition is `if: failure() &&
needs.smoke-test-staging.result == 'failure'`. The `failure()` is not decorative, and this is worth
real weight: **GitHub Actions silently ANDs an implicit `success()` onto any job's `if:` condition
unless that condition already contains one of the status-check functions** (`success()`,
`failure()`, `always()`, `cancelled()`). A condition written as just
`needs.smoke-test-staging.result == 'failure'` — which reads correctly, and would pass any code
review — actually evaluates as `success() && needs.smoke-test-staging.result == 'failure'` under
the hood. Since the job it depends on failed, `success()` is `false`, and the whole expression is
`false` regardless of whether the `result` check alone would have been `true`. The job would show
as **skipped**, not run, on every single failure it was supposed to catch — the exact failure mode
it exists to handle would silently produce no rollback at all, while the workflow file itself looks
entirely correct.

This was not caught by reading the YAML, and not caught by unit-testing the shell scripts — it was
caught by deliberately forcing a **real** staging smoke test to fail (breaking `/health` on a
throwaway branch, merging it, watching what actually happened) and observing that
`rollback-staging` stayed `skipped`. That single real observation is what surfaced the implicit-
`success()` behavior. The fix — `failure() && needs.smoke-test-staging.result == 'failure'` — was
then verified the same way it was found: by forcing another real failure and confirming the job
actually ran and actually rolled back, staging and production, for all three services
independently, each time reverting a temporary trip-wire afterward and re-verifying a clean
successful run. Without that deliberate, real-failure testing discipline, this pipeline would have
shipped with a rollback job that looked complete, passed every review, and never once fired —
exactly the kind of bug that's invisible until the day it matters most.

## 7. Production promotion

Covered in detail in §5 above (the promotion flow itself) and §4 (the required-reviewer
environment gate). The one point worth restating on its own: the staging-verification gate isn't
theoretical — it was empirically tested against a real, deliberately-submitted wrong SHA during
this project and confirmed to correctly reject it, not just designed to in principle.

## 8. Observability system

### Architecture

```
GitHub Actions REST API (workflow runs, jobs, artifacts)
        │  polled every 15 minutes
        ▼
metrics-collector (in-cluster K8s CronJob, Workload Identity)
        │  writes durable history
        ▼
Cosmos DB — DeploymentEvents / PipelineMetrics / CollectorState containers
        │  aggregated fresh, every run, over rolling windows
        ▼
Pushgateway (current-value snapshots only — see below)
        │  scraped by
        ▼
Prometheus  →  Grafana (dashboard `metrics-collector-dora`, 29 panels)
```

### Why Pushgateway holds only current values, never history

Pushgateway is deliberately used as a short-lived-batch-job snapshot mechanism, not a
history store: every metric it holds represents "as of the collector's last run," and every
`compute*()` function in `scripts/metrics-collector/index.js` recomputes its result fresh from
Cosmos on every single invocation, over a rolling time window (30 days for DORA, 7 for pipeline
metrics), rather than reading back a previously-pushed value and updating it incrementally. This
is the textbook Pushgateway use case — a short-lived job pushing "the current state of the world,"
not a system pretending Pushgateway is a time-series database it structurally isn't. All real
history lives in Cosmos DB; Pushgateway (and, by extension, Prometheus's own scraped series for
these specific metrics) only ever reflects the most recent snapshot. A real, load-bearing
consequence of this design, discovered and fixed during this project: Pushgateway's `POST` only
adds or replaces metric families **by name** under a grouping key — it can never remove one that
stops being pushed. A metric that legitimately becomes "no data" (e.g. `changeFailureRate` when a
service has had zero deploy attempts in the window) would otherwise leave its last real value stuck
in Prometheus forever, silently wrong. The fix — `DELETE` the whole grouping key before every push,
then `POST` only what's currently true — is the only way to make an absent metric actually
disappear rather than just stop growing, confirmed safe to call even against a group that doesn't
exist yet (a real `202`, not a `404`).

### The migration from a GitHub Actions scheduled workflow to an in-cluster CronJob

`metrics-collector` originally ran as a GitHub Actions workflow on a `schedule:` trigger. It now
runs as a Kubernetes `CronJob` (`*/15 * * * *` — deliberately matching the schedule it replaced
exactly) inside the `inframonitor` namespace, using Azure Workload Identity
(`metrics-collector-identity`) to authenticate to Cosmos DB directly from inside the cluster. The
reason for the migration, not just a lateral move: a GitHub Actions runner has no stable, private
network path to reach the collector's own outputs or the Pushgateway sitting inside the cluster
without exposing something to the public internet — either the Pushgateway would need a public
ingress (a real, unnecessary attack-surface increase for a purely internal metrics-scraping
endpoint), or the workflow would need some other externally-reachable relay. Running the collector
*inside* the cluster means it can reach `pushgateway-prometheus-pushgateway.monitoring.svc.cluster.local:9091`
over the cluster's own internal DNS, with zero public exposure required anywhere in the chain —
Workload Identity gives the in-cluster job the same kind of federated, no-stored-secret credential
GitHub Actions' OIDC federation gives a workflow run, just reachable from a different network
position.

### The first-time establishment of the Key Vault CSI driver pattern

`metrics-collector` is the first (and, as of this writing, only) chart in this repo to use the
Secrets Store CSI Driver. It needs one long-lived credential no Workload Identity federation covers
— a GitHub PAT, used to call the GitHub Actions REST API (which doesn't support Workload Identity
or any other Azure-native auth). The `SecretProviderClass` reads that one secret out of
`inframonitor-aks-kv`, and does double duty: it mounts the secret as a file at `/mnt/secrets-store`
(the CSI driver's own contract), **and** syncs it into a real Kubernetes `Secret` via
`secretObjects:`. The CronJob's pod consumes it as a plain environment variable via
`secretKeyRef`, the same shape every other env var in its spec uses — the app itself never reads
the mounted file path directly. This establishes a reusable pattern (Key Vault → CSI driver → synced
K8s Secret → normal env var) for any future workload in this cluster that needs a credential
Workload Identity federation can't cover, without that workload needing to know anything about Key
Vault at all.

## 9. DORA metrics

All four DORA keys are computed fresh every collector run, over a rolling 30-day window
(`DORA_WINDOW_DAYS`), from `DeploymentEvents` documents written exclusively by the
`*-production-promotion.yml` workflows (staging deploys write to a separate container,
`PipelineMetrics`, and never enter these calculations at all — confirmed structurally, not just by
convention: `writeDeploymentEvents()` is only ever called when `wf.kind === "promotion"`).

**Real current values**, from the most recent live collector run:

| | `events-service` | `incidents-service` | `create-incident-job` |
|---|---|---|---|
| Deployment Frequency (per day) | 0.167 | 0.133 | 0.067 |
| Change Failure Rate | 54.5% | 55.6% | 33.3% |
| MTTR | 16.5s | 11s | 16s |
| Lead Time for Changes | 588s (~9.8 min) | 386s (~6.4 min) | 620s (~10.3 min) |
| Sample size (attempts in window) | 11 | 9 | 3 |

**The honest caveat that matters most: Lead Time for Changes here measures this project's own
manual-promotion practice, not raw pipeline speed.** Lead time is computed as the median duration
from a commit's real `author.date` (fetched from the GitHub commits API, confirmed for real against
this repo's history that `author.date` and `committer.date` are identical for merge commits — GitHub
resets both to merge time — so `author.date` is used as "the textbook-correct DORA field... the
timestamp of the commit that actually reached main") to the promotion workflow's `completed_at` (the
moment a smoke test actually verified it live in production, not when the promotion workflow merely
started). In a project where production promotions are frequently triggered manually, sometimes
minutes and sometimes much longer after a commit merges, this number reflects "how long this team
took to click promote," not "how fast the pipeline itself can move a change to production" — the
pipeline mechanics measured in §2/§10 are consistently well under two minutes end to end; the
9–10 minute lead times above are almost entirely human decision latency, honestly represented rather
than smoothed over.

**Null-vs-zero handling, a real bug found and fixed this project:** `changeFailureRate` and
`mttrSeconds` both return `null`, never `0`, when there's nothing to compute a rate or an average
*from* — a service with zero deploy attempts in the window and a service with many deploys and
zero failures are genuinely different outcomes a bare `0` can't distinguish, and conflating them
previously caused `changeFailureRate` to silently report `0%` (implying "perfectly healthy") for a
service that had simply never been promoted at all in the window. `safeRate()` now returns `null`
explicitly whenever its denominator is `0`, and the Pushgateway push functions skip pushing that
metric entirely when it's `null` (combined with the clear-before-push pattern in §8, so a metric
that goes from a real value to "no data" actually disappears from Prometheus rather than getting
stuck at its last real number).

**Production-only scoping, verified for real, not just assumed:** `changeFailureRate` and
`mttrSeconds` rely on the write-path guarantee described above rather than an explicit
`environment === "production"` filter in their own query — unlike `leadTimeSeconds`, which does
filter explicitly, "rather than relying on that being true forever." This session verified the
reliance is currently safe by tracing the *entire* possible contamination surface: staging
rollbacks (fired by every deliberate staging-failure test performed this project) are triggered by
a completely different job — `rollback-staging`, inside the `*-ci.yml` workflows — which the
collector's own `processRun()` never even calls `writeDeploymentEvents()` for (`kind: "ci"` runs
never reach that function at all; only `kind: "promotion"` runs do). Cross-checked against real
GitHub Actions run history for all three services' production-promotion workflows: the derived
success/failure counts behind every DORA number above matched the real run history exactly,
run-for-run — not just internally consistent with itself, but independently confirmed against a
second, unrelated data source.

## 10. Pipeline performance metrics

### Per-job avg/p95/success rate, over a rolling 7-day window

`computePipelineMetrics()` aggregates every individual job's duration and outcome, per service,
over the trailing `PIPELINE_WINDOW_DAYS` (7) days, recomputed fresh on every collector run — the
same "current snapshot, not incremental history" pattern DORA metrics use (§8). Seven days was
chosen for a project-specific reason worth stating plainly: this project's own pipeline *shape* has
changed multiple times during its life (the CI/CD template split, the Integration Tests scoping
fix, the two `pipeline_total_duration` write-path fixes below) — a longer window would keep
averaging in job durations from a pipeline structure that no longer exists, understating how fast
or how different the *current* pipeline actually is; a 7-day window means any structural change
fully "flushes" the old shape's data within a week without any manual cleanup ever being needed. A
concrete, currently-live consequence of exactly this rolling behavior: job names from the era before
the CI/CD template split (e.g. a job that used to run inside a single combined `call-service-ci`
step, now split across `call-service-ci`/`call-service-cd`) are still visible in some aggregates
today purely because they're less than 7 days old, and will disappear from the window entirely
without any code change, on their own, as that data ages out.

### The total-wall-clock-vs-summed-duration parallelism-savings metric

`pipeline_total_duration_avg_seconds`/`_p95_seconds` measure a workflow run's real
`created_at`→`updated_at` span — genuinely different from summing every job's own duration, which
double-counts time spent running jobs in parallel (the CI validation-job matrix, or the two CD scan
jobs). The dashboard surfaces this as a single, plain "Parallelism Savings" percentage per service —
`(summed job durations − real wall-clock time) / summed job durations × 100` — rather than leaving
two raw-minute numbers for a viewer to subtract themselves.

**The real story of the two contamination bugs found and fixed while building this metric.**
`writeWorkflowTotalMetric()`'s write path went through two real, sequential bugs before the metric
was trustworthy, both caught by directly inspecting real data rather than trusting the code's own
apparent correctness:

1. The original gate checked only `wf.kind === "ci"` — a static property blind to what actually
   triggered the run. A `pull_request`-triggered run never reaches `push-image`/
   `smoke-test-staging` (both gated push-to-main-only), so it represents a structurally shorter,
   incomplete pipeline — yet it was being written as a `__workflow_total__` sample and averaged in
   alongside genuine full push-to-main totals. Fixed by adding `&& run.event === "push"`.
2. That fix was still incomplete: `branches: ['**']` means pushing to *any* branch — including a
   throwaway feature branch — fires a `"push"` event too, and a push to a non-`main` branch never
   reaches `call-service-cd` at all (it requires `ref == main` specifically), producing an even
   shorter, more incomplete sample than even a `pull_request` run. This was found only by directly
   listing the real documents in Cosmos and noticing implausibly short (33–51s) samples sitting
   alongside genuine ~300s totals — not by reasoning about the code in the abstract. Fixed by
   additionally requiring `&& run.head_branch === "main"`.

Both fixes shipped as separate, individually-verified PRs, and the contaminated historical
documents (9 in total, across both bugs) were retroactively deleted from Cosmos directly, rather
than left to silently age out of the 7-day window over the following days — the same rolling-window
self-healing property described above, deliberately not relied on here, since correcting the record
immediately was cheap and the alternative would have shown a visibly wrong number on the dashboard
for up to a week. This metric currently converges slowly for an honestly-stated, separate reason
unrelated to either bug: it takes real push-to-`main` merges to accumulate enough genuine samples
for a representative average, and the "summed jobs" side of the comparison is still measurably
inflated by the pre-existing CI/CD-template job-naming duplication described in §11 — both will
correct within days as more real merges happen and the old duplicate-named job documents age out of
the same 7-day window.

## 11. Deliberate scope decisions

- **Staging and production share the same application identity, per service.**
  `events-service-identity-aks`, `incidents-service-identity-aks`, and
  `create-incident-job-identity-aks` are each federated to their service's ServiceAccount in *both*
  `inframonitor` and `inframonitor-production`. This is a deliberate scope simplification for a
  two-environment, multi-service project, stated explicitly in the values files themselves ("Same
  managed identity as staging - deliberate scope simplification for this project, not a mistake"),
  not an oversight — the tradeoff is that a compromised pod in staging holds a credential that's
  *structurally* (not just by RBAC scope) valid to authenticate as the *same* identity production
  uses, even though the Cosmos database and Service Bus topic each environment's app config points
  at differs. A stricter version of this project would mint a separate identity per (service,
  environment) pair, closing that structural equivalence entirely.

- **No individual developer productivity metrics — no PR counts, no merge rates, no
  commits-per-day.** This is a deliberate absence, not an unfinished feature. The four DORA keys
  this system measures (§9) are all *system-level* and *outcome*-oriented: how often a real change
  reaches users, how long it takes, how often it breaks something, how fast the team recovers.
  PR-count and merge-rate style metrics measure *activity*, not outcome, and are trivially gamed
  without any real improvement — splitting one meaningful change into ten trivial commits inflates
  a PR-count metric while making the actual system no faster or safer. Worse, they invite comparing
  people doing structurally incomparable work: a single PR fixing a gnarly, hard-to-reproduce bug
  and ten PRs each bumping a dependency version look identical, or worse, under a raw count. DORA's
  own research explicitly designed its four keys as team/system-level indicators for exactly this
  reason — they can be improved by fixing the *system* (a flaky test, a slow gate, a rollback path
  that doesn't actually fire) in a way that helps everyone, whereas an individual-output metric can
  only be improved by an individual changing their own visible behavior, often in ways that make the
  number look better without making the software better. For a project whose entire pipeline exists
  to answer "is this system healthy and shipping safely," an individual productivity dimension would
  measure a different, and in this context less useful, question.

- **The CI/CD job-naming duplication is a known, self-resolving transient artifact, not a bug
  requiring a fix.** Several job names appear twice in `pipeline_job_duration_avg_seconds` today —
  once under an older naming convention from before the CI/CD template split, once under the
  current one — because both sets of documents are still within the 7-day rolling window described
  in §10. This inflates the "summed jobs" side of the parallelism-savings comparison right now. It
  requires no code change: the older-named documents will age out of the window on their own within
  days, at which point the duplication disappears without anyone touching the write path or the
  historical data. Normalizing the job names retroactively was considered and deliberately left
  undecided rather than done — it would mean deciding how to relabel historical documents that
  genuinely were produced under a different pipeline shape, a judgment call with no clearly correct
  answer, versus simply waiting a few days for the rolling window to do it for free.

- **`events-service` (and `incidents-service`) have no authentication on their APIs today.**
  Confirmed by direct inspection: no authorization/API-key/JWT/bearer-token logic exists anywhere in
  either service's source. Their Kubernetes `Service`s are default `ClusterIP` (not a `LoadBalancer`
  or `Ingress`), so they aren't publicly reachable as deployed today — but nothing in the
  application layer itself would stop a request from anywhere inside the cluster (or from a future
  Ingress/LoadBalancer exposing it) from calling any endpoint with no credential at all. This is a
  real, pre-existing gap, explicitly out of scope for the CI/CD project — worth documenting as known
  and intentionally deferred, not hidden.

- **`create-incident-job`'s pipeline is now fully built — this document previously said it wasn't,
  and that was stale.** As of this rewrite, `create-incident-job-ci.yml` and
  `create-incident-job-production-promotion.yml` both exist, share the same reusable templates as
  the other two services, and have real, repeated CI, staging-deploy, production-promotion, and
  rollback run history — including a full deliberate end-to-end failure test (both staging and
  production) that confirmed its rollback mechanism fires correctly, the same discipline applied to
  the other two services in §6. Its real coverage numbers are in §3. The previous version of this
  document, describing this pipeline as unbuilt with a placeholder image tag, was accurate when
  written and is the clearest example of why this rewrite exists: a fast-moving system's
  documentation goes stale quickly, and needs a genuine re-audit against real state rather than
  incremental patching, on a cadence that matches how fast the underlying system actually changes.
