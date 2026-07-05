const { CosmosClient } = require("@azure/cosmos")
const { ServiceBusClient } = require("@azure/service-bus")
const { ClientSecretCredential, DefaultAzureCredential } = require("@azure/identity")

function getAzureConfiguration(env = process.env) {
    const cosmosEndpoint = env.COSMOS_ENDPOINT?.trim() || ""
    const serviceBusNamespace = env.SERVICEBUS_NAMESPACE?.trim() || ""
    const cosmosConnectionString = env.COSMOS_CONNECTION_STRING?.trim() || ""
    const serviceBusConnectionString = env.SERVICEBUS_CONNECTION_STRING?.trim() || ""
    const clientId = env.AZURE_CLIENT_ID?.trim() || ""
    const tenantId = env.AZURE_TENANT_ID?.trim() || ""
    const clientSecret = env.AZURE_CLIENT_SECRET?.trim() || ""

    if (!cosmosEndpoint && !cosmosConnectionString) {
        throw new Error(
            "Missing Cosmos DB configuration. Set COSMOS_ENDPOINT or COSMOS_CONNECTION_STRING.",
        )
    }

    if (!serviceBusNamespace && !serviceBusConnectionString) {
        throw new Error(
            "Missing Service Bus configuration. Set SERVICEBUS_NAMESPACE or SERVICEBUS_CONNECTION_STRING.",
        )
    }

    return {
        cosmosEndpoint,
        serviceBusNamespace,
        cosmosConnectionString,
        serviceBusConnectionString,
        clientId,
        tenantId,
        clientSecret,
        authMode:
            cosmosConnectionString || serviceBusConnectionString
                ? "connection-string"
                : "azure-identity",
    }
}

function createCredential(env = process.env) {
    const clientId = env.AZURE_CLIENT_ID?.trim() || ""
    const tenantId = env.AZURE_TENANT_ID?.trim() || ""
    const clientSecret = env.AZURE_CLIENT_SECRET?.trim() || ""

    if (clientId && tenantId && clientSecret) {
        return new ClientSecretCredential(tenantId, clientId, clientSecret)
    }

    return new DefaultAzureCredential({
        managedIdentityClientId: clientId || undefined,
        excludeInteractiveBrowserCredential: true,
    })
}

function createAzureClients(env = process.env) {
    const config = getAzureConfiguration(env)

    const cosmosClient = config.cosmosConnectionString
        ? new CosmosClient({ connectionString: config.cosmosConnectionString })
        : new CosmosClient({
              endpoint: config.cosmosEndpoint,
              aadCredentials: createCredential(env),
          })

    const database = cosmosClient.database("InfraMonitorDB")
    const eventsContainer = database.container("Events")

    const serviceBusClient = config.serviceBusConnectionString
        ? new ServiceBusClient(config.serviceBusConnectionString)
        : new ServiceBusClient(config.serviceBusNamespace, createCredential(env), {
              transportType: "AmqpWebSockets",
          })

    return {
        ...config,
        cosmosClient,
        database,
        eventsContainer,
        serviceBusClient,
    }
}

module.exports = {
    createAzureClients,
    createCredential,
    getAzureConfiguration,
}
