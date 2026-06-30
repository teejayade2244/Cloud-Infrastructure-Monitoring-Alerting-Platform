using System.Text.Json.Serialization;
using Newtonsoft.Json;

namespace incidents_service.Models
{
    public class NotificationItem
    {
        [JsonPropertyName("id")]
        [JsonProperty("id")]
        public string Id { get; set; } = string.Empty;

        [JsonPropertyName("eventId")]
        [JsonProperty("eventId")]
        public string EventId { get; set; } = string.Empty;

        [JsonPropertyName("type")]
        [JsonProperty("type")]
        public string Type { get; set; } = string.Empty;

        [JsonPropertyName("severity")]
        [JsonProperty("severity")]
        public string Severity { get; set; } = string.Empty;

        [JsonPropertyName("message")]
        [JsonProperty("message")]
        public string Message { get; set; } = string.Empty;

        [JsonPropertyName("source")]
        [JsonProperty("source")]
        public string Source { get; set; } = string.Empty;

        [JsonPropertyName("environment")]
        [JsonProperty("environment")]
        public string Environment { get; set; } = string.Empty;

        [JsonPropertyName("channel")]
        [JsonProperty("channel")]
        public string Channel { get; set; } = string.Empty;

        [JsonPropertyName("sentAt")]
        [JsonProperty("sentAt")]
        public DateTimeOffset? SentAt { get; set; }

        [JsonPropertyName("status")]
        [JsonProperty("status")]
        public string Status { get; set; } = string.Empty;
    }

    public class NotificationListResponse
    {
        public List<NotificationItem> Notifications { get; set; } = new();
        public int Count { get; set; }
    }
}
