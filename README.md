# InfraMonitor

![Kubernetes](https://img.shields.io/badge/AKS-Kubernetes-326CE5?logo=kubernetes&logoColor=white)
![ArgoCD](https://img.shields.io/badge/ArgoCD-GitOps-EF7B4D?logo=argo&logoColor=white)
![Azure](https://img.shields.io/badge/Azure-Cloud-0078D4?logo=microsoftazure&logoColor=white)
![Node.js](https://img.shields.io/badge/Node.js-20-339933?logo=nodedotjs&logoColor=white)
![.NET](https://img.shields.io/badge/.NET-10-512BD4?logo=dotnet&logoColor=white)
![TypeScript](https://img.shields.io/badge/TypeScript-5-3178C6?logo=typescript&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

**InfraMonitor** is a cloud infrastructure monitoring and alerting platform: a single place to
publish infrastructure events, automatically turn the critical ones into tracked incidents, and get
notified the moment something needs attention. This README covers the platform end to end; the
CI/CD and observability system that builds, tests, scans, deploys, and measures it is documented in
full, with real numbers and real engineering reasoning, in **[docs/CICD.md](docs/CICD.md)**.

## The problem it solves

When something goes wrong in production — a deployment fails, a service goes down, a threshold gets
breached — teams need three things straight away: to know about it, to have a record of it, and to
be able to track it through to resolution. InfraMonitor wires the pieces together into one
pipeline: **event in → incident created → someone notified → status tracked to resolution**.

![InfraMonitor dashboard](docs/dashboard.png)

## Platform architecture

The application services run on **Azure Kubernetes Service** (`inframonitor-aks`), deployed and
kept in sync entirely through GitOps — no `kubectl apply` in the deploy path, ever:

- **ArgoCD** (app-of-apps pattern: one `inframonitor-root` Application points at `charts/apps` in
  the separate [`inframonitor-gitops`](https://github.com/teejayade2244/inframonitor-gitops) repo,
  which in turn defines one ArgoCD `Application` per service per environment) — every Deployment,
  every RBAC binding, every image tag change lands as a Git commit first; ArgoCD's `selfHeal` then
  reconciles the cluster to match, automatically and continuously.
- **KEDA** scales `create-incident-job` from zero based on Service Bus queue depth — it's a
  `ScaledJob`, not a long-running Deployment, so it costs nothing to run when there's nothing to
  process.
- **kube-prometheus-stack** (Prometheus + Grafana + Alertmanager) provides cluster and workload
  metrics, running in the `monitoring` namespace — and also backs a purpose-built, in-cluster
  `metrics-collector` CronJob that turns raw GitHub Actions history into real DORA and pipeline-
  performance dashboards. See [docs/CICD.md §8–§10](docs/CICD.md#8-observability-system).
- Two environments, `inframonitor` (staging) and `inframonitor-production`, each with its own
  namespace and its own ArgoCD Applications per service.

Three backend components make up the application layer:

| Service | Stack | Role |
|---|---|---|
| `events-service` | Node.js + Express | Ingests infrastructure events, writes to Cosmos DB, publishes critical/high-severity events to Service Bus |
| `incidents-service` | .NET 10 (ASP.NET Core Web API) | Incident CRUD |
| `create-incident-job` | Node.js, KEDA `ScaledJob` on AKS | Triggered by Service Bus queue depth; turns a critical event into a tracked incident |

All three authenticate to Azure (Cosmos DB, Service Bus) via **Azure AD Workload Identity** — a
Kubernetes ServiceAccount federated to a user-assigned Managed Identity, no connection strings or
client secrets anywhere in application code.

> **A note on `infra/` and the architecture diagram below.** This repository also contains a
> Terraform-driven Azure **Container Apps** + API Management + Front Door architecture (see
> `infra/`, and the diagram/API-reference sections further down) — a genuinely different, earlier
> iteration of this same application layer, built and actually deployed via `terraform apply` as
> recently as July 2026. As of this writing, **no Container Apps, APIM, or Front Door resources
> currently exist in this project's Azure subscription** (verified directly — the `Microsoft.App`
> resource provider isn't even registered on it) — the AKS/ArgoCD platform described above is what
> the CI/CD pipelines in `docs/CICD.md` actually build and deploy to today. The Terraform code and
> the architecture diagram are kept in the repo as the earlier iteration, not as a second live
> environment running in parallel. If you're here for the Kubernetes/GitOps/CI-CD engineering,
> `docs/CICD.md` and `inframonitor-gitops` are the current, live system; if you're here for the
> managed-PaaS/Terraform iteration, the sections below (architecture diagram, API reference via
> APIM, environment variables, Terraform getting-started steps) describe that earlier design as it
> was actually built.

![InfraMonitor architecture (earlier Container Apps iteration)](docs/architecture.jpg)

## Tech stack

| Layer | Technology | Purpose |
|---|---|---|
| Frontend | React 19 + TypeScript + Vite + Tailwind CSS | Dashboard for incidents, events and notifications |
| Events service | Node.js + Express | Event ingestion API |
| Incidents service | .NET 10 (ASP.NET Core Web API) | Incident CRUD |
| Incident creation job | Node.js, KEDA `ScaledJob` | Triggered by Service Bus queue depth; turns a critical event into a tracked incident |
| Data store | Azure Cosmos DB (SQL API) | Events, Incidents and Notifications containers; separate databases per environment on one account |
| Messaging | Azure Service Bus (Topic + subscriptions) | Fans out critical events to the incident-creation job |
| Orchestration | Azure Kubernetes Service | Runs all three services/jobs and the metrics-collector CronJob |
| GitOps | ArgoCD (app-of-apps) | Every deployment is a Git commit to `inframonitor-gitops`; automated sync + selfHeal, no manual `kubectl apply` |
| Autoscaling | KEDA | Scale-to-zero for the event-triggered incident job |
| Observability | kube-prometheus-stack (Prometheus, Grafana, Alertmanager) + a custom `metrics-collector` CronJob | Cluster/workload metrics, plus real DORA metrics (deployment frequency, change failure rate, MTTR, lead time) and CI/CD pipeline-performance metrics, pushed to Prometheus via Pushgateway |
| Identity | Azure AD Workload Identity + Cosmos/Service Bus/ACR RBAC | No connection strings or shared keys in application code; **14 distinct, purpose-scoped Managed Identities** across CI, CD, smoke-test, and runtime roles — see `docs/CICD.md §4` |
| CI/CD | GitHub Actions (OIDC, no stored client secret), two shared reusable `workflow_call` templates | Per-service pipelines: lint → test → scan → build → deploy → smoke-test → automatic rollback, plus a separate human-gated production-promotion pipeline |
| Container registry | Azure Container Registry | Stores service images, pulled via kubelet identity |
| IaC (earlier iteration) | Terraform (`azurerm`) | Azure Container Apps + APIM + Front Door — see the note above |

## Engineering highlights

Four concrete pieces of evidence from this project worth calling out specifically, because they're
the kind of thing that's easy to claim and rarely actually demonstrated:

- **A real, subtle GitHub Actions bug, caught by testing the failure path, not by reading the
  YAML.** `rollback-staging`'s trigger condition looked correct
  (`needs.smoke-test-staging.result == 'failure'`) and would have passed any code review — but
  GitHub Actions silently ANDs an implicit `success()` onto any job condition that doesn't already
  contain a status-check function, which made the job stay `skipped` on every failure it was
  supposed to catch. This was only found by deliberately forcing a real staging smoke test to fail
  and watching the rollback job not run — then re-verified the same way, for real, across all three
  services and both staging and production. Full story, with the exact fix, in
  [docs/CICD.md §6](docs/CICD.md#6-rollback-strategy).
- **Real DORA metrics, with honest caveats instead of vanity numbers.** All four DORA keys
  (deployment frequency, change failure rate, MTTR, lead time for changes) are computed from real
  GitHub Actions history and Cosmos-backed deployment records, not hand-waved — and the writeup
  doesn't stop at the numbers. Lead time currently sits around 6–10 minutes per service; the
  document says plainly that this reflects *this project's own manual-promotion practice*, not raw
  pipeline speed (the pipeline mechanics themselves run well under two minutes), because reporting
  a flattering number without that context would misrepresent what's actually being measured. See
  [docs/CICD.md §9](docs/CICD.md#9-dora-metrics).
- **The golden-path template extraction was backed by a real job-by-job analysis, not intuition.**
  Before writing a single reusable workflow template, every job across the (then two) existing
  pipelines was individually categorized as language-agnostic or language-specific, with the
  evidence written down first: over 70% of the CI pipeline's jobs, and 100% of the
  production-promotion pipeline, turned out to never touch source code at all — which is exactly
  why the templates are split by pipeline *shape*, not by language. See
  [docs/CICD.md §2](docs/CICD.md#2-pipeline-architecture).
- **14 distinct identities, split by capability, with the reasoning behind each split documented.**
  Not "least privilege" as a slogan — a concrete, load-bearing decision trail: the ACR-push
  identity-reuse question being raised and rejected (a PR-reachable identity must never be able to
  push an image), why the smoke-test RBAC grants `pods/portforward` and not `pods/exec`, and a
  documented, not-yet-unified inconsistency between an older account-wide Cosmos RBAC pattern and a
  newer, narrower container-scoped one. See [docs/CICD.md §4](docs/CICD.md#4-identity-and-security-model).

**→ Full engineering writeup, with every claim above traced to real code, real runs, and real
data: [docs/CICD.md](docs/CICD.md).**

## Repository structure

```
Cloud-Infrastructure-Monitoring-Alerting-Platform/   (this repo)
├── Frontend/                          # React + TypeScript + Vite dashboard
├── Microservices/
│   ├── services/
│   │   ├── events-service/            # Node.js + Express: event ingestion API
│   │   ├── incidents-service/         # .NET 10 Web API: incident management API
│   │   ├── incidents-service.Tests/   # xUnit unit tests
│   │   └── incidents-service.IntegrationTests/   # xUnit integration tests, real Azure resources
│   ├── functions/
│   │   └── incident-function/         # Node.js source for the KEDA-scaled create-incident-job
│   └── send-notification-go/          # Go notification prototype (reference only, not deployed)
├── infra/                             # Terraform - the earlier Container Apps iteration (see note above)
├── scripts/
│   ├── smoke-test.sh                  # Real deployed-pod verification, shared by events/incidents-service
│   ├── create-incident-job-smoke-test.sh   # KEDA/Service Bus-shaped equivalent for the incident job
│   ├── find-rollback-target.sh        # Walks CI history for the most recent verified-good tag
│   ├── verify-staging-smoke-test.sh   # Production-promotion gate: checks for real evidence, not just a tag name
│   └── metrics-collector/             # Node script: GitHub Actions history -> Cosmos DB -> DORA/pipeline metrics
├── docs/
│   ├── CICD.md                        # The full CI/CD + observability engineering writeup - start here
│   └── reusable-workflow-analysis.md  # The job-by-job evidence behind the golden-path template split
└── .github/workflows/
    ├── service-ci-template.yml        # Shared reusable CI template (all three services)
    ├── service-cd-template.yml        # Shared reusable staging-deploy template (all three services)
    ├── service-promotion-template.yml # Shared reusable production-promotion template (all three services)
    ├── events-service-ci.yml / events-service-production-promotion.yml
    ├── incidents-service-ci.yml / incidents-service-production-promotion.yml
    ├── create-incident-job-ci.yml / create-incident-job-production-promotion.yml
    ├── metrics-collector-ci.yml       # Builds/deploys the metrics-collector CronJob image
    ├── terraform.yml                  # Earlier iteration's IaC pipeline (self-hosted runner)
    └── deploy-frontend.yml            # Frontend build/deploy to Azure Static Web Apps

inframonitor-gitops/   (separate repo - the GitOps source of truth for the AKS platform)
└── charts/
    ├── apps/                          # ArgoCD Application manifests (app-of-apps)
    ├── events-service/                # Helm chart: values.yaml + per-environment values-{staging,production}.yaml
    ├── incidents-service/
    ├── create-incident-job/           # Includes the KEDA ScaledJob + TriggerAuthentication
    ├── metrics-collector/             # CronJob, Key Vault CSI SecretProviderClass, Grafana dashboard ConfigMap
    └── inframonitor-namespace/        # Namespaces + CI/CD RBAC (ci-rbac.yaml, ci-argocd-refresh-rbac.yaml)
```

## Running things locally

**All three backend components** run locally against real Azure resources (Cosmos DB, Service Bus)
via environment variables — there's no local emulator step documented or required beyond that:

```bash
# events-service
cd Microservices/services/events-service && npm install && npm run dev
# needs COSMOS_ENDPOINT / Service Bus config in a local .env - see azureConfig.js; gitignored

# incidents-service
cd Microservices/services/incidents-service && dotnet run

# create-incident-job (incident-function)
cd Microservices/functions/incident-function && npm install && npm run start:create-incident
# a one-shot job (node src/create-incident.js), not a long-running server - needs a real Service Bus
# message to process; see scripts/create-incident-job-smoke-test.sh for how CI exercises it end to end

# Frontend
cd Frontend && npm install && npm run dev
```

**Running the test suites** (the numbers in the Engineering highlights section and
[docs/CICD.md §3](docs/CICD.md#3-testing-philosophy) come from exactly these commands):

```bash
cd Microservices/services/events-service && npm run test:coverage        # Jest
cd Microservices/services/incidents-service.Tests && dotnet test /p:CollectCoverage=true /p:CoverletOutputFormat=cobertura   # xUnit + coverlet
cd Microservices/functions/incident-function && npm run test:coverage    # Jest
cd scripts/metrics-collector && npm test                                 # Jest, the collector's own pure-function unit tests
```

**Prerequisites:** [Node.js](https://nodejs.org/) 20, the
[.NET 10 SDK](https://dotnet.microsoft.com/), [Docker](https://www.docker.com/), the
[Azure CLI](https://learn.microsoft.com/cli/azure/) with the `kubelogin` extension, `kubectl`, and
the [GitHub CLI](https://cli.github.com/) if you want to interact with pipeline runs the way
`docs/CICD.md` describes.

**What isn't documented anywhere (a real, current gap, not an oversight in this README):**
provisioning the `inframonitor-aks` cluster itself, and the cluster-level add-ons running on it
(ArgoCD, KEDA's own operator, kube-prometheus-stack) are not captured as code in either this repo
or `inframonitor-gitops` — they were provisioned directly against the cluster. Everything
*downstream* of "the cluster and these add-ons exist" (every service, every namespace, every RBAC
binding, the metrics-collector CronJob) is GitOps-managed from `inframonitor-gitops`; the cluster
and its add-ons themselves currently are not. See `docs/CICD.md`'s scope note for how this fits
together.

For the earlier Container Apps / Terraform iteration's own getting-started steps (provisioning via
`terraform apply`, the self-hosted runner, environment variables/secrets reference, and the full
API reference as published through APIM) — that content describes a real, previously-deployed
system, not a currently-running one; ask if you'd like it restored to this README in full rather
than summarized here.

## Licence

Distributed under the MIT Licence. See [`LICENSE`](LICENSE) for details.
