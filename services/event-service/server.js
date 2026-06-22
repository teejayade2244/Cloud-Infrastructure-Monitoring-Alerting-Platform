const app = require("./src/app")

const port = process.env.PORT || 3000

app.listen(port, () => {
    console.log(`Events Service running on port ${port}`)
})
 
// server.js file is the entry point for the Event Service. It imports the Express application from `src/app.js` and starts the server on the specified port (defaulting to 3000 if not set in the environment variables). When the server starts, it logs a message indicating that the Events Service is running and on which port.