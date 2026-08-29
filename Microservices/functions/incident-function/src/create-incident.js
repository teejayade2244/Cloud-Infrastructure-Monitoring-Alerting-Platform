const appInsights = require("applicationinsights")
if (
    process.env.APPLICATIONINSIGHTS_CONNECTION_STRING &&
    !appInsights.defaultClient
) {
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

// Defaults to the production subscription name - only set explicitly for a different
// environment (e.g. create-incident-prod for the production namespace).
const subscriptionName =
    process.env.SERVICEBUS_SUBSCRIPTION?.trim() || "create-incident"

// Only runs the job when this file is executed directly (node src/create-incident.js, the real
// production entrypoint), not when it's require()'d - e.g. by a test importing handleEvent.
// require.main === module is Node's standard idiom for this; it changes nothing about how the
// container actually runs the file. istanbul ignore next: pure entrypoint wiring, no branching
// logic of its own worth unit-testing - deliberately excluded from coverage accounting, same as
// the appInsights bootstrap above.
/* istanbul ignore next */
if (require.main === module) {
    runJob(subscriptionName, handleEvent)
        .then((count) => {
            console.log(
                `create-incident job complete, processed ${count} message(s)`,
            )
            process.exit(0)
        })
        .catch((err) => {
            console.error("create-incident job failed", err)
            process.exit(1)
        })
}

// no-op: fresh build tag to demonstrate a real production rollback end to end
module.exports = { handleEvent }
