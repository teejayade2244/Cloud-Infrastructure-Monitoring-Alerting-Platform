const express = require("express")
const eventsRouter = require("./routes/events")

const app = express()
app.use(express.json())

// Used by the CI smoke-test job to verify the staging/production deployment is up - a failure
// here (or on the write/cleanup checks in routes/events.js) triggers an automatic GitOps rollback.
app.get("/health", (req, res) => {
    // TEMPORARY: deliberate end-to-end rollback test - reverted in a follow-up commit.
    res.status(500).json({
        status: "unhealthy",
        service: "events-service",
        timestamp: new Date().toISOString(),
    })
})

app.use("/events", eventsRouter)

app.use((err, req, res, next) => {
    console.error(err.stack)
    res.status(500).json({ error: "Internal server error" })
})

module.exports = app
