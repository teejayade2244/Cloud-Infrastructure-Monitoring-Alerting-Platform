using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Cosmos;
using incidents_service.Models;
using incidents_service.Services;
using System.Text.Json;

namespace incidents_service.Controllers
{
    [ApiController]
    [Route("incidents")]
    public class IncidentsController : ControllerBase
    {
        private readonly IIncidentService _incidentService;
        private readonly CosmosClient _cosmosClient;

        public IncidentsController(IIncidentService incidentService, CosmosClient cosmosClient)
{
    _incidentService = incidentService;
    _cosmosClient = cosmosClient;
}

        [HttpGet("/notifications")]
        public async Task<IActionResult> GetNotifications()
        {
            try
            {
                var container = _cosmosClient.GetDatabase("InfraMonitorDB").GetContainer("Notifications");
                var query = "SELECT * FROM c ORDER BY c.sentAt DESC OFFSET 0 LIMIT 50";
                var notifications = new List<NotificationItem>();
                var iterator = container.GetItemQueryIterator<NotificationItem>(query);

                while (iterator.HasMoreResults)
                {
                    var response = await iterator.ReadNextAsync();
                    notifications.AddRange(response);
                }

                return Ok(new NotificationListResponse
                {
                    Notifications = notifications,
                    Count = notifications.Count
                });
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { error = ex.Message });
            }
        }

        [HttpPost]
        public async Task<IActionResult> CreateIncident([FromBody] CreateIncidentRequest request)
        {
            if (string.IsNullOrEmpty(request.Title) ||
                string.IsNullOrEmpty(request.Severity) ||
                string.IsNullOrEmpty(request.Environment))
            {
                return BadRequest(new { error = "Title, severity and environment are required" });
            }

            var incident = await _incidentService.CreateIncidentAsync(request);
            return CreatedAtAction(nameof(GetIncident), 
                new { id = incident.Id, severity = incident.Severity }, incident);
        }

        [HttpGet]
        public async Task<IActionResult> GetIncidents(
            [FromQuery] string? severity,
            [FromQuery] string? status,
            [FromQuery] string? environment)
        {
            var incidents = await _incidentService.GetIncidentsAsync(severity, status, environment);
            return Ok(new { incidents, count = incidents.Count });
        }

        [HttpGet("{id}")]
        public async Task<IActionResult> GetIncident(string id, [FromQuery] string severity)
        {
            var incident = await _incidentService.GetIncidentByIdAsync(id, severity);
            if (incident == null) return NotFound(new { error = "Incident not found" });
            return Ok(incident);
        }

        [HttpPatch("{id}")]
        public async Task<IActionResult> UpdateIncident(
            string id,
            [FromQuery] string severity,
            [FromBody] UpdateIncidentRequest request)
        {
            var incident = await _incidentService.UpdateIncidentAsync(id, severity, request);
            if (incident == null) return NotFound(new { error = "Incident not found" });
            return Ok(incident);
        }
    }
}