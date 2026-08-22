# incidents-service.Tests

xUnit + Moq unit tests for `incidents-service`. Mocks the Cosmos SDK entirely
(`CosmosClient`/`Database`/`Container`/`FeedIterator<T>` are all designed by
Microsoft to be Moq-mockable) - no real Cosmos DB calls. Real Azure interaction
is covered by integration tests, not part of this suite (not yet built for
this service).

## Running tests

Plain run, no coverage (fast, for local iteration):

```
dotnet test
```

## Running tests with coverage (CI equivalent of events-service's `npm run test:coverage`)

```
dotnet test /p:CollectCoverage=true /p:CoverletOutputFormat=cobertura /p:Threshold=70 /p:ThresholdType=line /p:ThresholdStat=total
```

This is the command the CI pipeline for this service should run. It fails the
build (non-zero exit) if total line coverage drops below 70% - verified
empirically to actually enforce (confirmed both that it fails above the real
achieved percentage and passes at the real threshold), not just configured
and assumed to work.

Note: `coverlet.collector` (the VSTest data collector coverage collection
alone goes through, e.g. `dotnet test --collect:"XPlat Code Coverage"`) does
**not** enforce `Threshold` via `.runsettings` despite the setting existing in
its schema - confirmed by testing it directly. `coverlet.msbuild` (added to
this project specifically for this reason) is the package that actually fails
the build on a missed threshold.

## Coverage baseline (as of this suite, 33 tests, all passing)

| File | Line coverage |
|---|---|
| `Controllers/IncidentsController.cs` | 100% (100/100) |
| `services/IncidentService.cs` | 100% (122/122) |
| `Middleware/ErrorHandlingMiddleware.cs` | 100% (32/32) |
| `models/incident.cs` | 100% (52/52) |
| `models/Notification.cs` | 91.67% (22/24) |
| `Program.cs` | 3.03% (2/66) |
| **Project total** | **83.33% (330/396)** |

**Threshold set to 70%**, ~13 points below the real 83.33% achieved - enough
margin to absorb minor incidental changes without being toothless; it would
still catch a real regression (e.g. deleting a chunk of controller or service
tests).

### Deliberate, explained gaps

- **`Program.cs` (2/66 lines, ~3%)** - the dominant reason project-wide
  coverage isn't higher. This is ASP.NET composition-root code
  (`WebApplication.CreateBuilder`, `CosmosClient` construction, DI
  registration, `app.Run()`) with no branching logic of its own. It's not
  meaningfully unit-testable without spinning up a real host (e.g.
  `WebApplicationFactory`), which is an integration/functional-test concern,
  not a unit-test one - out of scope for this task. The 2 covered lines are
  the `CosmosDatabaseOptions` record declared at the bottom of the file,
  incidentally exercised via its constructor everywhere else in the suite.
- **`models/Notification.cs` line 42 (`SentAt` property)** - no test data in
  this suite happens to set `SentAt` on a `NotificationItem` explicitly (the
  `GetNotifications` tests only set `Id`/`Message`), so that one
  auto-property's getter/setter is never invoked. Trivial, not a real logic
  gap - there's no logic on that property to miss.

### What's intentionally NOT covered by a dedicated test, and why that's fine

- **Model classes generally** - plain POCOs with auto-properties, no logic to
  exercise. Their high coverage numbers above are incidental (from being
  constructed throughout the other tests), not the product of tests written
  specifically for them.
