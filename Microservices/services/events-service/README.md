# events-service

Node.js/Express service for recording infrastructure events. Writes events to Cosmos DB and, for
`critical`/`high` severity events, publishes them to a Service Bus topic for downstream consumers.

## Endpoints

| Method | Path          | Description                                                                |
| ------ | ------------- | -------------------------------------------------------------------------- |
| GET    | `/health`     | Liveness/readiness check, used by the CI smoke test and Kubernetes probes  |
| POST   | `/events`     | Create an event; publishes to Service Bus if severity is `critical`/`high` |
| GET    | `/events`     | List events, optionally filtered by `environment`, `severity`, `type`      |
| GET    | `/events/:id` | Get a single event by id                                                   |
| DELETE | `/events/:id` | Delete a single event by id                                                |

## Local development

```bash
npm ci
npm run dev        # nodemon, requires a .env with Cosmos/Service Bus config
```

## Tests

```bash
npm test                 # unit tests
npm run test:coverage    # unit tests with coverage (CI enforces 70% via package.json)
npm run test:integration # against real Cosmos/Service Bus test resources
```

## Deployment

Built, scanned, and deployed via `events-service-ci.yml` → `service-ci-template.yml`. See
[docs/CICD.md](../../../docs/CICD.md) for the full pipeline.
