import type { Incident, Severity, Status } from "../types"
import { useState, type ChangeEvent } from "react"

interface UpdateForm {
    status: Status
    assignedTo?: string
    message: string
    updatedBy: string
}
import { incidentsApi } from "../services/api"

interface Props {
    incident: Incident
    onUpdate: () => void
}

const severityColors: Record<Severity, string> = {
    critical: "bg-red-500",
    high: "bg-orange-500",
    medium: "bg-yellow-500",
    low: "bg-blue-500",
    info: "bg-gray-500",
}

const statusColors: Record<Status, string> = {
    open: "text-red-400",
    investigating: "text-yellow-400",
    resolved: "text-green-400",
}

export default function IncidentCard({ incident, onUpdate }: Props) {
    const [expanded, setExpanded] = useState(false)
    const [updating, setUpdating] = useState<boolean>(false)
    const [updateForm, setUpdateForm] = useState<UpdateForm>({
        status: incident.status as Status,
        assignedTo: incident.assignedTo,
        message: "",
        updatedBy: "",
    })

    const handleUpdate = async (): Promise<void> => {
        if (!updateForm.message || !updateForm.updatedBy) return
        setUpdating(true)
        try {
            await incidentsApi.update(
                incident.id,
                incident.severity,
                updateForm,
            )
            onUpdate()
            setUpdateForm((prev) => ({ ...prev, message: "", updatedBy: "" }))
        } catch (err) {
            console.error(err)
        }
        setUpdating(false)
    }

    return (
        <div className="bg-gray-800 rounded-lg border border-gray-700 overflow-hidden">
            <div
                className="flex items-center justify-between p-4 cursor-pointer hover:bg-gray-750"
                onClick={() => setExpanded(!expanded)}
            >
                <div className="flex items-center gap-3">
                    <span
                        className={`w-2 h-2 rounded-full ${severityColors[incident.severity]}`}
                    />
                    <div>
                        <p className="text-white font-medium">
                            {incident.title}
                        </p>
                        <p className="text-gray-400 text-sm">
                            {incident.source} • {incident.environment}
                        </p>
                    </div>
                </div>
                <div className="flex items-center gap-4">
                    <span
                        className={`text-sm font-medium ${statusColors[incident.status]}`}
                    >
                        {incident.status.toUpperCase()}
                    </span>
                    <span className="text-gray-400 text-sm">
                        {new Date(incident.createdAt).toLocaleString()}
                    </span>
                    <span className="text-gray-400">
                        {expanded ? "▲" : "▼"}
                    </span>
                </div>
            </div>

            {expanded && (
                <div className="border-t border-gray-700 p-4 space-y-4">
                    <div className="grid grid-cols-2 gap-4 text-sm">
                        <div>
                            <p className="text-gray-400">Assigned To</p>
                            <p className="text-white">
                                {incident.assignedTo || "Unassigned"}
                            </p>
                        </div>
                        <div>
                            <p className="text-gray-400">Event ID</p>
                            <p className="text-white font-mono text-xs">
                                {incident.eventId}
                            </p>
                        </div>
                    </div>

                    {incident.updates.length > 0 && (
                        <div>
                            <p className="text-gray-400 text-sm mb-2">
                                Update History
                            </p>
                            <div className="space-y-2">
                                {incident.updates.map((update, i) => (
                                    <div
                                        key={i}
                                        className="bg-gray-900 rounded p-3 text-sm"
                                    >
                                        <div className="flex justify-between text-gray-400 mb-1">
                                            <span>{update.updatedBy}</span>
                                            <span>
                                                {new Date(
                                                    update.timestamp,
                                                ).toLocaleString()}
                                            </span>
                                        </div>
                                        <p className="text-white">
                                            {update.message}
                                        </p>
                                    </div>
                                ))}
                            </div>
                        </div>
                    )}

                    <div className="border-t border-gray-700 pt-4">
                        <p className="text-gray-400 text-sm mb-3">
                            Update Incident
                        </p>
                        <div className="grid grid-cols-2 gap-3 mb-3">
                            <select
                                className="bg-gray-900 border border-gray-600 text-white rounded px-3 py-2 text-sm"
                                value={updateForm.status}
                                onChange={(e: ChangeEvent<HTMLSelectElement>) =>
                                    setUpdateForm((prev) => ({
                                        ...prev,
                                        status: e.target.value as Status,
                                    }))
                                }
                            >
                                <option value="open">Open</option>
                                <option value="investigating">
                                    Investigating
                                </option>
                                <option value="resolved">Resolved</option>
                            </select>
                            <input
                                className="bg-gray-900 border border-gray-600 text-white rounded px-3 py-2 text-sm"
                                placeholder="Assign to..."
                                value={updateForm.assignedTo}
                                onChange={(e: ChangeEvent<HTMLInputElement>) =>
                                    setUpdateForm((prev) => ({
                                        ...prev,
                                        assignedTo: e.target.value,
                                    }))
                                }
                            />
                        </div>
                        <div className="grid grid-cols-2 gap-3 mb-3">
                            <input
                                className="bg-gray-900 border border-gray-600 text-white rounded px-3 py-2 text-sm"
                                placeholder="Your name..."
                                value={updateForm.updatedBy}
                                onChange={(e: ChangeEvent<HTMLInputElement>) =>
                                    setUpdateForm((prev) => ({
                                        ...prev,
                                        updatedBy: e.target.value,
                                    }))
                                }
                            />
                            <textarea
                                className="bg-gray-900 border border-gray-600 text-white rounded px-3 py-2 text-sm col-span-2"
                                placeholder="Describe the update..."
                                rows={3}
                                value={updateForm.message}
                                onChange={(e: ChangeEvent<HTMLTextAreaElement>) =>
                                    setUpdateForm((prev) => ({
                                        ...prev,
                                        message: e.target.value,
                                    }))
                                }
                            />
                        </div>

                        <div className="flex justify-end">
                            <button
                                type="button"
                                className="bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded text-sm disabled:opacity-50"
                                disabled={
                                    updating ||
                                    !updateForm.message ||
                                    !updateForm.updatedBy
                                }
                                onClick={handleUpdate}
                            >
                                {updating ? "Updating..." : "Update Incident"}
                            </button>
                        </div>
                    </div>
                </div>
            )}
        </div>
    )
}
