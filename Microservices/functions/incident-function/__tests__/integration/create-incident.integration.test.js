const requiredEnvVars = [
    "COSMOS_ENDPOINT",
    "COSMOS_TEST_DATABASE",
    "SERVICEBUS_NAMESPACE",
    "SERVICEBUS_TEST_TOPIC",
    "SERVICEBUS_TEST_SUBSCRIPTION",
]
const missing = requiredEnvVars.filter((name) => !process.env[name]?.trim())
if (missing.length > 0) {
    throw new Error(
        `Integration tests require these env vars, missing: ${missing.join(", ")}`,
    )
}

// Point the REAL create-incident.js at test infrastructure before requiring it -
// createCosmosContainer("Incidents") reads COSMOS_ENDPOINT/COSMOS_DATABASE at require-time (see
// src/lib/azureClients.js), so this must happen first. Mirrors events-service's own integration
// test pattern (events.integration.test.js). Requiring create-incident.js here does NOT run the
// job or call process.exit - only when require.main === module (see the guard added to
// create-incident.js, and its own dedicated regression test in create-incident.test.js).
process.env.COSMOS_DATABASE = process.env.COSMOS_TEST_DATABASE

const { CosmosClient } = require("@azure/cosmos")
const { ServiceBusClient } = require("@azure/service-bus")
const { DefaultAzureCredential } = require("@azure/identity")

const { handleEvent } = require("../../src/create-incident")
const { runJob } = require("../../src/lib/runJob")

// A second, independently-constructed set of clients, built directly here rather than reused
// from src/lib/azureClients.js - deliberately separate from the app's own client construction,
// so verification/seeding/cleanup never shares a code path with the thing being verified.
function createTestCredential() {
    return new DefaultAzureCredential({
        managedIdentityClientId:
            process.env.AZURE_CLIENT_ID?.trim() || undefined,
        excludeInteractiveBrowserCredential: true,
    })
}

const cosmosClient = new CosmosClient({
    endpoint: process.env.COSMOS_ENDPOINT,
    aadCredentials: createTestCredential(),
})
const testContainer = cosmosClient
    .database(process.env.COSMOS_TEST_DATABASE)
    .container("Incidents")

const serviceBusClient = new ServiceBusClient(
    process.env.SERVICEBUS_NAMESPACE,
    createTestCredential(),
    { transportType: "AmqpWebSockets" },
)
const sender = serviceBusClient.createSender(process.env.SERVICEBUS_TEST_TOPIC)

// SERVICEBUS_TEST_SUBSCRIPTION (create-incident-job-test) is dedicated specifically to this
// suite - a separate subscription from create-incident-test, which is events-service's own
// integration test's publish-verification target. Both live on the same infrastructure-events-test
// topic, but never share a subscription, so there's no cross-suite receive race to worry about
// here. Every receive below still filters by this run's own TEST_RUN_ID marker before asserting
// anything, and politely completes (without asserting on) anything else it happens to
// peek-lock along the way - a leftover message from a crashed prior run of this same suite,
// not a cross-suite one, since no other suite reads this subscription.
const TEST_RUN_ID = `integration-test-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`

async function drainSubscription(subQueueType) {
    const receiver = serviceBusClient.createReceiver(
        process.env.SERVICEBUS_TEST_TOPIC,
        process.env.SERVICEBUS_TEST_SUBSCRIPTION,
        subQueueType
            ? { receiveMode: "peekLock", subQueueType }
            : { receiveMode: "peekLock" },
    )
    try {
        let messages
        do {
            messages = await receiver.receiveMessages(10, {
                maxWaitTimeInMs: 2000,
            })
            for (const msg of messages) {
                await receiver.completeMessage(msg)
            }
        } while (messages.length > 0)
    } finally {
        await receiver.close()
    }
}

async function sweepTestData() {
    const { resources } = await testContainer.items
        .query({
            query: "SELECT c.id, c.severity FROM c WHERE STARTSWITH(c.source, @prefix)",
            parameters: [{ name: "@prefix", value: "integration-test-" }],
        })
        .fetchAll()

    await Promise.all(
        resources.map((doc) =>
            testContainer
                .item(doc.id, doc.severity)
                .delete()
                .catch(() => {
                    // Already gone (e.g. deleted by this run's own test) - fine.
                }),
        ),
    )
}

afterAll(async () => {
    await sweepTestData()
    await drainSubscription()
    await drainSubscription("deadLetter")
    await sender.close()
    await serviceBusClient.close()
}, 30000)

describe("create-incident-job integration (real Cosmos DB + Service Bus)", () => {
    test("handleEvent writes a real document to Cosmos DB, with source passed through unchanged", async () => {
        const event = {
            id: "evt-integration-1",
            type: "deployment",
            environment: "production",
            severity: "medium",
            message: "integration test event",
            source: TEST_RUN_ID,
        }

        await handleEvent(event)

        // Verified via the independently-constructed client, not the app's own - proves the
        // write actually landed in Cosmos DB, not just that handleEvent returned without
        // throwing.
        const { resources } = await testContainer.items
            .query({
                query: "SELECT * FROM c WHERE c.eventId = @eventId",
                parameters: [{ name: "@eventId", value: event.id }],
            })
            .fetchAll()

        expect(resources).toHaveLength(1)
        const [doc] = resources
        expect(doc.eventId).toBe(event.id)
        expect(doc.title).toBe("DEPLOYMENT: integration test event")
        expect(doc.description).toBe(
            "Auto-created from deployment event in production",
        )
        expect(doc.severity).toBe("medium")
        expect(doc.environment).toBe("production")
        expect(doc.source).toBe(TEST_RUN_ID)
        expect(doc.status).toBe("open")

        await testContainer.item(doc.id, doc.severity).delete()
    })

    test("runJob receives a real published message, invokes handleEvent with its real content, writes to Cosmos, and completes the message", async () => {
        const event = {
            id: "evt-integration-2",
            type: "alert",
            environment: "staging",
            severity: "high",
            message: "integration test runJob event",
            source: TEST_RUN_ID,
        }
        await sender.sendMessages({
            body: event,
            contentType: "application/json",
            subject: event.type,
        })

        // Wraps (not replaces) the real handleEvent - still does the real Cosmos write, this
        // just also records how it was called, so the message's real content can be asserted on
        // directly rather than inferred from its side effect alone.
        const handleEventSpy = jest.fn(handleEvent)

        const processed = await runJob(
            process.env.SERVICEBUS_TEST_SUBSCRIPTION,
            handleEventSpy,
            {
                SERVICEBUS_NAMESPACE: process.env.SERVICEBUS_NAMESPACE,
                SERVICEBUS_TOPIC: process.env.SERVICEBUS_TEST_TOPIC,
                AZURE_CLIENT_ID: process.env.AZURE_CLIENT_ID,
            },
        )

        expect(processed).toBeGreaterThanOrEqual(1)
        const ourCall = handleEventSpy.mock.calls.find(
            (call) => call[0]?.source === TEST_RUN_ID,
        )
        expect(ourCall).toBeDefined()
        expect(ourCall[0]).toMatchObject({
            id: event.id,
            type: "alert",
            environment: "staging",
            severity: "high",
            message: event.message,
        })

        const { resources } = await testContainer.items
            .query({
                query: "SELECT * FROM c WHERE c.eventId = @eventId",
                parameters: [{ name: "@eventId", value: event.id }],
            })
            .fetchAll()
        expect(resources).toHaveLength(1)
        await testContainer
            .item(resources[0].id, resources[0].severity)
            .delete()

        // The message must be genuinely gone (completed) from the subscription after a
        // successful run, not still sitting there for someone else to redeliver.
        const verifyReceiver = serviceBusClient.createReceiver(
            process.env.SERVICEBUS_TEST_TOPIC,
            process.env.SERVICEBUS_TEST_SUBSCRIPTION,
            { receiveMode: "peekLock" },
        )
        try {
            const remaining = await verifyReceiver.receiveMessages(5, {
                maxWaitTimeInMs: 5000,
            })
            const stillThere = remaining.find(
                (m) => m.body?.source === TEST_RUN_ID,
            )
            expect(stillThere).toBeUndefined()
            // Anything else peek-locked here isn't this suite's data (see the shared-
            // subscription note above) - complete it so it isn't left abandoned mid-receive,
            // without asserting on it.
            for (const msg of remaining) {
                await verifyReceiver.completeMessage(msg)
            }
        } finally {
            await verifyReceiver.close()
        }
    }, 30000)

    test("runJob dead-letters a message that causes handleEvent to genuinely throw, rather than losing it", async () => {
        // Two prior approaches were tried and ruled out for real, not just in theory:
        // 1. A missing severity (the Incidents container's real partition key path, confirmed
        //    via az cosmosdb sql container show) does NOT trigger a rejection - Cosmos DB
        //    accepts a write missing its partition key property, placing it in a synthetic
        //    "Undefined" logical partition instead. Confirmed for real after the CI step
        //    masking this suite's actual result got fixed - "Incident created" had been logged
        //    for this exact test's event the whole time, meaning the write had silently
        //    succeeded on every prior run.
        // 2. An oversized message (targeting Cosmos's 2MB document limit) can't even be
        //    published - this namespace is Standard tier (confirmed via az servicebus namespace
        //    show), capped at 256KB per message, well below what's needed.
        // A missing `type` causes handleEvent's own event.type.toUpperCase() to throw a real,
        // deterministic TypeError before Cosmos is ever involved - genuinely real, not a mocked
        // throw, and doesn't depend on guessing another Cosmos/Service Bus constraint.
        const malformedEvent = {
            id: "evt-integration-3",
            environment: "staging",
            severity: "high",
            message: "integration test malformed event",
            source: TEST_RUN_ID,
        }
        await sender.sendMessages({
            body: malformedEvent,
            contentType: "application/json",
            subject: malformedEvent.type,
        })

        const processed = await runJob(
            process.env.SERVICEBUS_TEST_SUBSCRIPTION,
            handleEvent,
            {
                SERVICEBUS_NAMESPACE: process.env.SERVICEBUS_NAMESPACE,
                SERVICEBUS_TOPIC: process.env.SERVICEBUS_TEST_TOPIC,
                AZURE_CLIENT_ID: process.env.AZURE_CLIENT_ID,
            },
        )

        // Dead-lettered messages aren't counted as processed (see runJob.js) - this alone
        // doesn't prove OUR message was the one dead-lettered though, since other messages may
        // legitimately be on this shared subscription; the DLQ check below is the real proof.
        expect(processed).toBeGreaterThanOrEqual(0)

        const dlqReceiver = serviceBusClient.createReceiver(
            process.env.SERVICEBUS_TEST_TOPIC,
            process.env.SERVICEBUS_TEST_SUBSCRIPTION,
            { receiveMode: "peekLock", subQueueType: "deadLetter" },
        )
        try {
            const dlqMessages = await dlqReceiver.receiveMessages(5, {
                maxWaitTimeInMs: 10000,
            })
            const ours = dlqMessages.find((m) => m.body?.source === TEST_RUN_ID)
            expect(ours).toBeDefined()
            expect(ours.deadLetterReason).toBe("ProcessingError")
            await dlqReceiver.completeMessage(ours)
            // Any other dead-lettered messages found aren't this suite's concern - left alone,
            // not completed, not asserted on.
        } finally {
            await dlqReceiver.close()
        }
    }, 30000)
})
