// Deliberately uncovered: all three functions below default their env parameter to
// process.env (env = process.env). Every test here injects env explicitly, by design - it's
// what makes these tests deterministic and independent of whatever happens to be in the real
// environment. That leaves the "no argument passed, fall back to process.env" branch itself
// unexercised (createCredential/createServiceBusClient, confirmed at lines 5 and 31 by the real
// coverage report - not every occurrence of the same pattern gets flagged, since Istanbul
// doesn't count them all identically). It's exercised for real at runtime (create-incident.js
// always calls these with no second argument) and is trivial - a single default-value
// assignment, no branching logic of its own worth a dedicated unit test.
jest.mock("@azure/cosmos")
jest.mock("@azure/service-bus")
jest.mock("@azure/identity")

const { CosmosClient } = require("@azure/cosmos")
const { ServiceBusClient } = require("@azure/service-bus")
const { DefaultAzureCredential } = require("@azure/identity")
const {
    createCredential,
    createCosmosContainer,
    createServiceBusClient,
} = require("../src/lib/azureClients")

describe("createCredential", () => {
    beforeEach(() => {
        jest.clearAllMocks()
    })

    test("passes AZURE_CLIENT_ID through as managedIdentityClientId when set", () => {
        createCredential({ AZURE_CLIENT_ID: "  client-123  " })

        expect(DefaultAzureCredential).toHaveBeenCalledWith({
            managedIdentityClientId: "client-123",
            excludeInteractiveBrowserCredential: true,
        })
    })

    test("passes undefined for managedIdentityClientId when AZURE_CLIENT_ID is not set", () => {
        createCredential({})

        expect(DefaultAzureCredential).toHaveBeenCalledWith({
            managedIdentityClientId: undefined,
            excludeInteractiveBrowserCredential: true,
        })
    })

    test("treats a whitespace-only AZURE_CLIENT_ID as not set", () => {
        createCredential({ AZURE_CLIENT_ID: "   " })

        expect(DefaultAzureCredential).toHaveBeenCalledWith({
            managedIdentityClientId: undefined,
            excludeInteractiveBrowserCredential: true,
        })
    })

    // excludeInteractiveBrowserCredential: true is a real, security-relevant guard, not
    // boilerplate - without it, a broken/missing managed identity could fall back to trying to
    // pop an interactive browser login, which would just hang forever in a container with no
    // browser and no human watching. Asserted explicitly above in every case, not just the
    // happy path.
})

describe("createCosmosContainer", () => {
    let mockContainerFn
    let mockDatabaseFn

    beforeEach(() => {
        jest.clearAllMocks()
        mockContainerFn = jest.fn(() => "the-container")
        mockDatabaseFn = jest.fn(() => ({ container: mockContainerFn }))
        CosmosClient.mockImplementation(() => ({ database: mockDatabaseFn }))
    })

    test("throws a clear error when COSMOS_ENDPOINT is missing", () => {
        expect(() => createCosmosContainer("Incidents", {})).toThrow(
            "Missing COSMOS_ENDPOINT",
        )
        expect(CosmosClient).not.toHaveBeenCalled()
    })

    test("throws a clear error when COSMOS_ENDPOINT is whitespace-only", () => {
        expect(() =>
            createCosmosContainer("Incidents", { COSMOS_ENDPOINT: "   " }),
        ).toThrow("Missing COSMOS_ENDPOINT")
    })

    test("constructs CosmosClient with the trimmed endpoint and an AAD credential", () => {
        createCosmosContainer("Incidents", {
            COSMOS_ENDPOINT: "  https://fake-cosmos.documents.azure.com:443/  ",
        })

        expect(CosmosClient).toHaveBeenCalledWith({
            endpoint: "https://fake-cosmos.documents.azure.com:443/",
            aadCredentials: expect.any(Object),
        })
    })

    test("defaults the database name to InfraMonitorDB when COSMOS_DATABASE is not set", () => {
        createCosmosContainer("Incidents", {
            COSMOS_ENDPOINT: "https://fake-cosmos.documents.azure.com:443/",
        })

        expect(mockDatabaseFn).toHaveBeenCalledWith("InfraMonitorDB")
    })

    test("uses COSMOS_DATABASE from env when set", () => {
        createCosmosContainer("Incidents", {
            COSMOS_ENDPOINT: "https://fake-cosmos.documents.azure.com:443/",
            COSMOS_DATABASE: "InfraMonitorTestDB",
        })

        expect(mockDatabaseFn).toHaveBeenCalledWith("InfraMonitorTestDB")
    })

    test("gets the container by the exact name passed in", () => {
        const result = createCosmosContainer("Incidents", {
            COSMOS_ENDPOINT: "https://fake-cosmos.documents.azure.com:443/",
        })

        expect(mockContainerFn).toHaveBeenCalledWith("Incidents")
        expect(result).toBe("the-container")
    })
})

describe("createServiceBusClient", () => {
    beforeEach(() => {
        jest.clearAllMocks()
    })

    test("throws a clear error when SERVICEBUS_NAMESPACE is missing", () => {
        expect(() => createServiceBusClient({})).toThrow(
            "Missing SERVICEBUS_NAMESPACE",
        )
        expect(ServiceBusClient).not.toHaveBeenCalled()
    })

    test("throws a clear error when SERVICEBUS_NAMESPACE is whitespace-only", () => {
        expect(() =>
            createServiceBusClient({ SERVICEBUS_NAMESPACE: "   " }),
        ).toThrow("Missing SERVICEBUS_NAMESPACE")
    })

    test("constructs ServiceBusClient with the trimmed namespace, an AAD credential, and AmqpWebSockets", () => {
        createServiceBusClient({
            SERVICEBUS_NAMESPACE: "  fake-ns.servicebus.windows.net  ",
        })

        expect(ServiceBusClient).toHaveBeenCalledWith(
            "fake-ns.servicebus.windows.net",
            expect.any(Object),
            { transportType: "AmqpWebSockets" },
        )
    })
})
