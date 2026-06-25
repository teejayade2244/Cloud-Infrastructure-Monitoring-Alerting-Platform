const { app } = require("@azure/functions")
const { CosmosClient } = require("@azure/cosmos")
const { DefaultAzureCredential } = require("@azure/identity")

const credential = new DefaultAzureCredential()
const cosmosClient = new CosmosClient({
    endpoint: process.env.COSMOS_ENDPOINT,
    aadCredentials: credential,
})
const container = cosmosClient
    .database("InfraMonitorDB")
    .container("Notifications")

app.serviceBusTopic("SendNotification", {
    connection: "SERVICEBUS_CONNECTION",
    topicName: "infrastructure-events",
    subscriptionName: "send-notification",
    handler: async (message, context) => {
        context.log("SendNotification triggered")

        const event = message

        const notification = {
            id: `NOTIF-${Date.now()}`,
            eventId: event.id,
            type: "alert",
            severity: event.severity,
            message: `🚨 ${event.severity.toUpperCase()} ALERT: ${event.message}`,
            source: event.source,
            environment: event.environment,
            channel: "platform",
            sentAt: new Date().toISOString(),
            status: "sent",
        }

        await container.items.create(notification)

        context.log("=================================")
        context.log(`🚨 ALERT: ${notification.message}`)
        context.log(`Environment: ${event.environment}`)
        context.log(`Source: ${event.source}`)
        context.log(`Severity: ${event.severity}`)
        context.log("=================================")

        context.log(`Notification saved: ${notification.id}`)
    },
})
