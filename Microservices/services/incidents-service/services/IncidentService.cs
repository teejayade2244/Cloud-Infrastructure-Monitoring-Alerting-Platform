using System.Net;
using Microsoft.Azure.Cosmos;
using incidents_service.Models;

namespace incidents_service.Services
{
    public interface IIncidentService
    {
        Task<Incident> CreateIncidentAsync(CreateIncidentRequest request);
        Task<List<Incident>> GetIncidentsAsync(string? severity, string? status, string? environment);
        Task<Incident?> GetIncidentByIdAsync(string id, string severity);
        Task<Incident?> UpdateIncidentAsync(string id, string severity, UpdateIncidentRequest request);
    }

public class IncidentService : IIncidentService
{
    private readonly Container _container;

    public IncidentService(CosmosClient cosmosClient)
    {
        _container = cosmosClient
            .GetDatabase("InfraMonitorDB")
            .GetContainer("Incidents");
    }

        public async Task<Incident> CreateIncidentAsync(CreateIncidentRequest request)
        {
            var incident = new Incident
            {
                EventId = request.EventId,
                Title = request.Title,
                Description = request.Description,
                Severity = request.Severity,
                Environment = request.Environment,
                Source = request.Source,
                Status = "open"
            };

            await _container.CreateItemAsync(incident, new PartitionKey(incident.Severity));
            return incident;
        }

   public async Task<List<Incident>> GetIncidentsAsync(string? severity, string? status, string? environment)
{
    var query = "SELECT * FROM c WHERE 1=1";
    if (!string.IsNullOrEmpty(severity)) query += $" AND c.severity = '{severity}'";
    if (!string.IsNullOrEmpty(status)) query += $" AND c.status = '{status}'";
    if (!string.IsNullOrEmpty(environment)) query += $" AND c.environment = '{environment}'";
    query += " ORDER BY c.createdAt DESC OFFSET 0 LIMIT 50";

    var incidents = new List<Incident>();
    var iterator = _container.GetItemQueryIterator<Incident>(query);
    while (iterator.HasMoreResults)
    {
        var response = await iterator.ReadNextAsync();
        incidents.AddRange(response);
    }
    return incidents;
}
        public async Task<Incident?> GetIncidentByIdAsync(string id, string severity)
        {
            try
            {
                var response = await _container.ReadItemAsync<Incident>(id, new PartitionKey(severity));
                return response.Resource;
            }
            catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
            {
                return null;
            }
        }

        public async Task<Incident?> UpdateIncidentAsync(string id, string severity, UpdateIncidentRequest request)
        {
            var incident = await GetIncidentByIdAsync(id, severity);
            if (incident == null) return null;

            if (!string.IsNullOrEmpty(request.Status))
                incident.Status = request.Status;

            if (!string.IsNullOrEmpty(request.AssignedTo))
                incident.AssignedTo = request.AssignedTo;

            if (request.Status == "resolved")
                incident.ResolvedAt = DateTime.UtcNow;

            incident.Updates.Add(new IncidentUpdate
            {
                Message = request.Message,
                UpdatedBy = request.UpdatedBy,
                Status = request.Status
            });

            await _container.ReplaceItemAsync(incident, id, new PartitionKey(severity));
            return incident;
        }
    }
}