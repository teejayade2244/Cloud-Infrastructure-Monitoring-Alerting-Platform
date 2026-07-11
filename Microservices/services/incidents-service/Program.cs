using Azure.Identity;
using Microsoft.Azure.Cosmos;
using incidents_service.Services;
using incidents_service.Middleware;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddApplicationInsightsTelemetry(builder.Configuration);

// Azure credential - uses managed identity in Azure, CLI locally
var credential = new DefaultAzureCredential(new DefaultAzureCredentialOptions
{
    ManagedIdentityClientId = Environment.GetEnvironmentVariable("AZURE_CLIENT_ID")
});
var cosmosEndpoint = builder.Configuration["COSMOS_ENDPOINT"] 
    ?? Environment.GetEnvironmentVariable("COSMOS_ENDPOINT");
// Cosmos DB
// var cosmosEndpoint = Environment.GetEnvironmentVariable("COSMOS_ENDPOINT");
// Direct/RNTBD mode (the SDK default) connects straight to backend replicas over ports
// 10250-10255, which the NSGs in this project don't open (only 443 is allowed outbound to
// data-subnet). Gateway mode routes everything through the Cosmos DB gateway over HTTPS/443.
var cosmosClient = new CosmosClient(
    cosmosEndpoint,
    credential,
    new CosmosClientOptions
    {
        ConnectionMode = ConnectionMode.Gateway
    }
);
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