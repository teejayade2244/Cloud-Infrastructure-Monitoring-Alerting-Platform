using System.Text.Json.Serialization;
using Newtonsoft.Json;

namespace incidents_service.Models
{
    public class Incident
    {
        [JsonPropertyName("id")]
        [JsonProperty("id")]
        public string Id { get; set; } = Guid.NewGuid().ToString();

        [JsonPropertyName("eventId")]
        [JsonProperty("eventId")]
        public string EventId { get; set; } = string.Empty;

        [JsonPropertyName("title")]
        [JsonProperty("title")]
        public string Title { get; set; } = string.Empty;

        [JsonPropertyName("description")]
        [JsonProperty("description")]
        public string Description { get; set; } = string.Empty;

        [JsonPropertyName("severity")]
        [JsonProperty("severity")]
        public string Severity { get; set; } = string.Empty;

        [JsonPropertyName("environment")]
        [JsonProperty("environment")]
        public string Environment { get; set; } = string.Empty;

        [JsonPropertyName("status")]
        [JsonProperty("status")]
        public string Status { get; set; } = "open";

        [JsonPropertyName("assignedTo")]
        [JsonProperty("assignedTo")]
        public string AssignedTo { get; set; } = string.Empty;

        [JsonPropertyName("source")]
        [JsonProperty("source")]
        public string Source { get; set; } = string.Empty;

        [JsonPropertyName("createdAt")]
        [JsonProperty("createdAt")]
        public DateTime CreatedAt { get; set; } = DateTime.UtcNow;

        [JsonPropertyName("resolvedAt")]
        [JsonProperty("resolvedAt")]
        public DateTime? ResolvedAt { get; set; }

        [JsonPropertyName("updates")]
        [JsonProperty("updates")]
        public List<IncidentUpdate> Updates { get; set; } = new();
    }

    public class IncidentUpdate
    {
        [JsonPropertyName("message")]
        [JsonProperty("message")]
        public string Message { get; set; } = string.Empty;

        [JsonPropertyName("updatedBy")]
        [JsonProperty("updatedBy")]
        public string UpdatedBy { get; set; } = string.Empty;

        [JsonPropertyName("status")]
        [JsonProperty("status")]
        public string Status { get; set; } = string.Empty;

        [JsonPropertyName("timestamp")]
        [JsonProperty("timestamp")]
        public DateTime Timestamp { get; set; } = DateTime.UtcNow;
    }

    public class CreateIncidentRequest
    {
        public string EventId { get; set; } = string.Empty;
        public string Title { get; set; } = string.Empty;
        public string Description { get; set; } = string.Empty;
        public string Severity { get; set; } = string.Empty;
        public string Environment { get; set; } = string.Empty;
        public string Source { get; set; } = string.Empty;
    }

    public class UpdateIncidentRequest
    {
        public string Status { get; set; } = string.Empty;
        public string AssignedTo { get; set; } = string.Empty;
        public string Message { get; set; } = string.Empty;
        public string UpdatedBy { get; set; } = string.Empty;
    }
}