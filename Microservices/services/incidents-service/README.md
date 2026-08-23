# incidents-service

.NET 10 / ASP.NET Core service for tracking infrastructure incidents, backed by Cosmos DB.

## Endpoints

| Method | Path              | Description                                                   |
|--------|-------------------|-----------------------------------------------------------------|
| GET    | `/health`         | Liveness/readiness check, used by the CI smoke test and Kubernetes probes |
| POST   | `/incidents`      | Create an incident (`title`, `severity`, `environment` required) |
| GET    | `/incidents`      | List incidents, optionally filtered by `severity`, `status`, `environment` |
| GET    | `/incidents/{id}` | Get a single incident by id (`severity` query param required - it's the partition key) |
| PATCH  | `/incidents/{id}` | Update a single incident (`severity` query param required)     |
| GET    | `/notifications`  | List the 50 most recent notifications                          |

## Local development

```bash
dotnet restore
dotnet run          # requires appsettings.json / user-secrets with Cosmos config
```

## Tests

```bash
dotnet test ../incidents-service.Tests                    # unit tests
dotnet test ../incidents-service.IntegrationTests          # against a real Cosmos test database
```

Coverage is enforced in CI at 70% line coverage via `coverlet.collector`.

## Deployment

Built, scanned, and deployed via `incidents-service-ci.yml` → `service-ci-template.yml`. See
[docs/CICD.md](../../../docs/CICD.md) for the full pipeline.
