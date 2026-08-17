// events.js creates its Cosmos/Service Bus clients at module load time (top-level
// createAzureClients(process.env) call, not inside a request handler or a factory the test
// could inject into). So both the required env vars and the @azure/* mocks must be fully in
// place BEFORE the router is require()'d below - jest.mock() calls are hoisted above imports
// by Jest automatically, which is what makes this ordering work.
jest.mock("@azure/cosmos")
jest.mock("@azure/service-bus")
jest.mock("@azure/identity")

const express = require("express")
const request = require("supertest")
const { CosmosClient } = require("@azure/cosmos")
const { ServiceBusClient } = require("@azure/service-bus")

// Managed-identity style config (no connection strings) - matches how the service actually
// runs in AKS/Container Apps, and exercises the DefaultAzureCredential branch of
// createCredential() in azureConfig.js rather than the connection-string branch.
process.env.COSMOS_ENDPOINT = "https://fake-cosmos.documents.azure.com:443/"
process.env.SERVICEBUS_NAMESPACE = "fake-namespace.servicebus.windows.net"
process.env.AZURE_CLIENT_ID = "fake-client-id"
delete process.env.COSMOS_CONNECTION_STRING
delete process.env.SERVICEBUS_CONNECTION_STRING
delete process.env.AZURE_TENANT_ID
delete process.env.AZURE_CLIENT_SECRET

const mockItemsCreate = jest.fn()
const mockFetchAll = jest.fn()
const mockQuery = jest.fn(() => ({ fetchAll: mockFetchAll }))
const mockItemDelete = jest.fn()
const mockItem = jest.fn(() => ({ delete: mockItemDelete }))
const mockContainer = {
    items: {
        create: mockItemsCreate,
        query: mockQuery,
    },
    item: mockItem,
}
CosmosClient.mockImplementation(() => ({
    database: jest.fn(() => ({
        container: jest.fn(() => mockContainer),
    })),
}))

const mockSendMessages = jest.fn()
const mockSenderClose = jest.fn()
const mockCreateSender = jest.fn(() => ({
    sendMessages: mockSendMessages,
    close: mockSenderClose,
}))
ServiceBusClient.mockImplementation(() => ({
    createSender: mockCreateSender,
}))

// Required at module scope, after the mocks above are wired up, and only once - Node caches
// the module, so eventsContainer/serviceBusClient inside events.js are fixed for the whole
// file. Per-test behaviour is controlled by reconfiguring the mock fns themselves, not by
// re-requiring the router.
const eventsRouter = require("../src/routes/events")

const app = express()
app.use(express.json())
app.use("/events", eventsRouter)

const UUID_RE =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/

const validPayload = (overrides = {}) => ({
    type: "deployment",
    environment: "production",
    severity: "medium",
    message: "Deploy finished",
    source: "ci-pipeline",
    ...overrides,
})

describe("events router", () => {
    let consoleLogSpy
    let consoleErrorSpy

    beforeEach(() => {
        jest.clearAllMocks()
        mockItemsCreate.mockResolvedValue(undefined)
        mockFetchAll.mockResolvedValue({ resources: [] })
        mockItemDelete.mockResolvedValue(undefined)
        mockSendMessages.mockResolvedValue(undefined)
        mockSenderClose.mockResolvedValue(undefined)
        consoleLogSpy = jest.spyOn(console, "log").mockImplementation(() => {})
        consoleErrorSpy = jest
            .spyOn(console, "error")
            .mockImplementation(() => {})
    })

    afterEach(() => {
        consoleLogSpy.mockRestore()
        consoleErrorSpy.mockRestore()
    })

    describe("POST /events", () => {
        test.each(["critical", "high", "medium", "low", "info"])(
            "accepts a valid payload with severity=%s and returns 201",
            async (severity) => {
                const res = await request(app)
                    .post("/events")
                    .send(validPayload({ severity }))

                expect(res.status).toBe(201)
                expect(res.body.message).toBe("Event received")
                expect(res.body.eventId).toMatch(UUID_RE)
                expect(res.body.publishedToServiceBus).toBe(
                    severity === "critical" || severity === "high",
                )
            },
        )

        test("creates the Cosmos DB document with the correct shape", async () => {
            await request(app)
                .post("/events")
                .send(
                    validPayload({
                        type: "incident",
                        environment: "staging",
                        severity: "low",
                        message: "Disk usage high",
                        source: "monitoring-agent",
                        metadata: { host: "vm-1" },
                    }),
                )

            expect(mockItemsCreate).toHaveBeenCalledTimes(1)
            const created = mockItemsCreate.mock.calls[0][0]
            expect(created).toEqual({
                id: expect.stringMatching(UUID_RE),
                type: "incident",
                environment: "staging",
                severity: "low",
                message: "Disk usage high",
                source: "monitoring-agent",
                metadata: { host: "vm-1" },
                timestamp: expect.stringMatching(ISO_RE),
                status: "received",
            })
        })

        test("defaults metadata to {} when not provided", async () => {
            await request(app).post("/events").send(validPayload())

            const created = mockItemsCreate.mock.calls[0][0]
            expect(created.metadata).toEqual({})
        })

        test.each(["critical", "high"])(
            "publishes to Service Bus when severity=%s",
            async (severity) => {
                await request(app)
                    .post("/events")
                    .send(validPayload({ severity }))

                expect(mockCreateSender).toHaveBeenCalledWith(
                    "infrastructure-events",
                )
                expect(mockSendMessages).toHaveBeenCalledTimes(1)
                const message = mockSendMessages.mock.calls[0][0]
                expect(message.contentType).toBe("application/json")
                expect(message.subject).toBe("deployment")
                expect(message.body).toMatchObject({ severity })
                expect(mockSenderClose).toHaveBeenCalledTimes(1)
            },
        )

        test.each(["medium", "low", "info"])(
            "does not publish to Service Bus when severity=%s",
            async (severity) => {
                await request(app)
                    .post("/events")
                    .send(validPayload({ severity }))

                expect(mockCreateSender).not.toHaveBeenCalled()
                expect(mockSendMessages).not.toHaveBeenCalled()
            },
        )

        test("rejects a payload missing required fields with 400 and does not touch Cosmos DB", async () => {
            const res = await request(app)
                .post("/events")
                .send({ type: "deployment", environment: "production" })

            expect(res.status).toBe(400)
            expect(res.body).toEqual({
                error: "Missing required fields",
                required: [
                    "type",
                    "environment",
                    "severity",
                    "message",
                    "source",
                ],
            })
            expect(mockItemsCreate).not.toHaveBeenCalled()
        })

        test("rejects an invalid type with 400", async () => {
            const res = await request(app)
                .post("/events")
                .send(validPayload({ type: "not-a-real-type" }))

            expect(res.status).toBe(400)
            expect(res.body.error).toMatch(/^Invalid type\./)
            expect(mockItemsCreate).not.toHaveBeenCalled()
        })

        test("rejects an invalid environment with 400", async () => {
            const res = await request(app)
                .post("/events")
                .send(validPayload({ environment: "not-a-real-environment" }))

            expect(res.status).toBe(400)
            expect(res.body.error).toMatch(/^Invalid environment\./)
            expect(mockItemsCreate).not.toHaveBeenCalled()
        })

        test("rejects an invalid severity with 400", async () => {
            const res = await request(app)
                .post("/events")
                .send(validPayload({ severity: "apocalyptic" }))

            expect(res.status).toBe(400)
            expect(res.body.error).toMatch(/^Invalid severity\./)
            expect(mockItemsCreate).not.toHaveBeenCalled()
        })

        test("returns 500, logs the error, and does not publish to Service Bus when Cosmos DB throws", async () => {
            mockItemsCreate.mockRejectedValueOnce(new Error("Cosmos is down"))

            const res = await request(app)
                .post("/events")
                .send(validPayload({ severity: "critical" }))

            expect(res.status).toBe(500)
            expect(res.body).toEqual({ error: "Failed to process event" })
            expect(consoleErrorSpy).toHaveBeenCalledWith(
                "Error processing event:",
                "Cosmos is down",
            )
            expect(mockCreateSender).not.toHaveBeenCalled()
        })

        test("returns 500 when Service Bus throws for a critical event", async () => {
            mockSendMessages.mockRejectedValueOnce(
                new Error("Service Bus unreachable"),
            )

            const res = await request(app)
                .post("/events")
                .send(validPayload({ severity: "critical" }))

            expect(res.status).toBe(500)
            expect(res.body).toEqual({ error: "Failed to process event" })
            expect(mockItemsCreate).toHaveBeenCalledTimes(1)
        })
    })

    describe("GET /events", () => {
        test("uses the base query with no WHERE clause when no filters are given", async () => {
            await request(app).get("/events")

            expect(mockQuery).toHaveBeenCalledWith(
                "SELECT * FROM c ORDER BY c.timestamp DESC OFFSET 0 LIMIT 50",
            )
        })

        test("returns the events and count from Cosmos DB", async () => {
            const events = [{ id: "1" }, { id: "2" }]
            mockFetchAll.mockResolvedValueOnce({ resources: events })

            const res = await request(app).get("/events")

            expect(res.status).toBe(200)
            expect(res.body).toEqual({ events, count: 2 })
        })

        test("filters by environment only", async () => {
            await request(app)
                .get("/events")
                .query({ environment: "production" })

            expect(mockQuery).toHaveBeenCalledWith(
                "SELECT * FROM c WHERE c.environment = 'production' ORDER BY c.timestamp DESC OFFSET 0 LIMIT 50",
            )
        })

        test("filters by severity only", async () => {
            await request(app).get("/events").query({ severity: "critical" })

            expect(mockQuery).toHaveBeenCalledWith(
                "SELECT * FROM c WHERE c.severity = 'critical' ORDER BY c.timestamp DESC OFFSET 0 LIMIT 50",
            )
        })

        test("filters by type only", async () => {
            await request(app).get("/events").query({ type: "alert" })

            expect(mockQuery).toHaveBeenCalledWith(
                "SELECT * FROM c WHERE c.type = 'alert' ORDER BY c.timestamp DESC OFFSET 0 LIMIT 50",
            )
        })

        test("combines all three filters with AND, in environment/severity/type order", async () => {
            await request(app).get("/events").query({
                environment: "staging",
                severity: "high",
                type: "incident",
            })

            expect(mockQuery).toHaveBeenCalledWith(
                "SELECT * FROM c WHERE c.environment = 'staging' AND c.severity = 'high' AND c.type = 'incident' ORDER BY c.timestamp DESC OFFSET 0 LIMIT 50",
            )
        })

        test("returns 500 and logs the error when Cosmos DB throws", async () => {
            mockFetchAll.mockRejectedValueOnce(new Error("Cosmos is down"))

            const res = await request(app).get("/events")

            expect(res.status).toBe(500)
            expect(res.body).toEqual({ error: "Failed to fetch events" })
            expect(consoleErrorSpy).toHaveBeenCalledWith(
                "Error fetching events:",
                "Cosmos is down",
            )
        })
    })

    describe("GET /events/:id", () => {
        test("returns 200 with the event when it exists", async () => {
            const event = { id: "abc-123", type: "alert", severity: "high" }
            mockFetchAll.mockResolvedValueOnce({ resources: [event] })

            const res = await request(app).get("/events/abc-123")

            expect(res.status).toBe(200)
            expect(res.body).toEqual(event)
            expect(mockQuery).toHaveBeenCalledWith(
                "SELECT * FROM c WHERE c.id = 'abc-123'",
            )
        })

        test("returns 404 when the event does not exist", async () => {
            mockFetchAll.mockResolvedValueOnce({ resources: [] })

            const res = await request(app).get("/events/does-not-exist")

            expect(res.status).toBe(404)
            expect(res.body).toEqual({ error: "Event not found" })
        })

        test("returns 500 and logs the error when Cosmos DB throws", async () => {
            mockFetchAll.mockRejectedValueOnce(new Error("Cosmos is down"))

            const res = await request(app).get("/events/abc-123")

            expect(res.status).toBe(500)
            expect(res.body).toEqual({ error: "Failed to fetch event" })
            expect(consoleErrorSpy).toHaveBeenCalledWith(
                "Error fetching event:",
                "Cosmos is down",
            )
        })
    })

    describe("DELETE /events/:id", () => {
        test("returns 200 and deletes using the event's own environment as partition key", async () => {
            const event = {
                id: "abc-123",
                type: "alert",
                environment: "staging",
                severity: "high",
            }
            mockFetchAll.mockResolvedValueOnce({ resources: [event] })

            const res = await request(app).delete("/events/abc-123")

            expect(res.status).toBe(200)
            expect(res.body).toEqual({
                message: "Event deleted",
                eventId: "abc-123",
            })
            expect(mockQuery).toHaveBeenCalledWith(
                "SELECT * FROM c WHERE c.id = 'abc-123'",
            )
            expect(mockItem).toHaveBeenCalledWith("abc-123", "staging")
            expect(mockItemDelete).toHaveBeenCalledTimes(1)
        })

        test("returns 404 and does not attempt a delete when the event does not exist", async () => {
            mockFetchAll.mockResolvedValueOnce({ resources: [] })

            const res = await request(app).delete("/events/does-not-exist")

            expect(res.status).toBe(404)
            expect(res.body).toEqual({ error: "Event not found" })
            expect(mockItem).not.toHaveBeenCalled()
            expect(mockItemDelete).not.toHaveBeenCalled()
        })

        test("returns 500 and logs the error when the lookup query throws", async () => {
            mockFetchAll.mockRejectedValueOnce(new Error("Cosmos is down"))

            const res = await request(app).delete("/events/abc-123")

            expect(res.status).toBe(500)
            expect(res.body).toEqual({ error: "Failed to delete event" })
            expect(consoleErrorSpy).toHaveBeenCalledWith(
                "Error deleting event:",
                "Cosmos is down",
            )
            expect(mockItemDelete).not.toHaveBeenCalled()
        })

        test("returns 500 and logs the error when the delete itself throws", async () => {
            mockFetchAll.mockResolvedValueOnce({
                resources: [{ id: "abc-123", environment: "production" }],
            })
            mockItemDelete.mockRejectedValueOnce(new Error("Cosmos is down"))

            const res = await request(app).delete("/events/abc-123")

            expect(res.status).toBe(500)
            expect(res.body).toEqual({ error: "Failed to delete event" })
            expect(consoleErrorSpy).toHaveBeenCalledWith(
                "Error deleting event:",
                "Cosmos is down",
            )
        })
    })
})
