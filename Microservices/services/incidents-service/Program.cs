using Azure.Identity;
using Microsoft.Azure.Cosmos;
using incidents_service.Services;
using incidents_service.Middleware;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddApplicationInsightsTelemetry(builder.Configuration);
builder.Services.Configure<TelemetryConfiguration>(config =>
{
    config.TelemetryInitializers.Add(new CloudRoleNameTelemetryInitializer("incidents-service"));
});

// Azure credential - uses managed identity in Azure, CLI locally
var credential = new DefaultAzureCredential(new DefaultAzureCredentialOptions
{
    ManagedIdentityClientId = Environment.GetEnvironmentVariable("AZURE_CLIENT_ID")
});
var cosmosEndpoint = builder.Configuration["COSMOS_ENDPOINT"] 
    ?? Environment.GetEnvironmentVariable("COSMOS_ENDPOINT");
// Cosmos DB
// var cosmosEndpoint = Environment.GetEnvironmentVariable("COSMOS_ENDPOINT");
var cosmosClient = new CosmosClient(cosmosEndpoint, credential);
builder.Services.AddSingleton(cosmosClient);

// Register services
builder.Services.AddSingleton<IIncidentService, IncidentService>();
builder.Services.AddControllers();

var app = builder.Build();

app.UseMiddleware<ErrorHandlingMiddleware>();
app.MapControllers();
app.MapGet("/health", () => new { 
    status = "healthy", 
    service = "incidents-service",
    timestamp = DateTime.UtcNow 
});

app.Run();