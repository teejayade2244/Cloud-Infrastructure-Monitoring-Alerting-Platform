const express = require("express")
const eventsRouter = require("./routes/events")

const app = express()
app.use(express.json())

app.get("/health", (req, res) => {
    res.json({
        status: "healthy",
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
