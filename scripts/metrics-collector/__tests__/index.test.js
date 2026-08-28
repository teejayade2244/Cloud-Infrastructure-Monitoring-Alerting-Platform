const { durationSeconds } = require("../index")

describe("durationSeconds", () => {
    it("computes whole seconds between two ISO timestamps", () => {
        expect(
            durationSeconds("2026-08-28T00:00:00Z", "2026-08-28T00:00:30Z"),
        ).toBe(30)
    })

    it("computes fractional seconds", () => {
        expect(
            durationSeconds(
                "2026-08-28T00:00:00.000Z",
                "2026-08-28T00:00:00.500Z",
            ),
        ).toBe(0.5)
    })

    it("returns a negative value when completedAt precedes startedAt", () => {
        expect(
            durationSeconds("2026-08-28T00:00:30Z", "2026-08-28T00:00:00Z"),
        ).toBe(-30)
    })
})
