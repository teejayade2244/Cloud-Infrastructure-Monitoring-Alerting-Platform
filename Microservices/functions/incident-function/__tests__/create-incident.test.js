// handleEvent is exported, and the runJob(...).then/.catch/process.exit chain only runs when
// this file is executed directly (see the require.main === module guard in create-incident.js) -
// require()'ing it here, at module scope, never triggers that chain, since Jest's require.main
// is never this test file. No jest.resetModules()/fresh-require workaround needed for the
// handleEvent tests below. @azure/service-bus IS mocked here (unlike the previous version of
// this file) purely as a safety net for the guard-regression test further down: if the guard is
// ever accidentally removed, a real ServiceBusClient would otherwise attempt genuine network I/O
// during `npm test`, and a real process.exit() would kill the Jest worker outright instead of
// just failing one assertion.
jest.mock("@azure/cosmos")
jest.mock("@azure/identity")
jest.mock("@azure/service-bus")

const { CosmosClient } = require("@azure/cosmos")
const { ServiceBusClient } = require("@azure/service-bus")

const ID_RE = /^INC-\d+$/
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/

const mockItemsCreate = jest.fn()
const mockContainerFn = jest.fn(() => ({ items: { create: mockItemsCreate } }))
const mockDatabaseFn = jest.fn(() => ({ container: mockContainerFn }))
CosmosClient.mockImplementation(() => ({ database: mockDatabaseFn }))

process.env.COSMOS_ENDPOINT = "https://fake-cosmos.documents.azure.com:443/"

// Spied BEFORE the require below, specifically so this same, single, ordinary require() - the
// exact one handleEvent's tests already rely on, not a second/fresh one - can be checked for
// whether it triggered a real process.exit(). Restored at the end of the guard test further
// down, once it's been asserted on.
const moduleLoadExitSpy = jest
    .spyOn(process, "exit")
    .mockImplementation(() => {})

const { handleEvent } = require("../src/create-incident")

describe("handleEvent", () => {
    let consoleLogSpy

    beforeEach(() => {
        // Only mockItemsCreate is reset per test - mockContainerFn/mockDatabaseFn are called
        // exactly once, when create-incident.js is require()'d at the top of this file, not per
        // handleEvent call. Clearing them here would wipe that one real call before the first
        // test ever runs.
        mockItemsCreate.mockClear()
        mockItemsCreate.mockResolvedValue(undefined)
        consoleLogSpy = jest.spyOn(console, "log").mockImplementation(() => {})
    })

    afterEach(() => {
        consoleLogSpy.mockRestore()
    })

    test("used the Incidents container, constructed once at module load", () => {
        expect(mockContainerFn).toHaveBeenCalledWith("Incidents")
    })

    test("constructs the correct Incident document from the triggering event, with source passed through unchanged", async () => {
        const event = {
            id: "evt-1",
            type: "deployment",
            environment: "production",
            severity: "medium",
            message: "Deploy finished",
            source: "ci-pipeline",
        }

        await handleEvent(event)

        expect(mockItemsCreate).toHaveBeenCalledTimes(1)
        expect(mockItemsCreate.mock.calls[0][0]).toEqual({
            id: expect.stringMatching(ID_RE),
            eventId: "evt-1",
            title: "DEPLOYMENT: Deploy finished",
            description: "Auto-created from deployment event in production",
            severity: "medium",
            environment: "production",
            source: "ci-pipeline",
            status: "open",
            assignedTo: "",
            createdAt: expect.stringMatching(ISO_RE),
            resolvedAt: null,
            updates: [],
        })
    })

    test("logs the created incident id and the triggering event id", async () => {
        await handleEvent({
            id: "evt-3",
            type: "metric",
            environment: "staging",
            severity: "low",
            message: "cpu high",
            source: "monitoring-agent",
        })

        const created = mockItemsCreate.mock.calls[0][0]
        expect(consoleLogSpy).toHaveBeenCalledWith(
            `Incident created: ${created.id} for event evt-3`,
        )
    })

    // runJob.test.js already proves a handler rejection gets dead-lettered, not dropped - this
    // confirms handleEvent's half of that contract: a Cosmos failure must propagate out (not be
    // caught and swallowed here), or runJob would have nothing to catch.
    test("propagates a Cosmos write failure instead of swallowing it, so runJob's dead-letter handling can catch it", async () => {
        const writeError = new Error("Cosmos write failed")
        mockItemsCreate.mockRejectedValueOnce(writeError)

        await expect(
            handleEvent({
                id: "evt-2",
                type: "alert",
                environment: "staging",
                severity: "high",
                message: "boom",
                source: "monitoring-agent",
            }),
        ).rejects.toThrow("Cosmos write failed")
    })
})

// Minimal smoke check that the require.main === module guard itself is intact - distinct from
// (and lighter than) the full resolve/reject wiring, which is proven correct by the manual
// `node src/create-incident.js` verification done separately, not re-tested here. This exists
// purely to catch a future regression where someone accidentally removes or breaks the guard,
// not to re-verify behavior already covered elsewhere.
describe("the require.main === module guard", () => {
    test("importing this module the ordinary way (require.main is Jest's entry point here, never this file - same as any real caller importing handleEvent) does not call process.exit or construct a Service Bus client", () => {
        expect(require.main).not.toBe(module)
        expect(moduleLoadExitSpy).not.toHaveBeenCalled()
        expect(ServiceBusClient).not.toHaveBeenCalled()

        moduleLoadExitSpy.mockRestore()
    })
})
