using System.Net;
using Microsoft.Azure.Cosmos;
using Moq;
using incidents_service.Models;
using incidents_service.Services;

namespace incidents_service.Tests;

public class IncidentServiceTests
{
    private readonly Mock<Container> _mockContainer = new();
    private readonly IncidentService _service;

    public IncidentServiceTests()
    {
        var mockDatabase = new Mock<Database>();
        mockDatabase.Setup(d => d.GetContainer("Incidents")).Returns(_mockContainer.Object);

        var mockClient = new Mock<CosmosClient>();
        mockClient.Setup(c => c.GetDatabase("TestDb")).Returns(mockDatabase.Object);

        _service = new IncidentService(mockClient.Object, new CosmosDatabaseOptions("TestDb"));
    }

    // ---------- CreateIncidentAsync ----------

    [Fact]
    public async Task CreateIncidentAsync_MapsRequestFieldsAndDefaultsStatusToOpen()
    {
        var request = new CreateIncidentRequest
        {
            EventId = "evt-1",
            Title = "Disk full",
            Description = "root volume at 98%",
            Severity = "critical",
            Environment = "production",
            Source = "monitoring-agent",
        };

        Incident? created = null;
        _mockContainer
            .Setup(c => c.CreateItemAsync(
                It.IsAny<Incident>(),
                It.Is<PartitionKey?>(pk => pk == new PartitionKey("critical")),
                null,
                default))
            .Callback<Incident, PartitionKey?, ItemRequestOptions?, CancellationToken>((i, _, _, _) => created = i)
            .ReturnsAsync(Mock.Of<ItemResponse<Incident>>());

        var result = await _service.CreateIncidentAsync(request);

        Assert.Equal("evt-1", result.EventId);
        Assert.Equal("Disk full", result.Title);
        Assert.Equal("root volume at 98%", result.Description);
        Assert.Equal("critical", result.Severity);
        Assert.Equal("production", result.Environment);
        Assert.Equal("monitoring-agent", result.Source);
        Assert.Equal("open", result.Status);
        // Confirms the write actually happened, not just that the returned object looks right -
        // same reasoning as events-service's "verified via the independently-constructed client"
        // integration test comment, applied here via the mock's own call verification instead.
        Assert.NotNull(created);
        Assert.Equal("open", created!.Status);
        _mockContainer.Verify(
            c => c.CreateItemAsync(It.IsAny<Incident>(), new PartitionKey("critical"), null, default),
            Times.Once);
    }

    // ---------- GetIncidentsAsync ----------

    [Fact]
    public async Task GetIncidentsAsync_NoFilters_UsesBaseQuery()
    {
        const string expectedQuery = "SELECT * FROM c WHERE 1=1 ORDER BY c.createdAt DESC OFFSET 0 LIMIT 50";
        var mockIterator = CosmosMockHelpers.MockFeedIterator(new List<Incident>());
        _mockContainer
            .Setup(c => c.GetItemQueryIterator<Incident>(
                It.IsAny<string>(), It.IsAny<string>(), It.IsAny<QueryRequestOptions>()))
            .Returns(mockIterator.Object);

        await _service.GetIncidentsAsync(null, null, null);

        _mockContainer.Verify(
            c => c.GetItemQueryIterator<Incident>(expectedQuery, null, null), Times.Once);
    }

    [Fact]
    public async Task GetIncidentsAsync_SeverityFilterOnly_AddsSeverityClause()
    {
        const string expectedQuery =
            "SELECT * FROM c WHERE 1=1 AND c.severity = 'critical' ORDER BY c.createdAt DESC OFFSET 0 LIMIT 50";
        var mockIterator = CosmosMockHelpers.MockFeedIterator(new List<Incident>());
        _mockContainer
            .Setup(c => c.GetItemQueryIterator<Incident>(
                It.IsAny<string>(), It.IsAny<string>(), It.IsAny<QueryRequestOptions>()))
            .Returns(mockIterator.Object);

        await _service.GetIncidentsAsync("critical", null, null);

        _mockContainer.Verify(
            c => c.GetItemQueryIterator<Incident>(expectedQuery, null, null), Times.Once);
    }

    [Fact]
    public async Task GetIncidentsAsync_StatusFilterOnly_AddsStatusClause()
    {
        const string expectedQuery =
            "SELECT * FROM c WHERE 1=1 AND c.status = 'open' ORDER BY c.createdAt DESC OFFSET 0 LIMIT 50";
        var mockIterator = CosmosMockHelpers.MockFeedIterator(new List<Incident>());
        _mockContainer
            .Setup(c => c.GetItemQueryIterator<Incident>(
                It.IsAny<string>(), It.IsAny<string>(), It.IsAny<QueryRequestOptions>()))
            .Returns(mockIterator.Object);

        await _service.GetIncidentsAsync(null, "open", null);

        _mockContainer.Verify(
            c => c.GetItemQueryIterator<Incident>(expectedQuery, null, null), Times.Once);
    }

    [Fact]
    public async Task GetIncidentsAsync_EnvironmentFilterOnly_AddsEnvironmentClause()
    {
        const string expectedQuery =
            "SELECT * FROM c WHERE 1=1 AND c.environment = 'staging' ORDER BY c.createdAt DESC OFFSET 0 LIMIT 50";
        var mockIterator = CosmosMockHelpers.MockFeedIterator(new List<Incident>());
        _mockContainer
            .Setup(c => c.GetItemQueryIterator<Incident>(
                It.IsAny<string>(), It.IsAny<string>(), It.IsAny<QueryRequestOptions>()))
            .Returns(mockIterator.Object);

        await _service.GetIncidentsAsync(null, null, "staging");

        _mockContainer.Verify(
            c => c.GetItemQueryIterator<Incident>(expectedQuery, null, null), Times.Once);
    }

    [Fact]
    public async Task GetIncidentsAsync_AllFilters_CombinesInSeverityStatusEnvironmentOrder()
    {
        const string expectedQuery =
            "SELECT * FROM c WHERE 1=1 AND c.severity = 'critical' AND c.status = 'open' " +
            "AND c.environment = 'production' ORDER BY c.createdAt DESC OFFSET 0 LIMIT 50";
        var mockIterator = CosmosMockHelpers.MockFeedIterator(new List<Incident>());
        _mockContainer
            .Setup(c => c.GetItemQueryIterator<Incident>(
                It.IsAny<string>(), It.IsAny<string>(), It.IsAny<QueryRequestOptions>()))
            .Returns(mockIterator.Object);

        await _service.GetIncidentsAsync("critical", "open", "production");

        _mockContainer.Verify(
            c => c.GetItemQueryIterator<Incident>(expectedQuery, null, null), Times.Once);
    }

    [Fact]
    public async Task GetIncidentsAsync_ReturnsAllItemsFromTheIterator()
    {
        var items = new List<Incident>
        {
            new() { Id = "1", Title = "A" },
            new() { Id = "2", Title = "B" },
        };
        var mockIterator = CosmosMockHelpers.MockFeedIterator(items);
        _mockContainer
            .Setup(c => c.GetItemQueryIterator<Incident>(
                It.IsAny<string>(), It.IsAny<string>(), It.IsAny<QueryRequestOptions>()))
            .Returns(mockIterator.Object);

        var result = await _service.GetIncidentsAsync(null, null, null);

        Assert.Equal(2, result.Count);
        Assert.Equal(new[] { "1", "2" }, result.Select(i => i.Id));
    }

    // ---------- GetIncidentByIdAsync ----------

    [Fact]
    public async Task GetIncidentByIdAsync_ExistingIncident_ReturnsIt()
    {
        var incident = new Incident { Id = "abc", Severity = "high", Title = "Found me" };
        var mockResponse = new Mock<ItemResponse<Incident>>();
        mockResponse.Setup(r => r.Resource).Returns(incident);
        _mockContainer
            .Setup(c => c.ReadItemAsync<Incident>("abc", new PartitionKey("high"), null, default))
            .ReturnsAsync(mockResponse.Object);

        var result = await _service.GetIncidentByIdAsync("abc", "high");

        Assert.NotNull(result);
        Assert.Equal("Found me", result!.Title);
    }

    [Fact]
    public async Task GetIncidentByIdAsync_NotFound_ReturnsNullInsteadOfThrowing()
    {
        _mockContainer
            .Setup(c => c.ReadItemAsync<Incident>("missing", new PartitionKey("high"), null, default))
            .ThrowsAsync(CosmosMockHelpers.NotFoundException());

        var result = await _service.GetIncidentByIdAsync("missing", "high");

        Assert.Null(result);
    }

    [Fact]
    public async Task GetIncidentByIdAsync_NonNotFoundCosmosException_PropagatesRatherThanBeingSwallowed()
    {
        // The catch clause is scoped with `when (ex.StatusCode == HttpStatusCode.NotFound)` -
        // confirms a different Cosmos failure (e.g. a real outage) surfaces as a real error
        // instead of silently looking identical to "incident doesn't exist".
        _mockContainer
            .Setup(c => c.ReadItemAsync<Incident>("abc", new PartitionKey("high"), null, default))
            .ThrowsAsync(CosmosMockHelpers.ServiceUnavailableException());

        var ex = await Assert.ThrowsAsync<CosmosException>(
            () => _service.GetIncidentByIdAsync("abc", "high"));
        Assert.Equal(HttpStatusCode.ServiceUnavailable, ex.StatusCode);
    }

    // ---------- UpdateIncidentAsync ----------

    private void SetUpExistingIncident(Incident incident)
    {
        var mockResponse = new Mock<ItemResponse<Incident>>();
        mockResponse.Setup(r => r.Resource).Returns(incident);
        _mockContainer
            .Setup(c => c.ReadItemAsync<Incident>(incident.Id, new PartitionKey(incident.Severity), null, default))
            .ReturnsAsync(mockResponse.Object);
    }

    [Fact]
    public async Task UpdateIncidentAsync_UnknownId_ReturnsNullAndNeverCallsReplace()
    {
        _mockContainer
            .Setup(c => c.ReadItemAsync<Incident>("missing", new PartitionKey("high"), null, default))
            .ThrowsAsync(CosmosMockHelpers.NotFoundException());

        var result = await _service.UpdateIncidentAsync(
            "missing", "high", new UpdateIncidentRequest { Status = "resolved" });

        Assert.Null(result);
        _mockContainer.Verify(
            c => c.ReplaceItemAsync(It.IsAny<Incident>(), It.IsAny<string>(), It.IsAny<PartitionKey?>(), null, default),
            Times.Never);
    }

    [Fact]
    public async Task UpdateIncidentAsync_UpdatesStatusAndAppendsAnUpdateEntry()
    {
        var incident = new Incident { Id = "abc", Severity = "high", Status = "open" };
        SetUpExistingIncident(incident);
        _mockContainer
            .Setup(c => c.ReplaceItemAsync(It.IsAny<Incident>(), "abc", new PartitionKey("high"), null, default))
            .ReturnsAsync(Mock.Of<ItemResponse<Incident>>());

        var request = new UpdateIncidentRequest
        {
            Status = "investigating",
            Message = "looking into it",
            UpdatedBy = "oncall-engineer",
        };
        var result = await _service.UpdateIncidentAsync("abc", "high", request);

        Assert.NotNull(result);
        Assert.Equal("investigating", result!.Status);
        Assert.Equal(string.Empty, result.AssignedTo); // untouched - request.AssignedTo was empty
        Assert.Single(result.Updates);
        Assert.Equal("looking into it", result.Updates[0].Message);
        Assert.Equal("oncall-engineer", result.Updates[0].UpdatedBy);
        Assert.Equal("investigating", result.Updates[0].Status);
        _mockContainer.Verify(
            c => c.ReplaceItemAsync(It.IsAny<Incident>(), "abc", new PartitionKey("high"), null, default),
            Times.Once);
    }

    [Fact]
    public async Task UpdateIncidentAsync_UpdatesAssignedToWhenProvided()
    {
        var incident = new Incident { Id = "abc", Severity = "high", AssignedTo = "" };
        SetUpExistingIncident(incident);
        _mockContainer
            .Setup(c => c.ReplaceItemAsync(It.IsAny<Incident>(), "abc", new PartitionKey("high"), null, default))
            .ReturnsAsync(Mock.Of<ItemResponse<Incident>>());

        var result = await _service.UpdateIncidentAsync(
            "abc", "high", new UpdateIncidentRequest { AssignedTo = "jane" });

        Assert.Equal("jane", result!.AssignedTo);
    }

    [Fact]
    public async Task UpdateIncidentAsync_StatusResolved_SetsResolvedAtToNow()
    {
        var incident = new Incident { Id = "abc", Severity = "high", ResolvedAt = null };
        SetUpExistingIncident(incident);
        _mockContainer
            .Setup(c => c.ReplaceItemAsync(It.IsAny<Incident>(), "abc", new PartitionKey("high"), null, default))
            .ReturnsAsync(Mock.Of<ItemResponse<Incident>>());

        var before = DateTime.UtcNow;
        var result = await _service.UpdateIncidentAsync(
            "abc", "high", new UpdateIncidentRequest { Status = "resolved" });
        var after = DateTime.UtcNow;

        Assert.NotNull(result!.ResolvedAt);
        Assert.InRange(result.ResolvedAt!.Value, before, after);
    }

    [Fact]
    public async Task UpdateIncidentAsync_StatusNotResolved_LeavesResolvedAtUntouched()
    {
        var incident = new Incident { Id = "abc", Severity = "high", ResolvedAt = null };
        SetUpExistingIncident(incident);
        _mockContainer
            .Setup(c => c.ReplaceItemAsync(It.IsAny<Incident>(), "abc", new PartitionKey("high"), null, default))
            .ReturnsAsync(Mock.Of<ItemResponse<Incident>>());

        var result = await _service.UpdateIncidentAsync(
            "abc", "high", new UpdateIncidentRequest { Status = "investigating" });

        Assert.Null(result!.ResolvedAt);
    }
}
