# CI/CD Pipeline

This document explains the CI/CD system that builds, tests, scans, and deploys `events-service`
and `incidents-service` onto the `inframonitor-aks` AKS cluster. It covers what each pipeline
stage does, why it's a distinct stage rather than folded into another, the identity/security model
behind it, the deployment and rollback flow, the real test coverage numbers, and the honest list of
what's deliberately out of scope today.

Everything below was verified directly against the current state of the workflow files, the
`scripts/`, the Helm charts in `inframonitor-gitops`, and the live AKS cluster / Azure control
plane at the time of writing — not reconstructed from memory of how it was designed. Where a fact
couldn't be verified this way, it's called out explicitly rather than stated as settled.

> **Scope note:** this document covers the AKS/ArgoCD/GitOps deployment path for `events-service`
> and `incidents-service` — the platform these two services actually run on today. It does not
> cover `infra/`'s Terraform, which provisions a separate, earlier Azure Container Apps + APIM +
> Front Door architecture for the same application layer. See the root [README](../README.md) and
> its flagged note for why these are two different things living in one repository, and why that
> distinction matters here.

## 1. Overview

### Trunk-based, not GitFlow

Both services' pipelines (`events-service-ci.yml`, `incidents-service-ci.yml`) trigger on `push` to
**any** branch (`branches: ['**']`) plus `pull_request` into `main`. There is no `develop` branch,
no long-lived release branches, and no merge-freeze ritual around a release train. Every feature
branch gets the fast-tier checks (lint, unit tests, dependency scan) on every push, and every PR
into `main` gets the full gate (build, integration tests, SAST, container scan) before it's
mergeable. The moment a change lands on `main`, it is built, scanned, pushed to ACR, and rolled out
to staging automatically — there is no separate "release branch" step in between.

GitFlow's long-lived `develop`/`release/*` branches solve a problem this project doesn't have: a
need to batch multiple features into a coordinated release, or support multiple release versions
in parallel. With two small, independently-deployable services and a single staging + single
production environment each, that batching would only add merge-conflict surface and a delay
between "code is done" and "code is verified against something real" — the opposite of what a fast
feedback loop needs. Trunk-based development keeps every change small, tested against `main`
immediately, and deployed to staging within minutes of merge — the branch *is* the deployment unit.

### Staging = Continuous Deployment. Production = Continuous Delivery.

This is a precise, deliberate distinction, not inconsistent behavior between the two environments:

- **Staging is genuine Continuous Deployment.** Every push to `main` that passes every gate
  (`build-image` → `integration-tests` → `container-scan` → `push-image`) is deployed to staging
  automatically, with no human step anywhere in the sequence. `update-staging-values` commits the
  new image tag straight to `inframonitor-gitops`, ArgoCD picks it up, and `smoke-test-staging`
  verifies the real rollout — all inside the same workflow run, all unattended.

- **Production is Continuous Delivery, not Continuous Deployment.** `events-service`'s
  `push-image` job pushes **one** immutable, already-scanned image to ACR per merge to `main`. That
  same artifact sits in ACR, ready to deploy, indefinitely. Nothing about it changes between
  "verified in staging" and "promoted to production" — `events-service-production-promotion.yml`
  is a separate, `workflow_dispatch`-triggered workflow that takes an `image_tag` input (an image
  that must already exist and have passed a staging smoke test — enforced by
  `verify-staging-smoke-test.sh`, see §4) and promotes *that exact tag* by editing
  `values-production.yaml`. No rebuild, no re-scan, no new artifact — the bits that run in
  production are byte-for-byte the bits that were verified in staging.

The reason this split exists rather than "just automate production too": staging deployments are
cheap to get wrong (revert the tag, nobody outside the team notices) and valuable to get fast (fast
feedback on whether `main` is healthy). Production deployments are expensive to get wrong and don't
benefit from being instant — the useful signal for "should this go to production" isn't "did CI
pass" (staging already proved that), it's a human deciding *when*, informed by what staging has
already, verifiably shown. Automating that decision away wouldn't make the pipeline more
continuous in any way that matters — it would just remove the one point where a human's judgment
about timing and blast radius actually adds value. The artifact readiness is fully continuous; the
promotion decision is deliberately not.

## 2. Pipeline stages

The full job sequence for a service's CI workflow (both `events-service-ci.yml` and
`incidents-service-ci.yml` follow this shape — the differences between them are called out inline):

```
lint-and-format ──┐
                   ├──► sast (PR only) ─────────────────────────┐
unit-tests ────────┤                                            │
                   ├──► build-image ──► container-scan ─────────┼──► push-image ──► update-staging-values ──► smoke-test-staging ──► rollback-staging (on failure)
                   └──► integration-tests ───────────────────────┘

dependency-scan (independent, no needs:)
```

### Fast-tier vs. full-gate trigger split

Every job's `if:` falls into one of three tiers:

| Tier | Jobs | Runs on | Why |
|---|---|---|---|
| **Fast, always** | `lint-and-format`, `unit-tests`, `dependency-scan` | Every push, every branch, every PR | Cheap (seconds), no cloud dependencies, no `needs:` gating each other — they run in parallel so a developer gets all three signals at once instead of serially |
| **Full gate** | `sast`, `build-image`, `integration-tests`, `container-scan` | `pull_request` into `main`, or `push` to `main` | Expensive (a full Docker build, a real CodeQL analysis, real Cosmos DB/Service Bus calls) — worth running before merge (PR) and again on the artifact that actually ships (push to `main`), but not on every WIP push to a feature branch |
| **Deploy** | `push-image`, `update-staging-values`, `smoke-test-staging`, `rollback-staging` | `push` to `main` only | These have real, external side effects (an image lands in ACR, a Git commit lands in `inframonitor-gitops`, a real cluster gets modified) — a PR must never trigger any of these, regardless of how green its checks are |

`integration-tests` deserves its own note: it's gated with `needs: [lint-and-format, unit-tests]`,
same as `build-image` — not because it depends on their *output*, but because it hits a real Cosmos
DB and Service Bus and there is no reason to spend that (real, metered) cloud usage on a commit
that's already known to fail lint. This was a genuine bug found and fixed during this project: the
job originally had no `needs:` at all, so a failing `lint-and-format` did not stop it from running
to completion. See the git history of `events-service-ci.yml` for the exact fix
(`fix(ci): gate integration-tests on lint-and-format + unit-tests`).

### Unit tests vs. integration tests vs. smoke tests

These are three structurally different checks, not three tiers of the same check run at different
sizes:

- **Unit tests** (`unit-tests` job) run entirely mocked. `events-service`'s Jest suite mocks the
  Cosmos DB and Service Bus clients; `incidents-service`'s xUnit suite mocks `IIncidentService`/the
  Cosmos container behind interfaces. They verify **the application's own logic is correct in
  isolation** — validation rules, routing, status codes, what gets written to a mocked client and
  when. What they structurally cannot catch: whether the *real* Azure SDK call would actually
  succeed, whether the app's Managed Identity actually has the RBAC role it needs, whether the
  Cosmos partition key scheme actually round-trips through a real account. A mock always behaves
  exactly as configured — it can't be surprised by a real service.

- **Integration tests** (`integration-tests` job, `events-service` only today — see §7) run against
  **real** Azure infrastructure: a dedicated `InfraMonitorTestDB` Cosmos database and a dedicated
  `infrastructure-events-test` Service Bus topic/subscription, authenticated via the CI identity's
  own OIDC-federated Managed Identity (`azure/login@v2` with `AZURE_CLIENT_ID_EVENTS_CI`). This
  catches exactly what unit tests structurally can't: a real RBAC misconfiguration, a real Cosmos
  query that's syntactically valid but semantically wrong, a real SDK version incompatibility. What
  it still can't catch: whether the *actual deployed pod*, running the *actual built image*, with
  its *actual Workload Identity federation*, behaves the same way — a container image is not the
  same artifact as `npm run test:integration` executing on a GitHub-hosted runner.

- **Smoke tests** (`smoke-test-staging`/`smoke-test-production`, via `scripts/smoke-test.sh`) run
  against the **real deployed pod**, in the **real namespace**, reached via `kubectl port-forward`
  to the exact pod confirmed `Ready` with the expected image tag. The write it performs
  (`POST /events` or `POST /incidents`) goes through the pod's own **Workload Identity** — the same
  federated identity (`events-service-identity-aks` / `incidents-service-identity-aks`) the app
  uses in production, not a CI-only identity. This is the only layer that proves the entire chain
  end to end: image built correctly → deployed correctly → ArgoCD synced it → Workload Identity
  federation actually resolves → the pod's own credential actually has Cosmos RBAC → a write
  actually lands. None of the earlier layers structurally can prove this, because none of them run
  inside the real pod using the real production identity binding.

Each layer catches a failure mode invisible to the others: a unit test failure means the logic
itself is wrong; an integration test failure (with unit tests green) means the logic is right but
its real-world Azure interaction isn't; a smoke test failure (with both green) means the code and
its Azure interaction are both fine, but something about *this specific deployment* — the image,
the rollout, the identity binding — isn't.

### One Docker build, reused; rebuilt fresh on `main`

`build-image` builds and `docker save`s the image to a tarball exactly once, uploads it as the
`docker-image` artifact, and every downstream job (`container-scan`, `push-image`) downloads and
`docker load`s that same tarball rather than rebuilding. This was a deliberate, load-bearing
decision: the whole point of `container-scan` is to scan *the exact bits that will be pushed*, and
the whole point of `push-image` is to push *the exact bits that were scanned* — rebuilding in
between either step would silently reopen the question of whether the scanned image and the pushed
image are actually the same one (a mutable base-image tag, a flaky layer cache, a dependency that
resolved differently between two separate `docker build` invocations could all make them diverge
without anything failing loudly).

That said, `build-image` still runs a **second time**, from scratch, when the same commit that was
already built and scanned in a PR gets pushed to `main` — this is not the same "duplicate build"
problem, for two independent reasons:

1. **The commit SHA is not the same artifact identity.** For a `pull_request`-triggered run,
   `GITHUB_SHA` is a synthetic merge commit GitHub creates between the PR's base and head — it
   never exists in `main`'s history after merge. `image_tag` is `${GITHUB_SHA::7}`, so the PR
   build's tag doesn't correspond to any commit that will ever exist on `main`. There is no
   artifact to "reuse" across that boundary that would even carry a meaningful tag.
2. **Base images are mutable.** `docker build` pulls `FROM node:20-alpine` (or the .NET SDK/runtime
   equivalent) fresh each time, and that tag is not pinned to a digest. An image built in a PR
   review that sat open for a few days could be built against a meaningfully different base layer
   than the same Dockerfile produces today. Rebuilding on the actual push to `main` guarantees the
   image that ships is built against whatever `FROM` resolves to *at deploy time*, not whatever it
   happened to resolve to whenever the PR was last pushed.

So: reuse *within* one workflow run is a correctness requirement (same bits, scanned then pushed).
Rebuilding *across* the PR-run/push-run boundary is also a correctness requirement, just a
different one (a real commit identity, and a freshly-resolved base image) — not the same kind of
duplication the artifact-reuse pattern exists to eliminate.

### Four distinct security concerns, not overlapping redundancy

| Check | Tool | Target | Question it answers |
|---|---|---|---|
| SAST | CodeQL | Source code (JS or C#) | Does *this code*, as written, contain an exploitable pattern (injection, unsafe deserialization, etc.)? |
| Dependency scan | Trivy, `fs` mode | `package-lock.json` / `packages.lock.json` | Does a *declared dependency* have a known CVE, independent of whether the app is even built yet? |
| Container scan | Trivy, `image` mode | The built Docker image | Does the *final, shippable artifact* — OS packages from the base image **plus** application dependencies **plus** anything the build process introduced — have a known CVE? |
| SBOM generation | Trivy, CycloneDX format | The built Docker image | What, exhaustively, **is** in this artifact — a durable, queryable inventory, independent of whether anything in it is currently flagged |

These aren't four ways of asking the same question. SAST finds bugs in code *you* wrote; dependency
scanning finds known vulnerabilities in things *you* declared as a dependency; container scanning
finds known vulnerabilities in *everything that ends up in the shipped image*, including OS-level
packages from the base image that never appear in any lockfile at all (a stale `alpine`/`.NET`
base with an unpatched `libssl`, for instance — invisible to both SAST and the lockfile scan).

SBOM generation deliberately runs against the **built image**, not the source lockfile, for the
same reason container-scan does: a lockfile only enumerates what your package manager thinks it
installed. The actual image also contains the base OS's package set, anything layered in by the
Dockerfile outside the package manager, and the specific resolved versions that actually made it
into the final layers — not the versions a lockfile *declared*, but the versions that are *really
there*. A vulnerability disclosed six months from now against a transitive OS package would be
undiscoverable by re-reading `package-lock.json`, but is answerable in seconds against a
CycloneDX SBOM generated from the actual shipped artifact. That's the entire point of an SBOM: a
durable record of what you actually shipped, not what you intended to.

## 3. Identity and security model

**Principle: least privilege per capability, not per service.** Rather than one identity per
service that can do everything that service's pipeline needs, each service gets **three** separate
CI/CD identities, split by capability, plus its own runtime workload identity — so that compromising
or misusing any single identity's credential exposes the smallest possible blast radius for what
that credential can actually do.

### The full identity table (verified via `az identity list`, `az role assignment list`, and `az identity federated-credential list` against the live subscription)

**9 managed identities exist in total** — 3 application/workload identities, and 3 CI/CD identities
per service (×2 services):

| Identity | Federated to (trust boundary) | Can do | Explicitly cannot do |
|---|---|---|---|
| `events-service-identity-aks` | K8s ServiceAccount `events-service-sa` in **both** `inframonitor` and `inframonitor-production` namespaces (2 federated credentials) | Cosmos DB Data Contributor (account-scoped — see gap noted below); Service Bus Data **Sender** on the namespace | Push/pull images; touch `inframonitor-gitops`; any Kubernetes API beyond what the pod's own SA implies; receive from Service Bus |
| `incidents-service-identity-aks` | K8s ServiceAccount `incidents-service-sa` in both namespaces (2 federated credentials) | Cosmos DB Data Contributor (account-scoped) | Everything above that events-service's identity can't do, plus: no Service Bus role at all (incidents-service doesn't publish or consume) |
| `create-incident-job-identity-aks` | K8s ServiceAccount `create-incident-job-sa` in both namespaces, **plus** `keda-operator` in the `keda` namespace (3 federated credentials) | Cosmos DB Data Contributor (account-scoped); Service Bus Data **Receiver** on the namespace | Sender role (it only consumes); push/pull images |
| `events-service-ci-identity` | GitHub OIDC, `repo:...:ref:refs/heads/main` **and** `repo:...:pull_request` (2 federated credentials) | Cosmos DB Data Contributor (account-scoped, intended for `InfraMonitorTestDB` only — see gap below) — used only by `integration-tests` | **No ACR role of any kind.** Cannot push or pull a single layer. Cannot touch the cluster. Cannot touch `inframonitor-gitops` |
| `events-service-cd-identity` | GitHub OIDC, `ref:refs/heads/main` **only** — no `pull_request` credential | `AcrPush` on `inframonitoraksacr` | Cannot run from a PR context at all (no federated credential exists for it) — a PR literally cannot mint a token for this identity, not just "isn't granted to use one." No Cosmos/Service Bus role. No cluster access |
| `events-service-smoke-test-identity` | GitHub OIDC, `ref:refs/heads/main` only | K8s: namespace-scoped `get/list/watch` on pods/deployments/replicasets + `create` on `pods/portforward`, in **both** `inframonitor` and `inframonitor-production` (via `ciSmokeTestIdentitiesStaging`/`Production` in `ci-rbac.yaml`); resourceName-scoped `get/patch` on exactly the `events-service-staging` / `events-service-production` ArgoCD Applications (`ci-argocd-refresh-rbac.yaml`) | **No Cosmos role. No Service Bus role. No ACR role.** Cannot read or write application data directly — the Cosmos write it triggers during a smoke test happens entirely through the *pod's own* identity, reached over a port-forward, never through this identity's own credential |
| `incidents-service-ci-identity` | GitHub OIDC, `ref:refs/heads/main` and `pull_request` | Cosmos DB Data Contributor (account-scoped) — currently unused; provisioned ahead of the integration test code that will use it (see §7) | Same as `events-service-ci-identity`: no ACR, no cluster |
| `incidents-service-cd-identity` | GitHub OIDC, `ref:refs/heads/main` only | `AcrPush` on `inframonitoraksacr` | Same as `events-service-cd-identity` |
| `incidents-service-smoke-test-identity` | GitHub OIDC, `ref:refs/heads/main` only | K8s: same shape as events-service's smoke-test identity, but **`inframonitor` only** — no production entry exists in `ciSmokeTestIdentitiesProduction` yet, because incidents-service has no production-promotion workflow to smoke-test against (see §7) | Same as events-service's smoke-test identity |
| `metrics-collector-identity` | GitHub OIDC, `ref:refs/heads/main` only (1 federated credential — `metrics-collector.yml` only ever runs on `schedule` or a `workflow_dispatch` against `main`, never `pull_request`) | Cosmos DB Data Contributor, scoped to exactly three containers individually (`/dbs/InfraMonitorMetricsDB/colls/DeploymentEvents`, `.../PipelineMetrics`, `.../CollectorState`) — **not** account-scoped, unlike every identity above | Cannot touch `InfraMonitorDB`/`InfraMonitorProdDB`/`InfraMonitorTestDB` at all — this is the first identity in this project to actually use Cosmos SQL role assignments' container-level `--scope` instead of the account-level scope every identity above uses. No ACR, Service Bus, or cluster access — it only calls the read-only GitHub Actions REST API and writes to its three containers |

**Verified via `az role assignment list` at the ACR resource scope**: exactly two identities hold
`AcrPush` — the two `*-cd-identity`s. No CI identity, no smoke-test identity, and neither
application identity holds any ACR role at all (image pulls at runtime are handled by the
cluster's own kubelet identity, a separate concern from any of the nine above).

**A genuine, current gap, found while compiling this table**: all five Cosmos-connected
identities' Data Contributor role assignments are scoped to the **Cosmos account**
(`inframonitor-aks-cosmos`), not to an individual database. The account holds three databases —
`InfraMonitorDB` (staging), `InfraMonitorProdDB` (production), `InfraMonitorTestDB` (integration
tests) — and, strictly by what Azure RBAC enforces, any one of these five identities' credentials
could read or write any of the three, not just the one its own pipeline or pod actually targets.
Today, nothing *exercises* that gap (each identity is only ever handed the connection details for
its intended database), but it means the isolation between staging/production/test data currently
rests on application configuration discipline, not on an RBAC boundary that would make crossing it
impossible. Narrowing this to per-database role assignments (Cosmos supports this) is a real,
concrete improvement this project hasn't made yet.

### Two concrete illustrations of the principle in practice

**The ACR-push-identity-reuse question.** It would have been simpler to let the CI identity that
already authenticates for `integration-tests` also push the image, rather than introducing a fourth
identity per service. That was considered and rejected: the CI identity's trust boundary
deliberately includes `pull_request` (so integration tests can run on a PR before merge) — but
`AcrPush` is exactly the kind of capability that must never be reachable from a PR context, since a
PR can be opened by anyone with write access without yet having passed review. Giving the
PR-reachable identity push rights would mean a PR run alone (or a maliciously crafted PR, in a repo
with looser branch protection) could push an arbitrary image to the registry, before a human ever
looked at the diff. Splitting CD into its own identity, federated **only** to `ref:refs/heads/main`
— with no `pull_request` credential at all — closes that off structurally: no token for that
identity can be minted from a PR run in the first place, not merely "the workflow doesn't grant it
one." This is verifiable directly in the federated credential list above: `events-service-cd-identity`
and `incidents-service-cd-identity` are the only two of the nine with just one federated credential
each, and it's the `main`-only one.

**`pods/portforward`, not `pods/exec` — and `PATCH`, not `DELETE`.** The smoke-test identities'
K8s RBAC grants `create` on `pods/portforward`, never `pods/exec`. The proximate reason is
functional: both services' images (`node:20-alpine`, and the .NET runtime image) don't ship `curl`,
so `kubectl exec ... curl ...` would fail on a missing binary rather than say anything about the
service. But the capability that gets granted as a result is also structurally narrower:
`pods/portforward` only forwards network traffic to a port the container already exposes, while
`pods/exec` would allow arbitrary command execution inside the container. The least-privileged
choice and the only-functional-choice happened to be the same choice here — worth noting precisely
because it means the RBAC grant wasn't loosened to work around the missing `curl`, it was already
as narrow as it could be. Separately, `incidents-service`'s smoke-test cleanup uses `PATCH
.../incidents/{id}?severity=...` to move the synthetic incident to a terminal status, not `DELETE`
— because `IncidentsController` has no delete endpoint at all. Rather than adding one solely to
give the smoke test something to call, the smoke test was written to use only endpoints that
genuinely exist for the service's own real purposes — the same principle applied to the
*application's* API surface as to the identities that call it: don't grant (or build) a capability
whose only justification is a testing convenience.

## 4. Deployment flow

### Staging (fully automatic, every push to `main`)

```
push to main
  → build-image, integration-tests, container-scan all pass
  → push-image (events-service-cd-identity / incidents-service-cd-identity pushes to ACR)
  → update-staging-values (commits new image.tag to inframonitor-gitops/charts/<service>/values-staging.yaml)
  → ArgoCD (automated + selfHeal) detects the Git diff, syncs charts/<service>-staging
  → smoke-test-staging (events-service-smoke-test-identity / incidents-service-smoke-test-identity):
      1. Force-refreshes the ArgoCD Application (so the check isn't racing ArgoCD's ~3-minute poll cycle)
      2. Polls the Deployment until its spec image tag matches what was just pushed
      3. Polls pods until one is Ready running that exact tag
      4. Port-forwards to that pod, confirms GET /health → 200
      5. POSTs a real write through the pod's own Workload Identity, confirms it lands, then cleans up
  → success: done. failure: rollback-staging fires automatically (see §5)
```

No human step appears anywhere in this sequence. A merged PR is live in staging, smoke-tested, in
minutes.

### Production (staging-verification gate, human-triggered promotion of the same artifact)

`events-service-production-promotion.yml` — `workflow_dispatch` only, taking `image_tag` as a
required input:

```
human dispatches the workflow with image_tag = <a tag that already shipped to staging>
  → verify-staging-smoke-test.sh: confirms that EXACT tag has a genuinely successful
    "Smoke Test (staging)" run in this repo's Actions history for events-service-ci.yml — refuses
    to continue otherwise
  → promote-to-production (environment: production — a GitHub Environment, so this job can carry
    its own required-reviewers gate independent of anything above it): edits
    charts/events-service/values-production.yaml to that tag, commits, pushes to inframonitor-gitops
  → ArgoCD syncs charts/events-service-production
  → smoke-test-production (events-service-smoke-test-identity, same identity as staging — see §7):
    identical checks to staging's smoke test, run against inframonitor-production / the production
    ArgoCD Application / the production Cosmos database
  → success: done. failure: rollback-production fires automatically
```

**Why `verify-staging-smoke-test.sh` matters beyond "a human decided to promote it":** a human
choosing to promote a tag is a statement of *intent*, not *evidence*. The script is what turns "I
believe this tag is good" into "this tag has a machine-checked, timestamped record of actually
having passed a real smoke test in staging" — it queries this repo's own Actions run history for a
`Smoke Test (staging)` job with conclusion `success` against that specific tag, and fails the
promotion outright if none exists. This closes off a real failure mode: a human mistyping a tag, or
promoting a tag that was pushed to ACR but never actually got smoke-tested in staging for some
reason (a skipped job, a since-superseded run). The gate isn't "did a human click a button," it's
"does verifiable evidence exist that this exact artifact already worked in staging" — the human
decision is about *timing*, the script's check is about *fact*.

`incidents-service` has no equivalent production-promotion workflow yet — see §7.

## 5. Rollback strategy

### Why not `kubectl rollout undo`

`kubectl rollout undo` mutates the live Deployment object directly, reverting it to a prior
ReplicaSet. Every one of these Applications (`events-service-staging`, `events-service-production`,
`incidents-service-staging`, and so on) has `syncPolicy.automated.selfHeal: true` in
`inframonitor-gitops`. ArgoCD's `selfHeal` continuously reconciles the live cluster state back to
whatever Git says it should be — so a `kubectl rollout undo` wouldn't actually roll anything back
in any way that lasts: within one reconciliation cycle, ArgoCD would notice the live Deployment no
longer matches the Git-defined manifest (which still points at the bad tag) and simply reapply the
bad tag right back. The two mechanisms are structurally incompatible: one edits the cluster
directly, the other exists specifically to undo direct cluster edits that don't match Git.

**Rollback has to go through Git, like every other deployment**, because Git is the only source of
truth ArgoCD will ever agree with. `rollback-staging`/`rollback-production` don't touch the cluster
at all — they edit `values-{staging,production}.yaml` back to a prior tag and push, exactly the
same mechanism `update-staging-values`/`promote-to-production` use to roll *forward*. There is
deliberately no separate "rollback code path" distinct from "deploy code path" — a rollback **is**
a deploy, just to an older tag.

### Why "most recent verified-good tag," not "one commit prior"

`find-rollback-target.sh` doesn't roll back to the immediately preceding commit — it walks
backward through the last `LOOKBACK_LIMIT` (10) completed runs of the relevant CI workflow, from
most recent, looking for the first one whose smoke-test job's conclusion was genuinely `success`.
"One commit prior" assumes the immediately preceding commit was itself good — but if two or three
commits in a row broke staging before anyone noticed, "one prior" would just roll back into another
broken state. "Most recent **verified**-good" is the only definition that's actually safe to
automate: it can walk arbitrarily far back, and if nothing in the lookback window was ever
verified-good, it fails loudly and does nothing, rather than guessing.

### The rollback bug this project actually caught

This is worth real weight, not a footnote: `rollback-staging`'s trigger condition is
`if: failure() && needs.smoke-test-staging.result == 'failure'`. The `failure()` is not decorative.
GitHub Actions silently ANDs an implicit `success()` onto any job's `if:` condition **unless that
condition already contains one of the status-check functions** (`success()`, `failure()`,
`always()`, `cancelled()`). A condition written as just `needs.smoke-test-staging.result ==
'failure'` — which reads correctly, and would pass any code review — actually evaluates as
`success() && needs.smoke-test-staging.result == 'failure'` under the hood. Since the job it
depends on failed, `success()` is `false`, and the whole expression is `false` regardless of
whether the `result` check alone would have been `true`. The job would show as **skipped**, not
run, on every single failure it was supposed to catch — the exact failure mode it exists to handle
would silently produce no rollback at all, while the workflow file itself looks entirely correct.

This was not caught by reading the YAML, and not caught by unit-testing the shell scripts — it was
caught by deliberately forcing a **real** staging smoke test to fail and watching what actually
happened in the Actions UI. `rollback-staging` stayed `skipped`. That single observation is what
surfaced the implicit-`success()` behavior, which is why the condition now explicitly includes
`failure()` as its own term (`failure() && needs.smoke-test-staging.result == 'failure'`) — a
subtly different and correct expression, verified the same way, by forcing another real failure and
confirming the job actually ran and actually rolled back. Without that deliberate, real-failure
test, this pipeline would have shipped with a rollback job that looked complete, passed every
review, and never once fired.

## 6. Testing philosophy

Real numbers, from the actual most recent test runs — not estimated:

| | `events-service` | `incidents-service` |
|---|---|---|
| Test count | 32 passed, 32 total (Jest) | 33 passed, 0 failed (xUnit) |
| Line coverage | 96.96% | 82.91% |
| Statement coverage | 97.05% | — (Cobertura reports line/branch/method, not statement, for .NET) |
| Branch coverage | 79.51% | 82.35% |
| Method/function coverage | 100% | 96.22% |
| Enforced threshold | 70% (global, all four Jest metrics, via `jest.config`'s `coverageThreshold`) | 70% (line only, via `coverlet.msbuild`'s `/p:Threshold=70 /p:ThresholdType=line`) |
| Source of the number above | Real GitHub Actions run (`Unit Tests & Coverage` job, run `32566122572`, 2026-08-22) | Real local `dotnet test` run against the current working tree (this pipeline has never executed in real CI yet — see §7) |

**Why `coverlet.msbuild`, not `coverlet.collector`, for `incidents-service`:** empirically
confirmed earlier in this project that `coverlet.collector`'s `Threshold` setting inside a
`.runsettings` file does not actually fail the build when the threshold isn't met — the run exits 0
regardless. `coverlet.msbuild`'s `/p:Threshold=X` genuinely fails the build (non-zero exit) when
the threshold isn't reached, which is the entire point of gating on a number in CI. This wasn't
read from documentation; it was found by testing both against a deliberately-under-threshold run
and observing which one actually failed.

**Honest, deliberate coverage gaps:**

- `events-service`'s three uncovered lines are all in `src/azureConfig.js` (lines 19, 25, 51) — the
  config-validation guard clauses that throw when `COSMOS_ENDPOINT`/`SERVICEBUS_NAMESPACE` are
  entirely missing from the environment, and a `ClientSecretCredential` fallback branch. These are
  startup-time misconfiguration guards, not request-path logic — every route and every middleware
  file is at 100% across all four metrics. Testing them meaningfully would mean re-executing module
  initialization under a stripped environment, for a payoff limited to "confirm a `throw` statement
  throws."
- `incidents-service`'s single 0%-covered unit (confirmed via the raw Cobertura report) is
  `Program.cs`'s top-level startup/DI wiring — ASP.NET Core's minimal hosting model executes this
  as top-level statements at process start, which unit tests (which exercise controllers/services
  behind mocked interfaces) structurally never invoke. This is exactly the gap integration tests
  exist to close once they're written for this service (§7) — a real `WebApplicationFactory`-style
  test would actually boot `Program.cs`, where a unit test never does.

**Mutation testing (Stryker), scheduled nightly — genuinely not built yet.** No Stryker
configuration, dependency, or workflow exists anywhere in this repository as of this writing
(verified: no match for `stryker` anywhere in the tree). This is noted here as planned future work,
not something to imply is already running. The premise it would address is real — coverage
percentage measures *what ran*, not *whether the assertions would actually catch a real bug*; a
mutation-testing pass (deliberately introducing small logic mutations and confirming the test suite
kills them) is the check that coverage numbers alone can't provide. It isn't implemented today.

## 7. Known limitations and deliberate scope decisions

- **Staging and production share the same application identity, per service.**
  `events-service-identity-aks` is federated to `events-service-sa` in *both* `inframonitor` and
  `inframonitor-production`; the same is true for `incidents-service-identity-aks`. This is a
  deliberate scope simplification for a two-environment, two-service project, not an oversight —
  the tradeoff is that a compromised pod in staging holds a credential that's *structurally* (not
  just by RBAC scope) valid to authenticate as the *same* identity production uses, even though the
  Cosmos database each environment's app config points at differs. A stricter version of this
  project would mint a separate identity per (service, environment) pair — four total instead of
  two — closing that structural equivalence entirely.
- **The "golden path" reusable-workflow-template idea has not been built.** No
  `workflow_call`-based reusable workflow, and no `.github/workflow-templates/`, exists anywhere in
  this repo as of this writing (verified by direct search). This was a deliberate deferral, not a
  missed step: extracting a shared template from a single working pipeline risks encoding
  one-off assumptions as if they were general patterns. With two real pipelines now written
  independently (`events-service-ci.yml`, `incidents-service-ci.yml`), there's now genuine evidence
  of what's actually shared versus what only looks shared — most concretely, `find-rollback-target.sh`
  needed **zero** changes to support a second service (it was already fully parameterized), while
  `smoke-test.sh` needed real, structural changes (a `SERVICE_NAME`-driven dispatch to
  service-specific `verify_write_*` functions, because the write schema and even the cleanup HTTP
  verb differ by service). That asymmetry — some logic generalizes almost for free, some doesn't
  generalize without real complexity — is exactly the kind of evidence a template extracted from
  only one pipeline could never have surfaced. The extraction itself is still future work.
- **`events-service` has no authentication on its API today.** Confirmed by direct inspection: no
  authorization/API-key/JWT/bearer-token logic exists anywhere in `server.js` or `src/`. Its
  Kubernetes `Service` is a default `ClusterIP` (not a `LoadBalancer` or `Ingress`), so it isn't
  publicly reachable as deployed today — but nothing in the application layer itself would stop a
  request from anywhere inside the cluster (or from a future Ingress/LoadBalancer exposing it) from
  calling any endpoint with no credential at all. This is a real, pre-existing gap, discovered
  during this work, explicitly out of scope for the CI/CD project — worth documenting as known and
  intentionally deferred, not hidden. `incidents-service` was checked the same way and has the same
  gap.
- **`create-incident-job`'s CI/CD pipeline has not been built.** No workflow file references
  `incident-function` or `create-incident-job` anywhere in `.github/workflows/`. Its Helm chart
  (`charts/create-incident-job`) exists and is ArgoCD-managed (`create-incident-job-staging` and
  `-production` Applications both show `Synced`/`Healthy`), but `values-staging.yaml` and
  `values-production.yaml` both still carry a manually-set placeholder tag (`v1`) — nothing has
  ever pushed a real tag to either. This job is KEDA-`ScaledJob`-shaped, not HTTP-service-shaped
  (it's triggered by Service Bus queue depth via `TriggerAuthentication`/`ScaledJob`, scales to
  zero, and exposes no `/health` endpoint to port-forward to) — it will need a genuinely different
  smoke-test approach than polling a Deployment and curling a pod, likely something closer to
  "publish a real test message, confirm a job run was created and completed successfully, confirm
  the expected side effect landed" rather than the current script's shape.
- **`incidents-service-ci.yml` exists but has never run in real CI.** As of this writing, the
  workflow file, `scripts/smoke-test.sh`'s incidents-service support, and the entire
  `incidents-service.Tests` project are present locally but not yet pushed to this repository's
  `main` branch. Every number and behavior described for `incidents-service` in this document
  (coverage, test count) comes from running the same commands locally that the pipeline would run —
  not from an actual GitHub Actions execution history the way every `events-service` claim in this
  document does. `incidents-service` also has no production-promotion workflow yet, and, as a
  direct, currently-observable consequence, the `incidents-service-production` ArgoCD Application
  is presently `Degraded` in the real cluster — its `values-production.yaml` still carries the
  original placeholder tag (`REPLACE_ME`), so its pod is stuck in `ImagePullBackOff`. This isn't a
  design flaw in the pipeline; it's the accurate, current state of a pipeline whose production path
  has never been built or run.
