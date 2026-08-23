using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Azure.Cosmos;
using incidents_service.Models;

namespace incidents_service.IntegrationTests;

// Seeds a fixed set of documents once, shared across every [Fact] in
// GetIncidentsFilteringTests - the .NET equivalent of events.integration.test.js's nested
// describe("GET /events filtering") with its own beforeAll/afterAll. A separate fixture (rather
// than reusing IncidentsIntegrationFixture directly) because seeding needs to happen exactly
// once per test CLASS, not per test - xUnit gives IClassFixture<T> one instance per class already,
// so overriding Initialize/DisposeAsync here to seed-then-call-base and
// delete-then-call-base is what makes that "once per class" property land in the right place.
public class GetIncidentsFilteringFixture : IncidentsIntegrationFixture
{
    public List<Incident> Seeded { get; } = new();

    public override async Task InitializeAsync()
    {
        await base.InitializeAsync();

        var seeds = new[]
        {
            new Incident
            {
                Id = $"{TestRunId}-a",
                Title = "seeded incident A",
                Severity = "critical",
                Status = "open",
                Environment = "production",
                Source = TestRunId,
            },
            new Incident
            {
                Id = $"{TestRunId}-b",
                Title = "seeded incident B",
                Severity = "high",
                Status = "resolved",
                Environment = "staging",
                Source = TestRunId,
            },
            new Incident
            {
                Id = $"{TestRunId}-c",
                Title = "seeded incident C",
                Severity = "critical",
                Status = "resolved",
                Environment = "production",
                Source = TestRunId,
            },
        };

        foreach (var incident in seeds)
        {
            await TestContainer.CreateItemAsync(incident, new PartitionKey(incident.Severity));
            Seeded.Add(incident);
        }
    }

    public override async Task DisposeAsync()
    {
        foreach (var incident in Seeded)
        {
            try
            {
                await TestContainer.DeleteItemAsync<Incident>(
                    incident.Id, new PartitionKey(incident.Severity));
            }
            catch (CosmosException)
            {
                // Already gone - fine.
            }
        }

        await base.DisposeAsync();
    }
}

public class GetIncidentsFilteringTests : IClassFixture<GetIncidentsFilteringFixture>
{
    private static readonly JsonSerializerOptions CaseInsensitive =
        new() { PropertyNameCaseInsensitive = true };

    private readonly GetIncidentsFilteringFixture _fixture;

    public GetIncidentsFilteringTests(GetIncidentsFilteringFixture fixture)
    {
        _fixture = fixture;
    }

    private record IncidentListResponse(List<Incident> Incidents, int Count);

    private async Task<List<string>> GetIncidentIds(string queryString)
    {
        var response = await _fixture.Client.GetAsync($"/incidents{queryString}");
        response.EnsureSuccessStatusCode();

        var body = await response.Content.ReadFromJsonAsync<IncidentListResponse>(CaseInsensitive);
        Assert.NotNull(body);
        return body!.Incidents.Select(i => i.Id).ToList();
    }

    [Fact]
    public async Task FiltersBySeverity()
    {
        var ids = await GetIncidentIds("?severity=critical");

        Assert.Contains(_fixture.Seeded[0].Id, ids); // A: critical
        Assert.Contains(_fixture.Seeded[2].Id, ids); // C: critical
        Assert.DoesNotContain(_fixture.Seeded[1].Id, ids); // B: high
    }

    [Fact]
    public async Task FiltersByStatus()
    {
        var ids = await GetIncidentIds("?status=resolved");

        Assert.Contains(_fixture.Seeded[1].Id, ids); // B: resolved
        Assert.Contains(_fixture.Seeded[2].Id, ids); // C: resolved
        Assert.DoesNotContain(_fixture.Seeded[0].Id, ids); // A: open
    }

    [Fact]
    public async Task FiltersByEnvironment()
    {
        var ids = await GetIncidentIds("?environment=staging");

        Assert.Contains(_fixture.Seeded[1].Id, ids); // B: staging
        Assert.DoesNotContain(_fixture.Seeded[0].Id, ids); // A: production
        Assert.DoesNotContain(_fixture.Seeded[2].Id, ids); // C: production
    }

    [Fact]
    public async Task CombinesSeverityAndStatusFilters()
    {
        var ids = await GetIncidentIds("?severity=critical&status=resolved");

        Assert.Contains(_fixture.Seeded[2].Id, ids); // C: critical + resolved
        Assert.DoesNotContain(_fixture.Seeded[0].Id, ids); // A: critical, but open
        Assert.DoesNotContain(_fixture.Seeded[1].Id, ids); // B: resolved, but high
    }
}
