jest.mock("../src/lib/azureClients")

const { createServiceBusClient } = require("../src/lib/azureClients")
const { runJob } = require("../src/lib/runJob")

// MAX_MESSAGES and MAX_WAIT_TIME_MS in runJob.js are 10 and 10000 respectively (confirmed by
// reading the source, not assumed) - asserted directly against the real receiveMessages call
// below rather than duplicated as separate constants here.

const makeMessage = (id, body = {}) => ({ messageId: id, body })

describe("runJob", () => {
    let mockReceiveMessages
    let mockCompleteMessage
    let mockDeadLetterMessage
    let mockReceiverClose
    let mockCreateReceiver
    let mockClientClose

    beforeEach(() => {
        jest.clearAllMocks()

        mockReceiveMessages = jest.fn().mockResolvedValue([])
        mockCompleteMessage = jest.fn().mockResolvedValue(undefined)
        mockDeadLetterMessage = jest.fn().mockResolvedValue(undefined)
        mockReceiverClose = jest.fn().mockResolvedValue(undefined)
        mockCreateReceiver = jest.fn(() => ({
            receiveMessages: mockReceiveMessages,
            completeMessage: mockCompleteMessage,
            deadLetterMessage: mockDeadLetterMessage,
            close: mockReceiverClose,
        }))
        mockClientClose = jest.fn().mockResolvedValue(undefined)

        createServiceBusClient.mockReturnValue({
            createReceiver: mockCreateReceiver,
            close: mockClientClose,
        })

        jest.spyOn(console, "log").mockImplementation(() => {})
        jest.spyOn(console, "error").mockImplementation(() => {})
    })

    afterEach(() => {
        jest.restoreAllMocks()
    })

    test("receives with the real MAX_MESSAGES (10) and MAX_WAIT_TIME_MS (10000ms) bounds", async () => {
        await runJob("create-incident", jest.fn())

        expect(mockReceiveMessages).toHaveBeenCalledWith(10, {
            maxWaitTimeInMs: 10000,
        })
    })

    test("passes the subscription name through to createReceiver, on the default topic", async () => {
        await runJob("create-incident", jest.fn())

        expect(mockCreateReceiver).toHaveBeenCalledWith(
            "infrastructure-events",
            "create-incident",
            { receiveMode: "peekLock" },
        )
    })

    test("uses SERVICEBUS_TOPIC from env instead of the default when set", async () => {
        await runJob("create-incident-prod", jest.fn(), {
            SERVICEBUS_TOPIC: "infrastructure-events-prod",
        })

        expect(mockCreateReceiver).toHaveBeenCalledWith(
            "infrastructure-events-prod",
            "create-incident-prod",
            { receiveMode: "peekLock" },
        )
    })

    test("calls the handler with the message body and the raw message, for each received message", async () => {
        const message = makeMessage("msg-1", { type: "deployment" })
        mockReceiveMessages.mockResolvedValueOnce([message])
        const handler = jest.fn().mockResolvedValue(undefined)

        await runJob("create-incident", handler)

        expect(handler).toHaveBeenCalledTimes(1)
        expect(handler).toHaveBeenCalledWith(message.body, message)
    })

    test("completes each message the handler processes successfully, and returns the count", async () => {
        const messages = [makeMessage("msg-1"), makeMessage("msg-2")]
        mockReceiveMessages.mockResolvedValueOnce(messages)
        const handler = jest.fn().mockResolvedValue(undefined)

        const processed = await runJob("create-incident", handler)

        expect(mockCompleteMessage).toHaveBeenCalledTimes(2)
        expect(mockCompleteMessage).toHaveBeenNthCalledWith(1, messages[0])
        expect(mockCompleteMessage).toHaveBeenNthCalledWith(2, messages[1])
        expect(mockDeadLetterMessage).not.toHaveBeenCalled()
        expect(processed).toBe(2)
    })

    test("dead-letters (does not silently drop) a message whose handler throws, and does not count it as processed", async () => {
        const message = makeMessage("msg-bad")
        mockReceiveMessages.mockResolvedValueOnce([message])
        const handlerError = new Error("Cosmos write failed")
        const handler = jest.fn().mockRejectedValue(handlerError)

        const processed = await runJob("create-incident", handler)

        expect(mockCompleteMessage).not.toHaveBeenCalled()
        expect(mockDeadLetterMessage).toHaveBeenCalledTimes(1)
        expect(mockDeadLetterMessage).toHaveBeenCalledWith(message, {
            deadLetterReason: "ProcessingError",
            deadLetterErrorDescription: handlerError.message,
        })
        expect(processed).toBe(0)
    })

    test("a failed message doesn't stop the rest of the batch from being processed", async () => {
        const [msg1, msg2, msg3] = [
            makeMessage("msg-1"),
            makeMessage("msg-2"),
            makeMessage("msg-3"),
        ]
        mockReceiveMessages.mockResolvedValueOnce([msg1, msg2, msg3])
        const handler = jest
            .fn()
            .mockResolvedValueOnce(undefined)
            .mockRejectedValueOnce(new Error("boom"))
            .mockResolvedValueOnce(undefined)

        const processed = await runJob("create-incident", handler)

        expect(mockCompleteMessage).toHaveBeenCalledTimes(2)
        expect(mockCompleteMessage).toHaveBeenCalledWith(msg1)
        expect(mockCompleteMessage).toHaveBeenCalledWith(msg3)
        expect(mockDeadLetterMessage).toHaveBeenCalledTimes(1)
        expect(mockDeadLetterMessage).toHaveBeenCalledWith(
            msg2,
            expect.objectContaining({ deadLetterReason: "ProcessingError" }),
        )
        expect(processed).toBe(3 - 1)
    })

    test("closes the receiver and the Service Bus client after a normal run", async () => {
        await runJob("create-incident", jest.fn())

        expect(mockReceiverClose).toHaveBeenCalledTimes(1)
        expect(mockClientClose).toHaveBeenCalledTimes(1)
    })

    test("still closes the receiver and client, and rejects, when receiveMessages itself throws (a job-level failure, not a per-message one)", async () => {
        const connectivityError = new Error("Service Bus unreachable")
        mockReceiveMessages.mockRejectedValueOnce(connectivityError)

        await expect(runJob("create-incident", jest.fn())).rejects.toThrow(
            "Service Bus unreachable",
        )
        expect(mockReceiverClose).toHaveBeenCalledTimes(1)
        expect(mockClientClose).toHaveBeenCalledTimes(1)
    })

    test("returns 0 when there are no pending messages", async () => {
        const processed = await runJob("create-incident", jest.fn())

        expect(processed).toBe(0)
    })
})
