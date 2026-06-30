import { useEffect, useState } from "react"
import StatsBar from "./components/StatsBar"
import IncidentsList from "./components/IncidentsList"
import EventForm from "./components/EventForm"
import { incidentsApi, eventsApi } from "./services/api"
import type { Incident, Event } from "./types"

export default function App() {
    const [incidents, setIncidents] = useState<Incident[]>([])
    const [events, setEvents] = useState<Event[]>([])
    const [activeTab, setActiveTab] = useState<"incidents" | "publish">(
        "incidents",
    )
    const [refreshKey, setRefreshKey] = useState(0)

    const fetchStats = async () => {
        try {
            const [incData, evData] = await Promise.all([
                incidentsApi.getAll(),
                eventsApi.getAll(),
            ])
            setIncidents(incData.incidents)
            setEvents(evData.events)
        } catch (err) {
            console.error(err)
        }
    }

    useEffect(() => {
        fetchStats()
    }, [refreshKey])

    const openIncidents = incidents.filter((i) => i.status === "open").length
    const criticalIncidents = incidents.filter(
        (i) => i.severity === "critical",
    ).length

    return (
        <div className="min-h-screen bg-gray-900 text-white">
            {/* Header */}
            <header className="bg-gray-800 border-b border-gray-700 px-6 py-4">
                <div className="max-w-7xl mx-auto flex items-center justify-between">
                    <div className="flex items-center gap-3">
                        <div className="w-8 h-8 bg-blue-600 rounded-lg flex items-center justify-center">
                            <span className="text-white font-bold text-sm">
                                IM
                            </span>
                        </div>
                        <div>
                            <h1 className="text-white font-bold text-lg">
                                InfraMonitor
                            </h1>
                            <p className="text-gray-400 text-xs">
                                Cloud Infrastructure Monitoring Platform
                            </p>
                        </div>
                    </div>
                    <div className="flex items-center gap-2">
                        <div className="w-2 h-2 bg-green-400 rounded-full animate-pulse" />
                        <span className="text-gray-400 text-sm">Live</span>
                    </div>
                </div>
            </header>

            <main className="max-w-7xl mx-auto px-6 py-6">
                {/* Stats */}
                <StatsBar
                    totalEvents={events.length}
                    totalIncidents={incidents.length}
                    openIncidents={openIncidents}
                    criticalIncidents={criticalIncidents}
                />

                {/* Tabs */}
                <div className="flex gap-2 mb-6">
                    <button
                        onClick={() => setActiveTab("incidents")}
                        className={`px-4 py-2 rounded text-sm font-medium ${
                            activeTab === "incidents"
                                ? "bg-blue-600 text-white"
                                : "bg-gray-800 text-gray-400 hover:text-white"
                        }`}
                    >
                        Incidents
                    </button>
                    <button
                        onClick={() => setActiveTab("publish")}
                        className={`px-4 py-2 rounded text-sm font-medium ${
                            activeTab === "publish"
                                ? "bg-blue-600 text-white"
                                : "bg-gray-800 text-gray-400 hover:text-white"
                        }`}
                    >
                        Publish Event
                    </button>
                </div>

                {/* Content */}
                {activeTab === "incidents" && (
                    <IncidentsList key={refreshKey} />
                )}
                {activeTab === "publish" && (
                    <EventForm
                        onEventPublished={() => setRefreshKey((k) => k + 1)}
                    />
                )}
            </main>
        </div>
    )
}
