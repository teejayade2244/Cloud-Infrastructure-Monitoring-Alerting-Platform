const { durationSeconds, percentile, escapeLabelValue } = require("../index")

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

describe("percentile", () => {
    it("returns the exact value for a single-element array", () => {
        expect(percentile([42], 95)).toBe(42)
    })

    it("returns the max for p95 of a small sorted array", () => {
        // ceil(0.95 * 4) - 1 = 3 -> last index, matches the real n=17-45 sample sizes this
        // is actually used against - p95 of a short array is expected to land near the max.
        expect(percentile([1, 2, 3, 100], 95)).toBe(100)
    })

    it("returns the median for p50 of a sorted array", () => {
        expect(percentile([10, 20, 30, 40], 50)).toBe(20)
    })
})

describe("escapeLabelValue", () => {
    it("passes through ordinary job names unchanged", () => {
        expect(escapeLabelValue("call-service-ci / Docker Build")).toBe(
            "call-service-ci / Docker Build",
        )
    })

    it("escapes double quotes and backslashes", () => {
        expect(escapeLabelValue('a "quoted" \\ value')).toBe(
            'a \\"quoted\\" \\\\ value',
        )
    })
})
