// Deliberately separate from package.json's "jest" key (the unit test config): integration
// tests make real network calls against real Azure resources and take much longer than the
// mocked unit suite, so they need their own timeout, no coverage enforcement (coverage
// thresholds belong to the unit suite, which is what's actually exercising every branch), and
// forceExit, since the real Cosmos/Service Bus SDK clients (both the app's own and this file's
// verification client) hold open connections that are never explicitly torn down - fine for a
// long-running service, but would otherwise hang the test process on exit.
module.exports = {
    testEnvironment: "node",
    testMatch: ["<rootDir>/__tests__/integration/**/*.test.js"],
    testTimeout: 30000,
    forceExit: true,
}
