# incidents-service.IntegrationTests

Real Cosmos DB integration tests for `incidents-service` - the counterpart to
`incidents-service.Tests`, which mocks the Cosmos SDK entirely. This project makes real calls
against `InfraMonitorTestDB`'s `Incidents` container, proving the actual Cosmos DB SDK usage
works correctly (partition-key handling, query shape, write/read/update round-tripping), not just
business logic in isolation.

## Why a separate project, not a folder inside `incidents-service.Tests`

`events-service` separates its Jest suites by directory (`__tests__/` vs `__tests__/integration/`),
plus a distinct Jest config and `testPathIgnorePatterns` so the default `npm test` never touches
integration tests at all. `dotnet test` doesn't have an equivalent path-based mechanism - the unit
of isolation is the **project**, not a folder within one. A separate `.csproj` gives the same
guarantee events-service's config gets from directories: `incidents-service-ci.yml`'s
`unit-tests` job (`dotnet test` inside `incidents-service.Tests`) can never accidentally compile
or run a test here, since this project isn't referenced by that one at all - no filter/trait
convention to maintain correctly, it's structurally impossible for the unit-test run to reach
this code.

## What boots the app under test

`IncidentsIntegrationFixture` uses `WebApplicationFactory<Program>` to boot the **real**
`Program.cs` in-memory - real DI wiring, real `CosmosClient` construction, real middleware
pipeline - the same fidelity events-service's integration tests get from requiring the real
Express router directly. `Program.cs` has a `public partial class Program {}` marker added
specifically so this project (a separate assembly) can reference the type; top-level statements
generate an `internal` `Program` class by default.

A second, independently-constructed `CosmosClient` is used for seeding/verification/cleanup -
deliberately never sharing a code path with the app under test, so a bug that broke both the app's
write and the test's own verification couldn't hide behind agreement between the two.

## Test data hygiene

Every document these tests create carries a `Source` value prefixed `integration-test-` (via
`IncidentsIntegrationFixture.TestRunId`, timestamp + random suffix so concurrent runs don't
collide). Each test cleans up what it created directly (`try`/`finally`); the fixture's
`DisposeAsync` runs a broader sweep by that prefix as a safety net for anything a crashed test
left behind - same two-tier cleanup `events.integration.test.js` uses (precise per-test, plus an
`afterAll` sweep).

## Running locally

Requires `COSMOS_ENDPOINT` and `COSMOS_TEST_DATABASE` in the environment, and real Azure
credentials able to authenticate as `incidents-service-ci-identity` (or, locally, any identity/
`az login` session with Cosmos DB Data Contributor on the test database) - `DefaultAzureCredential`
resolves this the same way `Program.cs` itself does. Fails loudly and immediately if the required
env vars are missing, rather than failing confusingly deep inside a Cosmos SDK call.

```
COSMOS_ENDPOINT=https://inframonitor-aks-cosmos-eastus2.documents.azure.com:443/ \
COSMOS_TEST_DATABASE=InfraMonitorTestDB \
dotnet test
```

A local `dotnet test` run against real infrastructure was attempted directly during development
and hung indefinitely (20+ minutes, no failure, no completion) even after `az login`, most likely
because this machine can't actually reach the Cosmos DB endpoint the way GitHub Actions runners
can - `DefaultAzureCredential`'s chain itself resolves fine (confirmed via `az account show`), so
this reads as a network-level reachability gap, not a credential problem. The real, authoritative
verification for this project is CI, not local - it's already confirmed working there (see the
CI note below).

In CI, these come from the `COSMOS_ENDPOINT`/`COSMOS_TEST_DATABASE` GitHub Variables (already
shared with events-service's integration tests, same Cosmos account) via
`service-ci-template.yml`'s opaque `integration_test_vars` input, and `AZURE_CLIENT_ID` from the
`AZURE_CLIENT_ID_INCIDENTS_CI` secret.
