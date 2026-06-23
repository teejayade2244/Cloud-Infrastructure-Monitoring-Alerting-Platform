const validateEvent = (req, res, next) => {
    const { type, environment, severity, message, source } = req.body

    if (!type || !environment || !severity || !message || !source) {
        return res.status(400).json({
            error: "Missing required fields",
            required: ["type", "environment", "severity", "message", "source"],
        })
    }

    const validTypes = ["deployment", "incident", "alert", "metric", "recovery"]
    const validEnvironments = ["production", "staging", "development"]
    const validSeverities = ["critical", "high", "medium", "low", "info"]

    if (!validTypes.includes(type)) {
        return res
            .status(400)
            .json({
                error: `Invalid type. Must be one of: ${validTypes.join(", ")}`,
            })
    }

    if (!validEnvironments.includes(environment)) {
        return res
            .status(400)
            .json({
                error: `Invalid environment. Must be one of: ${validEnvironments.join(", ")}`,
            })
    }

    if (!validSeverities.includes(severity)) {
        return res
            .status(400)
            .json({
                error: `Invalid severity. Must be one of: ${validSeverities.join(", ")}`,
            })
    }

    next()
}

module.exports = { validateEvent }
