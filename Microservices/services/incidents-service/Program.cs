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
// Defaults to the production database name - only set explicitly for a different environment
// (e.g. InfraMonitorProdDB for the production namespace).
var cosmosDatabase = builder.Configuration["COSMOS_DATABASE"]
    ?? Environment.GetEnvironmentVariable("COSMOS_DATABASE")
    ?? "InfraMonitorDB";
builder.Services.AddSingleton(new CosmosDatabaseOptions(cosmosDatabase));
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
app.MapGet("/health", () => new
{
    status = "healthy",
    service = "incidents-service",
    timestamp = DateTime.UtcNow
});

app.Run();

// Small DI-friendly wrapper rather than injecting a bare string - IncidentService and
// IncidentsController both resolve the Cosmos database name from this single source, instead
// of each hardcoding (or independently re-reading) it.
public record CosmosDatabaseOptions(string DatabaseName);