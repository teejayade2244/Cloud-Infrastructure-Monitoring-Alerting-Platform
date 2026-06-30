import { useState } from "react"
import { eventsApi } from "../services/api"

interface Props {
    onEventPublished: () => void
}

export default function EventForm({ onEventPublished }: Props) {
    const [form, setForm] = useState({
        type: "incident",
        environment: "production",
        severity: "critical",
        message: "",
        source: "",
    })
    const [submitting, setSubmitting] = useState(false)
    const [result, setResult] = useState<string | null>(null)

    const handleSubmit = async () => {
        if (!form.message || !form.source) return
        setSubmitting(true)
        setResult(null)
        try {
            const data = await eventsApi.publish(form)
            setResult(`✅ Event published: ${data.eventId}`)
            setForm((prev) => ({ ...prev, message: "", source: "" }))
            onEventPublished()
        } catch (err) {
            setResult("❌ Failed to publish event")
        }
        setSubmitting(false)
    }

    return (
        <div className="bg-gray-800 rounded-lg border border-gray-700 p-4">
            <h3 className="text-white font-medium mb-4">
                Publish Infrastructure Event
            </h3>
            <div className="grid grid-cols-3 gap-3 mb-3">
                <select
                    className="bg-gray-900 border border-gray-600 text-white rounded px-3 py-2 text-sm"
                    value={form.type}
                    onChange={(e) =>
                        setForm((prev) => ({ ...prev, type: e.target.value }))
                    }
                >
                    <option value="incident">Incident</option>
                    <option value="alert">Alert</option>
                    <option value="deployment">Deployment</option>
                    <option value="metric">Metric</option>
                    <option value="recovery">Recovery</option>
                </select>
                <select
                    className="bg-gray-900 border border-gray-600 text-white rounded px-3 py-2 text-sm"
                    value={form.environment}
                    onChange={(e) =>
                        setForm((prev) => ({
                            ...prev,
                            environment: e.target.value,
                        }))
                    }
                >
                    <option value="production">Production</option>
                    <option value="staging">Staging</option>
                    <option value="development">Development</option>
                </select>
                <select
                    className="bg-gray-900 border border-gray-600 text-white rounded px-3 py-2 text-sm"
                    value={form.severity}
                    onChange={(e) =>
                        setForm((prev) => ({
                            ...prev,
                            severity: e.target.value,
                        }))
                    }
                >
                    <option value="critical">Critical</option>
                    <option value="high">High</option>
                    <option value="medium">Medium</option>
                    <option value="low">Low</option>
                    <option value="info">Info</option>
                </select>
            </div>
            <div className="grid grid-cols-2 gap-3 mb-3">
                <input
                    className="bg-gray-900 border border-gray-600 text-white rounded px-3 py-2 text-sm"
                    placeholder="Source (e.g. prometheus, github-actions)"
                    value={form.source}
                    onChange={(e) =>
                        setForm((prev) => ({ ...prev, source: e.target.value }))
                    }
                />
                <input
                    className="bg-gray-900 border border-gray-600 text-white rounded px-3 py-2 text-sm"
                    placeholder="Message..."
                    value={form.message}
                    onChange={(e) =>
                        setForm((prev) => ({
                            ...prev,
                            message: e.target.value,
                        }))
                    }
                />
            </div>
            <div className="flex items-center gap-3">
                <button
                    onClick={handleSubmit}
                    disabled={submitting}
                    className="bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded text-sm disabled:opacity-50"
                >
                    {submitting ? "Publishing..." : "Publish Event"}
                </button>
                {result && <p className="text-sm text-gray-300">{result}</p>}
            </div>
        </div>
    )
}
