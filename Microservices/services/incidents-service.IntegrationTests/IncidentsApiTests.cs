using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Azure.Cosmos;
using incidents_service.Models;

namespace incidents_service.IntegrationTests;

public class IncidentsApiTests : IClassFixture<IncidentsIntegrationFixture>
{
    private static readonly JsonSerializerOptions CaseInsensitive =
        new() { PropertyNameCaseInsensitive = true };

    private readonly IncidentsIntegrationFixture _fixture;

    public IncidentsApiTests(IncidentsIntegrationFixture fixture)
    {
        _fixture = fixture;
    }

    [Fact]
    public async Task PostIncidents_WritesRealDocumentToCosmosDb()
    {
        var request = new CreateIncidentRequest
        {
            Title = "integration test incident",
            Description = "created by incidents-service integration tests",
            Severity = "info",
            Environment = "test",
            Source = _fixture.TestRunId,
        };

        var response = await _fixture.Client.PostAsJsonAsync("/incidents", request);
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);

        var created = await response.Content.ReadFromJsonAsync<Incident>();
        Assert.NotNull(created);

        try
        {
            // Verified via the independently-constructed client, not the app's own - proves the
            // write actually landed in Cosmos DB, not just that the HTTP handler returned 201.
            var read = await _fixture.TestContainer.ReadItemAsync<Incident>(
                created!.Id, new PartitionKey(created.Severity));

            Assert.Equal(created.Id, read.Resource.Id);
            Assert.Equal("integration test incident", read.Resource.Title);
            Assert.Equal("info", read.Resource.Severity);
            Assert.Equal("test", read.Resource.Environment);
            Assert.Equal(_fixture.TestRunId, read.Resource.Source);
            Assert.Equal("open", read.Resource.Status);
        }
        finally
        {
            await _fixture.TestContainer.DeleteItemAsync<Incident>(
                created!.Id, new PartitionKey(created.Severity));
        }
    }

    [Fact]
    public async Task GetIncidentById_ReturnsTheRealDocumentJustWritten()
    {
        var created = await CreateRealIncident(severity: "medium");

        try
        {
            // GetIncident's own query is a Cosmos point-read keyed on id + the severity
            // partition key - a structurally different SDK call than CreateIncidentAsync's
            // write, so a successful create alone doesn't prove this path works.
            var response = await _fixture.Client.GetAsync(
                $"/incidents/{created.Id}?severity={created.Severity}");

            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            var fetched = await response.Content.ReadFromJsonAsync<Incident>();

            Assert.NotNull(fetched);
            Assert.Equal(created.Id, fetched!.Id);
            Assert.Equal(created.Title, fetched.Title);
        }
        finally
        {
            await _fixture.TestContainer.DeleteItemAsync<Incident>(
                created.Id, new PartitionKey(created.Severity));
        }
    }

    [Fact]
    public async Task GetIncidentById_ReturnsNotFoundForANonexistentId()
    {
        var response = await _fixture.Client.GetAsync(
            $"/incidents/{Guid.NewGuid()}?severity=info");

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Fact]
    public async Task PatchIncidents_UpdateGenuinelyPersistsInCosmosDb()
    {
        var created = await CreateRealIncident(severity: "high");

        try
        {
            var update = new UpdateIncidentRequest
            {
                Status = "resolved",
                AssignedTo = "integration-test-runner",
                Message = "closing out via integration test",
                UpdatedBy = "integration-test",
            };

            var response = await _fixture.Client.PatchAsJsonAsync(
                $"/incidents/{created.Id}?severity={created.Severity}", update);

            Assert.Equal(HttpStatusCode.OK, response.StatusCode);

            // Re-read via the independently-constructed client - proves the PATCH's
            // ReplaceItemAsync call genuinely persisted, not just that the handler returned 200
            // with an in-memory object it never actually saved.
            var read = await _fixture.TestContainer.ReadItemAsync<Incident>(
                created.Id, new PartitionKey(created.Severity));

            Assert.Equal("resolved", read.Resource.Status);
            Assert.Equal("integration-test-runner", read.Resource.AssignedTo);
            Assert.NotNull(read.Resource.ResolvedAt);
            Assert.Contains(
                read.Resource.Updates,
                u => u.Message == "closing out via integration test" && u.UpdatedBy == "integration-test");
        }
        finally
        {
            await _fixture.TestContainer.DeleteItemAsync<Incident>(
                created.Id, new PartitionKey(created.Severity));
        }
    }

    [Fact]
    public async Task PatchIncidents_ReturnsNotFoundForANonexistentId()
    {
        var update = new UpdateIncidentRequest { Status = "resolved" };

        var response = await _fixture.Client.PatchAsJsonAsync(
            $"/incidents/{Guid.NewGuid()}?severity=info", update);

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    // Real write, through the real API, used as seed/setup for the tests above rather than
    // seeding directly via TestContainer.CreateItemAsync - this way every test in this class
    // exercises the real POST path at least once, and each test remains self-contained (creates
    // exactly what it needs, cleans up exactly what it created) rather than depending on shared
    // class-level seed data - that pattern is reserved for the filtering tests below, where the
    // whole point is querying across several documents at once.
    private async Task<Incident> CreateRealIncident(string severity)
    {
        var request = new CreateIncidentRequest
        {
            Title = $"integration test incident ({severity})",
            Description = "created by incidents-service integration tests",
            Severity = severity,
            Environment = "test",
            Source = _fixture.TestRunId,
        };

        var response = await _fixture.Client.PostAsJsonAsync("/incidents", request);
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);

        var created = await response.Content.ReadFromJsonAsync<Incident>(CaseInsensitive);
        Assert.NotNull(created);
        return created!;
    }
}
