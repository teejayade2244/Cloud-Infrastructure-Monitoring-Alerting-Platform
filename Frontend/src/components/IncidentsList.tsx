import { useEffect, useState } from "react"
import type { Incident } from "../types"
import { incidentsApi } from "../services/api"
import IncidentCard from "./IncidentCard"

export default function IncidentsList() {
    const [incidents, setIncidents] = useState<Incident[]>([])
    const [loading, setLoading] = useState(true)
    const [filter, setFilter] = useState({
        severity: "",
        status: "",
        environment: "",
    })

    const fetchIncidents = async () => {
        setLoading(true)
        try {
            const data = await incidentsApi.getAll({
                severity: filter.severity || undefined,
                status: filter.status || undefined,
                environment: filter.environment || undefined,
            })
            setIncidents(data.incidents)
        } catch (err) {
            console.error(err)
        }
        setLoading(false)
    }

    useEffect(() => {
        fetchIncidents()
    }, [filter])

    return (
        <div>
            <div className="flex gap-3 mb-4">
                <select
                    className="bg-gray-800 border border-gray-600 text-white rounded px-3 py-2 text-sm"
                    value={filter.severity}
                    onChange={(e) =>
                        setFilter((prev) => ({
                            ...prev,
                            severity: e.target.value,
                        }))
                    }
                >
                    <option value="">All Severities</option>
                    <option value="critical">Critical</option>
                    <option value="high">High</option>
                    <option value="medium">Medium</option>
                    <option value="low">Low</option>
                </select>
                <select
                    className="bg-gray-800 border border-gray-600 text-white rounded px-3 py-2 text-sm"
                    value={filter.status}
                    onChange={(e) =>
                        setFilter((prev) => ({
                            ...prev,
                            status: e.target.value,
                        }))
                    }
                >
                    <option value="">All Statuses</option>
                    <option value="open">Open</option>
                    <option value="investigating">Investigating</option>
                    <option value="resolved">Resolved</option>
                </select>
                <select
                    className="bg-gray-800 border border-gray-600 text-white rounded px-3 py-2 text-sm"
                    value={filter.environment}
                    onChange={(e) =>
                        setFilter((prev) => ({
                            ...prev,
                            environment: e.target.value,
                        }))
                    }
                >
                    <option value="">All Environments</option>
                    <option value="production">Production</option>
                    <option value="staging">Staging</option>
                    <option value="development">Development</option>
                </select>
                <button
                    onClick={fetchIncidents}
                    className="bg-gray-700 hover:bg-gray-600 text-white px-4 py-2 rounded text-sm ml-auto"
                >
                    Refresh
                </button>
            </div>

            {loading ? (
                <div className="text-center text-gray-400 py-8">
                    Loading incidents...
                </div>
            ) : incidents.length === 0 ? (
                <div className="text-center text-gray-400 py-8">
                    No incidents found
                </div>
            ) : (
                <div className="space-y-3">
                    {incidents.map((incident) => (
                        <IncidentCard
                            key={incident.id}
                            incident={incident}
                            onUpdate={fetchIncidents}
                        />
                    ))}
                </div>
            )}
        </div>
    )
}
