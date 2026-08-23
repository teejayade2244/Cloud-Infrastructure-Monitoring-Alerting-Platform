# Reusable Workflow Template: Comparison & Design Proposal

**Status: analysis and proposal only — nothing implemented, no workflow files touched.**
This document compares the four existing, proven, production pipelines job by job, categorizes
every piece of logic, and proposes a concrete design for extracting shared `workflow_call`
templates. To be reviewed and agreed before any actual refactoring begins.

All four files were read in full, fresh, at the time of writing — not reconstructed from
conversation history. Line numbers refer to those reads.

## Methodology

Each job across the two CI workflows (`events-service-ci.yml`, `incidents-service-ci.yml`) and the
two production-promotion workflows (`events-service-production-promotion.yml`,
`incidents-service-production-promotion.yml`) is placed into exactly one category:

- **Category A** — genuinely identical structure/logic, differing only by simple parameter
  substitution (service name, identity secret names, chart path, image repository name). Strong
  candidates for a shared template.
- **Category B** — genuinely different due to language/runtime (npm vs dotnet, ESLint vs
  `dotnet format`, Jest vs xUnit). Needs per-language variants or must stay per-service.
- **Category C** — genuinely different due to real API/business differences, not just language
  (e.g. the smoke test's write/cleanup step). Already confirmed correctly branched logic elsewhere
  in this project (`scripts/smoke-test.sh`), not something to template away.

## Part 1: CI workflows, job by job

| Job | Category | Evidence |
|---|---|---|
| **Trigger (`on:`)** | A, with a caveat | Both: `push: branches:['**']` + `pull_request: branches:[main]` + `workflow_dispatch: {}`. Only difference: incidents-service needs **two** `paths:` entries (`incidents-service/**` and `incidents-service.Tests/**`, lines 6-8) vs events-service's one (line 6), because its test project is a sibling directory. Parameter-substitutable in principle, but see the platform-constraint note below — this can't actually live inside a `workflow_call` template at all. |
| **lint-and-format** | Shape=A, steps=B | Both jobs: identical `defaults.run.working-directory`, identical `checkout` → `setup-<runtime>` → `run lint`. But the actual commands are irreducibly different: `npm ci` / `npm run lint` / `npm run format:check` (events, lines 38-42) vs `dotnet format --verify-no-changes` (incidents, line 41). No plausible parameterization unifies ESLint+Prettier with `dotnet format`. |
| **unit-tests** | B, plus a real structural wrinkle | events: job-level `defaults.run.working-directory`, `npm run test:coverage` (line 61), coverage threshold enforced *externally* in `package.json`'s `jest.coverageThreshold` (invisible in the YAML). incidents: **no** job-level working-directory default (comment at lines 46-47 explains why — `TEST_DIR` is a sibling, not nested), per-step `working-directory: ${{ env.TEST_DIR }}` (line 55), threshold enforced *inline* via `/p:Threshold=70 /p:ThresholdType=line /p:ThresholdStat=total` (line 56) because `coverlet.collector`'s threshold silently no-ops. Two genuinely different things bundled here: different test runners (B), and a different *directory-scoping strategy* (job-level default vs per-step override) driven by a real filesystem-layout difference, not a style choice. |
| **dependency-scan** | **A — clean** | Byte-for-byte identical `aquasecurity/trivy-action@a9c7b0f06e461e9d4b4d1711f154ee024b8d7ab8` pin, identical `scan-type: fs`, `format: table`, `severity: CRITICAL,HIGH`, `ignore-unfixed: true`, `exit-code: 1` (events lines 82-90, incidents lines 80-88). Only differences: `scan-ref`/`output` interpolate `WORKING_DIR` (already a parameter), and the job *display name* differs by lockfile filename (`package-lock.json` vs `packages.lock.json` — genuinely different files, not a typo). Textbook Category A. |
| **sast (CodeQL)** | Shape=A, one step=B | Identical `needs`, `if: pull_request`, `permissions`. `languages:` differs (`javascript` vs `csharp` — parameterizable) and `paths-ignore` differs (`node_modules`/`coverage` vs `bin`/`obj` — parameterizable list). But incidents-service has an **extra step** events-service doesn't: `setup-dotnet@v4` *before* `codeql-action/init` (line 109), because C#'s `autobuild` needs an SDK present, unlike JS's near-no-op autobuild. Not a value substitution — a step that exists for one language and not the other. |
| **build-image** | **A — clean** | Identical shape line-for-line (events lines 128-155, incidents 127-154): same `needs`, same `if:`, same short-SHA-tag computation, same `docker build --platform linux/amd64`, same save/upload pattern. Every difference is the service-name substitution (image tag, tarball filename, artifact path) — 3 occurrences, all the same string. |
| **integration-tests** | Not comparable | Exists for events-service (lines 157-204); **does not exist** for incidents-service — deliberately deferred, with an explicit placeholder comment (lines 156-164). Can't categorize A/B/C against a job that isn't there yet. When written, its shape will likely mirror events-service's (Category A orchestration: checkout → setup-runtime → cloud login → run test command → upload results), but the actual test command (`dotnet test` vs `npm run test:integration`) will be Category B. |
| **container-scan** | **A — clean** | Same conclusion as `build-image` and `dependency-scan` — identical Trivy image-scan + SBOM-generation shape (events 206-256, incidents 166-216), differing only by service-name substitution. |
| **push-image** | Steps=A, `needs:` graph=parameterized-but-not-trivial | Steps are byte-identical (download-artifact → `docker load` → `azure/login` → `az acr login` → `docker push`) except the CD identity secret name (`AZURE_CLIENT_ID_EVENTS_CD` vs `AZURE_CLIENT_ID_INCIDENTS_CD`) and image name. But `needs:` differs structurally: `[container-scan, integration-tests]` (events, line 260) vs `container-scan` only (incidents, line 222) — because `integration-tests` doesn't exist yet for incidents-service. A graph-topology difference, not a string substitution — needs a boolean input (e.g. `has-integration-tests`) controlling both this `needs:` list and whether the `integration-tests` job block runs at all. |
| **update-staging-values** | **A — clean** | Identical shape (events 292-320, incidents 255-283): same yq install block, same `yq -i '.image.tag = ...'` pattern, same commit message template. Differs only by chart path and service name in the commit message. |
| **smoke-test-staging** | **A — clean, and reveals an existing inconsistency** | Identical shape and steps (events 322-373, incidents 285-332). Only real content difference: incidents-service's job sets `SERVICE_NAME: incidents-service` explicitly (line 322); events-service's job **doesn't set `SERVICE_NAME` at all**, relying on `smoke-test.sh`'s own default. A shared template with `SERVICE_NAME` as a required input would actually *fix* this small existing asymmetry, not just preserve it. |
| **rollback-staging** | **A — clean, strongest evidence in the whole comparison** | Identical shape (events 375-448, incidents 334-398). The `Report rollback` step's echoed text (lines 438-448 / 388-398) is **already 100% character-identical between the two files** — no service name appears anywhere in the literal text, only in interpolated job-output variables that are already parameters. This step could be copy-pasted into a template today with zero string edits. |

## Part 2: production-promotion workflows, job by job

All four jobs came back **Category A** with no exceptions — a materially different result from
the CI comparison:

| Job | Evidence |
|---|---|
| **verify-staging-smoke-test** | Identical (events lines 16-33, incidents 16-30) — differs only by the `WORKFLOW_FILE` value, which is itself already a parameter added to the shared script this session. |
| **promote-to-production** | Identical (events 35-69, incidents 32-66), including `environment: production` **verbatim, identical string, in both files** (line 38 / line 35) — directly confirms this is a genuinely shared gate, not per-service, by direct comparison, not assumption. |
| **smoke-test-production** | Identical shape (events 71-117, incidents 68-119); differs only by identity secret, `ARGOCD_APP_NAME`, and incidents-service's explicit `SERVICE_NAME` (same asymmetry noted above for staging). |
| **rollback-production** | Identical shape (events 119-193, incidents 121-189), including the same byte-identical `Report rollback` echo text. `ARTIFACT_NAME: smoke-test-evidence-production` is the **same literal string** in both files — safe because it's scoped by the differing `WORKFLOW_FILE` when queried. |

**Confirmed directly** (not from memory): the rollback `if:` condition is
`failure() && needs.smoke-test-production.result == 'failure'` in *both* files, via grep — correctly
present from the start in the incidents-service file, not rediscovered.

## Cross-cutting observations

- **The "Install yq" block is byte-identical in all 8 occurrences** across all four files
  (`update-staging-values` + `rollback-staging` in each CI file, `promote-to-production` +
  `rollback-production` in each promotion file). Zero risk, zero judgment calls — a composite
  action (`.github/actions/install-yq/action.yml`) would eliminate this duplication independent of
  any decision on the bigger job-level template.
- **The `azure/login` → `install kubectl+kubelogin` → `get AKS credentials` → `convert kubeconfig`
  4-step sequence is also byte-identical** across all 4 smoke-test jobs (staging×2, production×2),
  except the identity secret. Same story — a clean composite-action candidate.
- `GITOPS_PAT`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `GITHUB_TOKEN` are the same secret
  **names** everywhere — genuinely shared, unlike the three per-service identity secrets (`_CI`,
  `_CD`, `_SMOKE` suffixed per service).

## Design proposal

**Recommendation: two `workflow_call` templates (one CI-shaped, one promotion-shaped) — not split
by language, and not one giant template either.**

### Why not split by language

The job-by-job count above is the actual evidence, not a guess — out of the CI pipeline's ~10
jobs, only **2 are genuinely language-specific** (`lint-and-format`, `unit-tests`), and **1 has a
single language-conditional step** (`sast`'s pre-CodeQL setup). The other 7 jobs
(`dependency-scan`, `build-image`, `container-scan`, `push-image`, `update-staging-values`,
`smoke-test-staging`, `rollback-staging`) never touch source code at all — they operate on the
built container image, Git, Kubernetes, or ArgoCD, which don't care what language produced the
image. Splitting into two full templates would force that 70%+ language-agnostic majority to be
duplicated across both templates — reintroducing, at a coarser grain, the exact duplication a
template exists to remove.

The production-promotion pipeline is **100% language-agnostic across all 4 jobs**, with zero
exceptions found — that one is an unambiguous, single clean template with no language branching at
all.

### How the CI template should handle the 2-3 language-specific spots

A `language: node | dotnet` input, with narrowly-scoped `if: inputs.language == 'node'` /
`== 'dotnet'` step pairs *only* inside `lint-and-format`, `unit-tests`, and the one extra `sast`
setup step — not a parallel copy of the whole job. This keeps the language-specific surface area
honest and small, matches where the real differences actually live, and if a third language ever
needs onboarding (the repo already has a reference-only Go service), it's one more narrow branch in
three places, not a third full template.

### A platform constraint that shapes this regardless of the above

`workflow_call` reusable workflows cannot declare their own `on: push`/`on: pull_request` with
`paths:` filters — that trigger, with its path list, has to live in a small per-service *caller*
file that does `uses: ./.github/workflows/<template>.yml` with `with:`. So even fully templated,
`events-service-ci.yml` and `incidents-service-ci.yml` don't disappear — they shrink to a trigger
block plus a `uses:`/`with:` call. Similarly, secrets can't be looked up dynamically by a string
input — the template declares its own generically-named `secrets:` (e.g. `ci_client_id`,
`cd_client_id`, `smoke_client_id`), and each caller maps its own real secret name into those on
invocation.

### Rough input shape (illustrative, not final)

**CI template**: `service-name`, `working-directory`, `language`, `node-version`/`dotnet-version`,
`test-working-directory` (defaults to `working-directory`, overridden for incidents-service's
sibling-dir case), `has-integration-tests` (boolean, controls both the `integration-tests` job's
existence and `push-image`'s `needs:` list), `codeql-language`, `codeql-paths-ignore`.

**Promotion template**: `service-name` and `workflow-file` cover essentially everything.
`environment: production` should stay **hardcoded** in the template rather than parameterized — it's
deliberately identical across every caller, and turning a deliberately-fixed shared gate into a
knob would be the wrong kind of flexibility.

## Status

Analysis and proposal only. Nothing has been implemented; neither CI workflow nor either
production-promotion workflow has been touched. To be reviewed and agreed before any actual
refactoring begins.
