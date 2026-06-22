namespace incidents_service.Models
{
    public class Incident
    {
        public string Id { get; set; } = Guid.NewGuid().ToString();
        public string EventId { get; set; } = string.Empty;
        public string Title { get; set; } = string.Empty;
        public string Description { get; set; } = string.Empty;
        public string Severity { get; set; } = string.Empty;
        public string Environment { get; set; } = string.Empty;
        public string Status { get; set; } = "open";
        public string AssignedTo { get; set; } = string.Empty;
        public string Source { get; set; } = string.Empty;
        public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
        public DateTime? ResolvedAt { get; set; }
        public List<IncidentUpdate> Updates { get; set; } = new();
    }

    public class IncidentUpdate
    {
        public string Message { get; set; } = string.Empty;
        public string UpdatedBy { get; set; } = string.Empty;
        public string Status { get; set; } = string.Empty;
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