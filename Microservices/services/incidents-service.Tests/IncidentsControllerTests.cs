using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Cosmos;
using Moq;
using incidents_service.Controllers;
using incidents_service.Models;
using incidents_service.Services;

namespace incidents_service.Tests;

public class IncidentsControllerTests
{
    private readonly Mock<IIncidentService> _mockService = new();
    private readonly Mock<Container> _mockContainer = new();
    private readonly IncidentsController _controller;

    public IncidentsControllerTests()
    {
        // Only GetNotifications talks to CosmosClient directly (bypassing IIncidentService
        // entirely) - every other endpoint only needs _mockService, but the constructor still
        // requires a CosmosClient/CosmosDatabaseOptions regardless, so this wiring exists for
        // all tests even though most of them never touch it.
        var mockDatabase = new Mock<Database>();
        mockDatabase.Setup(d => d.GetContainer("Notifications")).Returns(_mockContainer.Object);
        var mockClient = new Mock<CosmosClient>();
        mockClient.Setup(c => c.GetDatabase("TestDb")).Returns(mockDatabase.Object);

        _controller = new IncidentsController(
            _mockService.Object, mockClient.Object, new CosmosDatabaseOptions("TestDb"));
    }

    private static T GetProp<T>(object obj, string name)
    {
        var value = obj.GetType().GetProperty(name)?.GetValue(obj);
        return Assert.IsType<T>(value);
    }

    // ---------- GetNotifications ----------

    [Fact]
    public async Task GetNotifications_Success_ReturnsOkWithNotificationsAndCount()
    {
        const string expectedQuery = "SELECT * FROM c ORDER BY c.sentAt DESC OFFSET 0 LIMIT 50";
        var items = new List<NotificationItem>
        {
            new() { Id = "n1", Message = "first" },
            new() { Id = "n2", Message = "second" },
        };
        var mockIterator = CosmosMockHelpers.MockFeedIterator(items);
        _mockContainer
            .Setup(c => c.GetItemQueryIterator<NotificationItem>(
                It.IsAny<string>(), It.IsAny<string>(), It.IsAny<QueryRequestOptions>()))
            .Returns(mockIterator.Object);

        var result = await _controller.GetNotifications();

        var ok = Assert.IsType<OkObjectResult>(result);
        var body = Assert.IsType<NotificationListResponse>(ok.Value);
        Assert.Equal(2, body.Count);
        Assert.Equal(new[] { "n1", "n2" }, body.Notifications.Select(n => n.Id));
        _mockContainer.Verify(
            c => c.GetItemQueryIterator<NotificationItem>(expectedQuery, null, null), Times.Once);
    }

    [Fact]
    public async Task GetNotifications_CosmosThrows_Returns500WithErrorMessage()
    {
        _mockContainer
            .Setup(c => c.GetItemQueryIterator<NotificationItem>(
                It.IsAny<string>(), It.IsAny<string>(), It.IsAny<QueryRequestOptions>()))
            .Throws(new InvalidOperationException("Cosmos is down"));

        var result = await _controller.GetNotifications();

        var statusResult = Assert.IsType<ObjectResult>(result);
        Assert.Equal(500, statusResult.StatusCode);
        Assert.NotNull(statusResult.Value);
        Assert.Equal("Cosmos is down", GetProp<string>(statusResult.Value!, "error"));
    }

    // ---------- CreateIncident ----------

    [Theory]
    [InlineData("", "critical", "production")]
    [InlineData("Title", "", "production")]
    [InlineData("Title", "critical", "")]
    [InlineData(null, "critical", "production")]
    public async Task CreateIncident_MissingRequiredField_ReturnsBadRequestAndNeverCallsService(
        string? title, string severity, string environment)
    {
        var request = new CreateIncidentRequest
        {
            Title = title ?? string.Empty,
            Severity = severity,
            Environment = environment,
        };

        var result = await _controller.CreateIncident(request);

        var badRequest = Assert.IsType<BadRequestObjectResult>(result);
        Assert.Equal(
            "Title, severity and environment are required", GetProp<string>(badRequest.Value!, "error"));
        _mockService.Verify(s => s.CreateIncidentAsync(It.IsAny<CreateIncidentRequest>()), Times.Never);
    }

    [Fact]
    public async Task CreateIncident_ValidRequest_ReturnsCreatedAtActionWithIncident()
    {
        var request = new CreateIncidentRequest
        {
            Title = "Disk full",
            Severity = "critical",
            Environment = "production",
        };
        var created = new Incident { Id = "new-id", Title = "Disk full", Severity = "critical" };
        _mockService.Setup(s => s.CreateIncidentAsync(request)).ReturnsAsync(created);

        var result = await _controller.CreateIncident(request);

        var createdResult = Assert.IsType<CreatedAtActionResult>(result);
        Assert.Equal(nameof(IncidentsController.GetIncident), createdResult.ActionName);
        Assert.Equal("new-id", createdResult.RouteValues!["id"]);
        Assert.Equal("critical", createdResult.RouteValues!["severity"]);
        Assert.Same(created, createdResult.Value);
    }

    // ---------- GetIncidents ----------

    [Fact]
    public async Task GetIncidents_PassesFiltersThroughAndReturnsOkWithCount()
    {
        var incidents = new List<Incident> { new() { Id = "1" }, new() { Id = "2" }, new() { Id = "3" } };
        _mockService
            .Setup(s => s.GetIncidentsAsync("critical", "open", "production"))
            .ReturnsAsync(incidents);

        var result = await _controller.GetIncidents("critical", "open", "production");

        var ok = Assert.IsType<OkObjectResult>(result);
        Assert.Equal(incidents, GetProp<List<Incident>>(ok.Value!, "incidents"));
        Assert.Equal(3, GetProp<int>(ok.Value!, "count"));
    }

    [Fact]
    public async Task GetIncidents_ServiceThrows_PropagatesRatherThanReturning500Itself()
    {
        // Unlike GetNotifications, this endpoint has no try/catch of its own - a thrown
        // exception here is only ever turned into a 500 by ErrorHandlingMiddleware at the HTTP
        // pipeline level (see ErrorHandlingMiddlewareTests), which a direct controller-method
        // call like this bypasses entirely. So the honest behavior to assert at this level is
        // that the exception really does propagate, not that this method somehow returns 500 on
        // its own.
        _mockService
            .Setup(s => s.GetIncidentsAsync(null, null, null))
            .ThrowsAsync(new InvalidOperationException("Cosmos is down"));

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => _controller.GetIncidents(null, null, null));
    }

    // ---------- GetIncident ----------

    [Fact]
    public async Task GetIncident_Found_ReturnsOkWithIncident()
    {
        var incident = new Incident { Id = "abc", Severity = "high" };
        _mockService.Setup(s => s.GetIncidentByIdAsync("abc", "high")).ReturnsAsync(incident);

        var result = await _controller.GetIncident("abc", "high");

        var ok = Assert.IsType<OkObjectResult>(result);
        Assert.Same(incident, ok.Value);
    }

    [Fact]
    public async Task GetIncident_NotFound_ReturnsNotFoundWithErrorBody()
    {
        _mockService.Setup(s => s.GetIncidentByIdAsync("missing", "high")).ReturnsAsync((Incident?)null);

        var result = await _controller.GetIncident("missing", "high");

        var notFound = Assert.IsType<NotFoundObjectResult>(result);
        Assert.Equal("Incident not found", GetProp<string>(notFound.Value!, "error"));
    }

    [Fact]
    public async Task GetIncident_ServiceThrows_PropagatesRatherThanReturning500Itself()
    {
        _mockService
            .Setup(s => s.GetIncidentByIdAsync("abc", "high"))
            .ThrowsAsync(new InvalidOperationException("Cosmos is down"));

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => _controller.GetIncident("abc", "high"));
    }

    // ---------- UpdateIncident ----------

    [Fact]
    public async Task UpdateIncident_Found_ReturnsOkWithUpdatedIncident()
    {
        var updated = new Incident { Id = "abc", Severity = "high", Status = "resolved" };
        var request = new UpdateIncidentRequest { Status = "resolved" };
        _mockService.Setup(s => s.UpdateIncidentAsync("abc", "high", request)).ReturnsAsync(updated);

        var result = await _controller.UpdateIncident("abc", "high", request);

        var ok = Assert.IsType<OkObjectResult>(result);
        Assert.Same(updated, ok.Value);
    }

    [Fact]
    public async Task UpdateIncident_NotFound_ReturnsNotFoundWithErrorBody()
    {
        var request = new UpdateIncidentRequest { Status = "resolved" };
        _mockService
            .Setup(s => s.UpdateIncidentAsync("missing", "high", request))
            .ReturnsAsync((Incident?)null);

        var result = await _controller.UpdateIncident("missing", "high", request);

        var notFound = Assert.IsType<NotFoundObjectResult>(result);
        Assert.Equal("Incident not found", GetProp<string>(notFound.Value!, "error"));
    }

    [Fact]
    public async Task UpdateIncident_ServiceThrows_PropagatesRatherThanReturning500Itself()
    {
        var request = new UpdateIncidentRequest { Status = "resolved" };
        _mockService
            .Setup(s => s.UpdateIncidentAsync("abc", "high", request))
            .ThrowsAsync(new InvalidOperationException("Cosmos is down"));

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => _controller.UpdateIncident("abc", "high", request));
    }
}
