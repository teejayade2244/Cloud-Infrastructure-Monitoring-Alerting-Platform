using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Azure.Cosmos;
using Azure.Identity;

namespace incidents_service.IntegrationTests;

// Boots the REAL Program.cs in-memory (real DI wiring, real CosmosClient construction, real
// middleware pipeline) against InfraMonitorTestDB's Incidents container - the .NET equivalent of
// events-service.integration.test.js requiring the real router directly rather than a hand-rolled
// substitute. One instance is shared across all [Fact]s in whichever test class declares
// IClassFixture<IncidentsIntegrationFixture> (xUnit's per-class fixture lifetime).
public class IncidentsIntegrationFixture : IAsyncLifetime
{
    private static readonly string[] RequiredEnvVars = ["COSMOS_ENDPOINT", "COSMOS_TEST_DATABASE"];

    private WebApplicationFactory<Program>? _factory;

    public HttpClient Client { get; private set; } = null!;
    public Container TestContainer { get; private set; } = null!;

    // Every document this fixture's tests create carries this marker (via the Source field) so
    // cleanup can reliably target only what THIS run created, never anything else that might
    // legitimately be in the test database. Timestamp + random suffix keeps concurrent runs from
    // colliding - same scheme events-service's TEST_RUN_ID uses.
    public string TestRunId { get; } =
        $"integration-test-{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}-{Guid.NewGuid().ToString("N")[..6]}";

    public virtual async Task InitializeAsync()
    {
        var missing = RequiredEnvVars
            .Where(name => string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(name)))
            .ToList();
        if (missing.Count > 0)
        {
            throw new InvalidOperationException(
                $"Integration tests require these env vars, missing: {string.Join(", ", missing)}");
        }

        // Program.cs reads COSMOS_DATABASE (defaulting to InfraMonitorDB if unset) at host-build
        // time - point it at the test database before the factory builds the app, same as
        // events-service's integration test overriding COSMOS_DATABASE from COSMOS_TEST_DATABASE
        // before requiring the router.
        Environment.SetEnvironmentVariable(
            "COSMOS_DATABASE", Environment.GetEnvironmentVariable("COSMOS_TEST_DATABASE"));

        _factory = new WebApplicationFactory<Program>();
        Client = _factory.CreateClient();

        // A second, independently-constructed client, built directly here rather than reused
        // from the app's own DI-registered one - deliberately separate from the app's own client
        // construction, so verification/seeding/cleanup never shares a code path with the thing
        // being verified.
        var credential = new DefaultAzureCredential(new DefaultAzureCredentialOptions
        {
            ManagedIdentityClientId = Environment.GetEnvironmentVariable("AZURE_CLIENT_ID"),
        });
        var cosmosClient = new CosmosClient(
            Environment.GetEnvironmentVariable("COSMOS_ENDPOINT"),
            credential,
            new CosmosClientOptions { ConnectionMode = ConnectionMode.Gateway });
        TestContainer = cosmosClient
            .GetDatabase(Environment.GetEnvironmentVariable("COSMOS_TEST_DATABASE"))
            .GetContainer("Incidents");
    }

    public virtual async Task DisposeAsync()
    {
        // Precise, per-test cleanup already happens in each test's own try/finally - this sweep
        // is the safety net for anything a crashed test left behind, matching
        // events.integration.test.js's afterAll sweep (by TEST_RUN_ID prefix, not exact IDs), so
        // stale data can't accumulate across CI runs.
        var query = new QueryDefinition(
            "SELECT c.id, c.severity FROM c WHERE STARTSWITH(c.source, @prefix)")
            .WithParameter("@prefix", "integration-test-");

        // dynamic, not a strongly-typed projection class - the Cosmos SDK's own serializer
        // contract (which this SELECT c.id, c.severity projection goes through) doesn't apply
        // the same JsonPropertyName/JsonProperty mapping Incident.cs needs for its full-document
        // round-trips, and this internal sweep has no reason to fight that for a two-field read.
        using var iterator = TestContainer.GetItemQueryIterator<dynamic>(query);
        while (iterator.HasMoreResults)
        {
            var page = await iterator.ReadNextAsync();
            foreach (var doc in page)
            {
                string id = doc.id;
                string severity = doc.severity;
                try
                {
                    await TestContainer.DeleteItemAsync<dynamic>(id, new PartitionKey(severity));
                }
                catch (CosmosException)
                {
                    // Already gone (e.g. deleted by the test's own cleanup) - fine.
                }
            }
        }

        Client.Dispose();
        _factory?.Dispose();
    }
}
