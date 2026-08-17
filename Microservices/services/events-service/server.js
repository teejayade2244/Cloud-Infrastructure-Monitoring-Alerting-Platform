const appInsights = require("applicationinsights")
appInsights
    .setup(process.env.APPLICATIONINSIGHTS_CONNECTION_STRING)
    .setAutoDependencyCorrelation(true)
    .setAutoCollectRequests(true)
    .setAutoCollectPerformance(true)
    .setAutoCollectExceptions(true)
    .setAutoCollectDependencies(true)
    .start()
appInsights.defaultClient.context.tags[
    appInsights.defaultClient.context.keys.cloudRole
] = "events-service"
require("dotenv").config()
const app = require("./src/app")

const port = process.env.PORT || 3000

// The App Insights + dotenv setup above runs before this, so there's a real window on startup
// where the process has started but isn't listening yet - the Deployment's readinessProbe
// (charts/events-service) exists specifically to keep Kubernetes from routing traffic during it.
app.listen(port, () => {
    console.log(`Events Service running on port ${port}`)
})
