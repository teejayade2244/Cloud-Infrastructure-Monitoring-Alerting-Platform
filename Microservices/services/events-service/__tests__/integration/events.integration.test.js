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

// Point the REAL router at test infrastructure before requiring it - azureConfig.js/events.js
// read these at module-load time, so this must happen first.
process.env.COSMOS_DATABASE = process.env.COSMOS_TEST_DATABASE
process.env.SERVICEBUS_TOPIC = process.env.SERVICEBUS_TEST_TOPIC

const express = require("express")
const request = require("supertest")
const { CosmosClient } = require("@azure/cosmos")
const { ServiceBusClient } = require("@azure/service-bus")
const { DefaultAzureCredential } = require("@azure/identity")

const eventsRouter = require("../../src/routes/events")

const app = express()
app.use(express.json())
app.use("/events", eventsRouter)

// A second, independently-constructed set of clients, built directly here rather than reused
// from azureConfig.js - deliberately separate from the app's own client construction, so
// verification/seeding/cleanup never shares a code path with the thing being verified.
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
    .container("Events")

const serviceBusClient = new ServiceBusClient(
    process.env.SERVICEBUS_NAMESPACE,
    createTestCredential(),
    { transportType: "AmqpWebSockets" },
)
const receiver = serviceBusClient.createReceiver(
    process.env.SERVICEBUS_TEST_TOPIC,
    process.env.SERVICEBUS_TEST_SUBSCRIPTION,
    { receiveMode: "peekLock" },
)

// Every document/message this file creates carries this marker so cleanup can reliably target
// only what THIS run created, never anything else that might legitimately be in the test
// database. The timestamp+random suffix keeps concurrent runs from colliding.
const TEST_RUN_ID = `integration-test-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`

// Tracks exactly what this run created, for precise per-test cleanup in afterEach - the primary
// cleanup path. The broader afterAll sweep (by TEST_RUN_ID prefix, not exact IDs) is the safety
// net for anything a crashed test left behind, so stale data can't accumulate across CI runs.
const createdEventIds = [] // { id, environment }

async function drainSubscription() {
    // Pre-drain before each Service Bus assertion, so a message left over from an earlier
    // failed run can't be mistaken for (or mask) this test's own real result.
    let messages
    do {
        messages = await receiver.receiveMessages(10, { maxWaitTimeInMs: 2000 })
        for (const msg of messages) {
            await receiver.completeMessage(msg)
        }
    } while (messages.length > 0)
}

async function sweepTestData() {
    const { resources } = await testContainer.items
        .query({
            query: "SELECT c.id, c.environment FROM c WHERE STARTSWITH(c.source, @prefix)",
            parameters: [{ name: "@prefix", value: "integration-test-" }],
        })
        .fetchAll()

    await Promise.all(
        resources.map((doc) =>
            testContainer
                .item(doc.id, doc.environment)
                .delete()
                .catch(() => {
                    // Already gone (e.g. deleted by this run's own afterEach) - fine.
                }),
        ),
    )
}

afterEach(async () => {
    await Promise.all(
        createdEventIds.map(({ id, environment }) =>
            testContainer
                .item(id, environment)
                .delete()
                .catch(() => {}),
        ),
    )
    createdEventIds.length = 0
})

afterAll(async () => {
    await sweepTestData()
    await receiver.close()
    await serviceBusClient.close()
}, 30000)

describe("events-service integration (real Cosmos DB + Service Bus)", () => {
    test("POST /events writes a real document to Cosmos DB", async () => {
        const res = await request(app).post("/events").send({
            type: "deployment",
            environment: "production",
            severity: "medium",
            message: "integration test event",
            source: TEST_RUN_ID,
        })

        expect(res.status).toBe(201)
        const eventId = res.body.eventId
        createdEventIds.push({ id: eventId, environment: "production" })

        // Verified via the independently-constructed client, not the app's own - proves the
        // write actually landed in Cosmos DB, not just that the HTTP handler returned 201.
        const { resource } = await testContainer
            .item(eventId, "production")
            .read()

        expect(resource).toBeDefined()
        expect(resource.id).toBe(eventId)
        expect(resource.type).toBe("deployment")
        expect(resource.environment).toBe("production")
        expect(resource.severity).toBe("medium")
        expect(resource.message).toBe("integration test event")
        expect(resource.source).toBe(TEST_RUN_ID)
        expect(resource.status).toBe("received")
    })

    test("POST /events with severity=critical publishes a real Service Bus message", async () => {
        await drainSubscription()

        const res = await request(app).post("/events").send({
            type: "incident",
            environment: "production",
            severity: "critical",
            message: "integration test critical event",
            source: TEST_RUN_ID,
        })

        expect(res.status).toBe(201)
        expect(res.body.publishedToServiceBus).toBe(true)
        createdEventIds.push({
            id: res.body.eventId,
            environment: "production",
        })

        // Requests more than 1 and finds this test's own message by TEST_RUN_ID, rather than
        // assuming receiveMessages(1) returns it - confirmed for real elsewhere in this file
        // that this subscription can receive a concurrently-running, unrelated suite's own
        // message (see the "does not publish" test's comment), which could otherwise occupy
        // the single slot instead. Any other message found is completed too, not left
        // peek-locked.
        const messages = await receiver.receiveMessages(5, {
            maxWaitTimeInMs: 20000,
        })
        const msg = messages.find((m) => m.body?.source === TEST_RUN_ID)
        for (const m of messages) {
            await receiver.completeMessage(m)
        }

        expect(msg).toBeDefined()
        expect(msg.body.id).toBe(res.body.eventId)
        expect(msg.body.severity).toBe("critical")
        expect(msg.body.source).toBe(TEST_RUN_ID)
        expect(msg.subject).toBe("incident")
    }, 25000)

    test("POST /events with severity=info does not publish to Service Bus", async () => {
        await drainSubscription()

        const res = await request(app).post("/events").send({
            type: "metric",
            environment: "production",
            severity: "info",
            message: "integration test info event",
            source: TEST_RUN_ID,
        })

        expect(res.status).toBe(201)
        expect(res.body.publishedToServiceBus).toBe(false)
        createdEventIds.push({
            id: res.body.eventId,
            environment: "production",
        })

        // Proves the conditional publish logic against real infrastructure: no message THIS
        // TEST published shows up within a short wait window, not just that mocked
        // sendMessages() wasn't called. Filtered by TEST_RUN_ID rather than asserting the
        // subscription is completely empty - confirmed for real that this subscription can
        // receive an unrelated, concurrently-running suite's own message (create-incident-job's
        // integration tests publish to the same infrastructure-events-test topic; Service Bus
        // topic subscriptions fan out independently by default, so a dedicated subscription for
        // that suite doesn't stop this one from also getting a copy). Any such message is
        // completed here too, same hygiene as drainSubscription, rather than left peek-locked.
        const messages = await receiver.receiveMessages(5, {
            maxWaitTimeInMs: 5000,
        })
        const ours = messages.filter((m) => m.body?.source === TEST_RUN_ID)
        for (const msg of messages) {
            await receiver.completeMessage(msg)
        }

        expect(ours).toHaveLength(0)
    }, 15000)

    describe("GET /events filtering", () => {
        const seeded = [
            {
                id: `${TEST_RUN_ID}-a`,
                type: "deployment",
                environment: "production",
                severity: "critical",
                message: "seeded event A",
                source: TEST_RUN_ID,
                metadata: {},
                timestamp: new Date().toISOString(),
                status: "received",
            },
            {
                id: `${TEST_RUN_ID}-b`,
                type: "incident",
                environment: "staging",
                severity: "high",
                message: "seeded event B",
                source: TEST_RUN_ID,
                metadata: {},
                timestamp: new Date().toISOString(),
                status: "received",
            },
            {
                id: `${TEST_RUN_ID}-c`,
                type: "alert",
                environment: "production",
                severity: "low",
                message: "seeded event C",
                source: TEST_RUN_ID,
                metadata: {},
                timestamp: new Date().toISOString(),
                status: "received",
            },
        ]

        beforeAll(async () => {
            for (const doc of seeded) {
                await testContainer.items.create(doc)
            }
        })

        afterAll(async () => {
            await Promise.all(
                seeded.map((doc) =>
                    testContainer
                        .item(doc.id, doc.environment)
                        .delete()
                        .catch(() => {}),
                ),
            )
        })

        test("filters by environment", async () => {
            const res = await request(app)
                .get("/events")
                .query({ environment: "staging" })

            expect(res.status).toBe(200)
            const ids = res.body.events.map((e) => e.id)
            expect(ids).toContain(seeded[1].id)
            expect(ids).not.toContain(seeded[0].id)
            expect(ids).not.toContain(seeded[2].id)
        })

        test("filters by severity", async () => {
            const res = await request(app)
                .get("/events")
                .query({ severity: "critical" })

            const ids = res.body.events.map((e) => e.id)
            expect(ids).toContain(seeded[0].id)
            expect(ids).not.toContain(seeded[1].id)
            expect(ids).not.toContain(seeded[2].id)
        })

        test("combines environment + severity filters", async () => {
            const res = await request(app)
                .get("/events")
                .query({ environment: "production", severity: "low" })

            const ids = res.body.events.map((e) => e.id)
            expect(ids).toContain(seeded[2].id)
            expect(ids).not.toContain(seeded[0].id)
            expect(ids).not.toContain(seeded[1].id)
        })
    })
})
