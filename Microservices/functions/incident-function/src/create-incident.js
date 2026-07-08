const appInsights = require("applicationinsights")
if (process.env.APPLICATIONINSIGHTS_CONNECTION_STRING && !appInsights.defaultClient) {
    appInsights.setup(process.env.APPLICATIONINSIGHTS_CONNECTION_STRING).start()
}

const { createCosmosContainer } = require("./lib/azureClients")
const { runJob } = require("./lib/runJob")

const container = createCosmosContainer("Incidents")

async function handleEvent(event) {
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
        updates: [],
    }

    await container.items.create(incident)
    console.log(`Incident created: ${incident.id} for event ${event.id}`)
}

runJob("create-incident", handleEvent)
    .then((count) => {
        console.log(`create-incident job complete, processed ${count} message(s)`)
        process.exit(0)
    })
    .catch((err) => {
        console.error("create-incident job failed", err)
        process.exit(1)
    })
