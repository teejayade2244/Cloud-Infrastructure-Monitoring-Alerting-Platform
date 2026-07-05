const appInsights = require("applicationinsights")
appInsights.setup(process.env.APPLICATIONINSIGHTS_CONNECTION_STRING)
    .setAutoDependencyCorrelation(true)
    .setAutoCollectRequests(true)
    .setAutoCollectPerformance(true)
    .setAutoCollectExceptions(true)
    .setAutoCollectDependencies(true)
    .start()
appInsights.defaultClient.context.tags[appInsights.defaultClient.context.keys.cloudRole] = "events-service"
require("dotenv").config()
const app = require("./src/app")

const port = process.env.PORT || 3000

app.listen(port, () => {
    console.log(`Events Service running on port ${port}`)
})