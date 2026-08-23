using Xunit;

// Confirmed the hard way: IncidentsApiTests and GetIncidentsFilteringTests each construct their
// own WebApplicationFactory<Program> (via IncidentsIntegrationFixture/GetIncidentsFilteringFixture),
// which means Program.cs's real AddApplicationInsightsTelemetry() call runs concurrently across
// two hosts in the same process by default - xUnit parallelizes different test CLASSES unless
// told otherwise. That collision produced a real failure inside the Cosmos SDK's own
// account-discovery call: "The collection already contains item with same key
// 'microsoft.sample_rate'" - a duplicate-registration race in Application Insights' global
// telemetry/diagnostics state, not a bug in the test logic or the app itself. Disabling
// cross-class parallelization for this assembly serializes the two WebApplicationFactory
// instances instead of fixing (or working around) Program.cs's real, production
// AddApplicationInsightsTelemetry() call, which is correct as-is for its actual deployment target.
[assembly: CollectionBehavior(DisableTestParallelization = true)]
