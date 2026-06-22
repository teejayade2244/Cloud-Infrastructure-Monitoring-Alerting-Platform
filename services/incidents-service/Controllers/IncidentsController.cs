using Microsoft.AspNetCore.Mvc;
using incidents_service.Models;
using incidents_service.Services;

namespace incidents_service.Controllers
{
    [ApiController]
    [Route("incidents")]
    public class IncidentsController : ControllerBase
    {
        private readonly IIncidentService _incidentService;

        public IncidentsController(IIncidentService incidentService)
        {
            _incidentService = incidentService;
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