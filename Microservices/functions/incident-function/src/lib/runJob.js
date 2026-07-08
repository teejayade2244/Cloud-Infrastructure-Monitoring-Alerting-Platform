const { createServiceBusClient } = require("./azureClients")

const TOPIC_NAME = "infrastructure-events"
const MAX_MESSAGES = 10
const MAX_WAIT_TIME_MS = 10000

// Container Apps Jobs run to completion per KEDA-triggered execution, unlike the Azure Functions
// host this used to run under (which stays alive and listens continuously). So each execution
// drains whatever's currently available on the subscription, processes it, and exits - it does
// not keep polling.
async function runJob(subscriptionName, handler, env = process.env) {
    const serviceBusClient = createServiceBusClient(env)
    const receiver = serviceBusClient.createReceiver(TOPIC_NAME, subscriptionName, {
        receiveMode: "peekLock",
    })

    let processed = 0
    try {
        const messages = await receiver.receiveMessages(MAX_MESSAGES, {
            maxWaitTimeInMs: MAX_WAIT_TIME_MS,
        })

        console.log(`${subscriptionName}: received ${messages.length} message(s)`)

        for (const message of messages) {
            try {
                await handler(message.body, message)
                await receiver.completeMessage(message)
                processed += 1
            } catch (err) {
                console.error(
                    `${subscriptionName}: failed to process message ${message.messageId}`,
                    err,
                )
                await receiver.deadLetterMessage(message, {
                    deadLetterReason: "ProcessingError",
                    deadLetterErrorDescription: err.message,
                })
            }
        }
    } finally {
        await receiver.close()
        await serviceBusClient.close()
    }

    console.log(`${subscriptionName}: processed ${processed} message(s)`)
    return processed
}

module.exports = { runJob, TOPIC_NAME }
