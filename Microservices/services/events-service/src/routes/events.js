const express = require("express")
const { v4: uuidv4 } = require("uuid")
const { validateEvent } = require("../middleware/validate")
const { createAzureClients } = require("../azureConfig")

const router = express.Router()

const { eventsContainer, serviceBusClient } = createAzureClients(process.env)

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
            const sender = serviceBusClient.createSender(
                "infrastructure-events",
            )
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

// GET /events/:id - get a specific event
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

module.exports = router
