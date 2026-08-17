const express = require("express")
const { v4: uuidv4 } = require("uuid")
const { validateEvent } = require("../middleware/validate")
const { createAzureClients } = require("../azureConfig")

const router = express.Router()

const { eventsContainer, serviceBusClient } = createAzureClients(process.env)

// Defaults to the production topic name - only the integration-tests CI job ever sets
// SERVICEBUS_TOPIC, pointed at the isolated test topic, so this is a no-op everywhere else.
const serviceBusTopic =
    process.env.SERVICEBUS_TOPIC?.trim() || "infrastructure-events"

// POST /events - publish a new infrastructure event
router.post("/", validateEvent, async (req, res) => {
    try {
        const { type, environment, severity, message, source, metadata } =
            req.body

        const event = {
            id: uuidv4(),
            type,
            environment,
            severity,
            message,
            source,
            metadata: metadata || {},
            timestamp: new Date().toISOString(),
            status: "received",
        }

        // Save to Cosmos DB
        await eventsContainer.items.create(event)
        console.log(`Event saved: ${event.id} - ${type} from ${source}`)

        // Publish to Service Bus for critical/high severity
        if (severity === "critical" || severity === "high") {
            const sender = serviceBusClient.createSender(serviceBusTopic)
            await sender.sendMessages({
                body: event,
                contentType: "application/json",
                subject: event.type,
            })
            await sender.close()
            console.log(`Event published to Service Bus: ${event.id}`)
        }

        res.status(201).json({
            message: "Event received",
            eventId: event.id,
            publishedToServiceBus:
                severity === "critical" || severity === "high",
        })
    } catch (err) {
        console.error("Error processing event:", err.message)
        res.status(500).json({ error: "Failed to process event" })
    }
})

// GET /events - list all events
router.get("/", async (req, res) => {
    try {
        const { environment, severity, type } = req.query

        let query = "SELECT * FROM c"
        const conditions = []

        if (environment) conditions.push(`c.environment = '${environment}'`)
        if (severity) conditions.push(`c.severity = '${severity}'`)
        if (type) conditions.push(`c.type = '${type}'`)

        if (conditions.length > 0) {
            query += " WHERE " + conditions.join(" AND ")
        }

        query += " ORDER BY c.timestamp DESC OFFSET 0 LIMIT 50"

        const { resources } = await eventsContainer.items
            .query(query)
            .fetchAll()

        res.json({ events: resources, count: resources.length })
    } catch (err) {
        console.error("Error fetching events:", err.message)
        res.status(500).json({ error: "Failed to fetch events" })
    }
})

// GET /events/:id - get a specific event (cross-partition lookup by id; the DELETE route below
// reuses this same query shape to find an event's partition key before deleting it)
router.get("/:id", async (req, res) => {
    try {
        const { resources } = await eventsContainer.items
            .query(`SELECT * FROM c WHERE c.id = '${req.params.id}'`)
            .fetchAll()

        if (resources.length === 0) {
            return res.status(404).json({ error: "Event not found" })
        }

        res.json(resources[0])
    } catch (err) {
        console.error("Error fetching event:", err.message)
        res.status(500).json({ error: "Failed to fetch event" })
    }
})

// DELETE /events/:id - delete a specific event - also the cleanup step of the CI smoke test
// (scripts/smoke-test.sh), removing the synthetic event its POST check creates.
router.delete("/:id", async (req, res) => {
    try {
        // Same cross-partition lookup as GET /:id - Cosmos deletes require the partition key
        // (environment) up front, so the id-only route param isn't enough on its own.
        const { resources } = await eventsContainer.items
            .query(`SELECT * FROM c WHERE c.id = '${req.params.id}'`)
            .fetchAll()

        if (resources.length === 0) {
            return res.status(404).json({ error: "Event not found" })
        }

        const { environment } = resources[0]
        await eventsContainer.item(req.params.id, environment).delete()

        res.status(200).json({
            message: "Event deleted",
            eventId: req.params.id,
        })
    } catch (err) {
        console.error("Error deleting event:", err.message)
        res.status(500).json({ error: "Failed to delete event" })
    }
})

module.exports = router
