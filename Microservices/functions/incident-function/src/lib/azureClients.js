const { CosmosClient } = require("@azure/cosmos")
const { ServiceBusClient } = require("@azure/service-bus")
const { DefaultAzureCredential } = require("@azure/identity")

function createCredential(env = process.env) {
    const clientId = env.AZURE_CLIENT_ID?.trim() || ""

    return new DefaultAzureCredential({
        managedIdentityClientId: clientId || undefined,
        excludeInteractiveBrowserCredential: true,
    })
}

function createCosmosContainer(containerName, env = process.env) {
    const cosmosEndpoint = env.COSMOS_ENDPOINT?.trim()
    if (!cosmosEndpoint) {
        throw new Error("Missing COSMOS_ENDPOINT")
    }

    const client = new CosmosClient({
        endpoint: cosmosEndpoint,
        aadCredentials: createCredential(env),
    })

    // Defaults to the production database name - only set explicitly when this job is deployed
    // against a different environment (e.g. InfraMonitorProdDB for the production namespace).
    const databaseName = env.COSMOS_DATABASE?.trim() || "InfraMonitorDB"
    return client.database(databaseName).container(containerName)
}

function createServiceBusClient(env = process.env) {
    const namespace = env.SERVICEBUS_NAMESPACE?.trim()
    if (!namespace) {
        throw new Error("Missing SERVICEBUS_NAMESPACE")
    }

    return new ServiceBusClient(namespace, createCredential(env), {
        transportType: "AmqpWebSockets",
    })
}

module.exports = {
    createCredential,
    createCosmosContainer,
    createServiceBusClient,
}
