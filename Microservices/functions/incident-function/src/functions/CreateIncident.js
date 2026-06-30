const { app } = require("@azure/functions")
const { CosmosClient } = require("@azure/cosmos")
const { DefaultAzureCredential } = require("@azure/identity")

const credential = new DefaultAzureCredential()
const cosmosClient = new CosmosClient({
    endpoint: process.env.COSMOS_ENDPOINT,
    aadCredentials: credential
})
const container = cosmosClient.database("InfraMonitorDB").container("Incidents")

app.serviceBusTopic("CreateIncident", {
    connection: "SERVICEBUS_CONNECTION",
    topicName: "infrastructure-events",
    subscriptionName: "create-incident",
    handler: async (message, context) => {
        context.log("CreateIncident triggered")
        context.log("Event received:", JSON.stringify(message, null, 2))

        const event = message

        const incident = {
            id: `INC-${Date.now()}`,
            eventId: event.id,
            title: `${event.type.toUpperCase()}: ${event.message}`,
            description: `Auto-created from ${event.type} event in ${event.environment}`,
            severity: event.severity,
            environment: event.environment,
            source: event.source,
            status: "open",
            assignedTo: "",
            createdAt: new Date().toISOString(),
            resolvedAt: null,
            updates: []
        }

        await container.items.create(incident)
        context.log(`Incident created: ${incident.id} for event ${event.id}`)
    }
})