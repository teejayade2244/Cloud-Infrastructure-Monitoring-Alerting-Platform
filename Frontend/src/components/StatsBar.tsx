interface Props {
    totalEvents: number
    totalIncidents: number
    openIncidents: number
    criticalIncidents: number
}

export default function StatsBar({
    totalEvents,
    totalIncidents,
    openIncidents,
    criticalIncidents,
}: Props) {
    return (
        <div className="grid grid-cols-4 gap-4 mb-6">
            <div className="bg-gray-800 rounded-lg p-4 border border-gray-700">
                <p className="text-gray-400 text-sm">Total Events</p>
                <p className="text-white text-3xl font-bold mt-1">
                    {totalEvents}
                </p>
            </div>
            <div className="bg-gray-800 rounded-lg p-4 border border-gray-700">
                <p className="text-gray-400 text-sm">Total Incidents</p>
                <p className="text-white text-3xl font-bold mt-1">
                    {totalIncidents}
                </p>
            </div>
            <div className="bg-yellow-900 rounded-lg p-4 border border-yellow-700">
                <p className="text-yellow-300 text-sm">Open Incidents</p>
                <p className="text-white text-3xl font-bold mt-1">
                    {openIncidents}
                </p>
            </div>
            <div className="bg-red-900 rounded-lg p-4 border border-red-700">
                <p className="text-red-300 text-sm">Critical</p>
                <p className="text-white text-3xl font-bold mt-1">
                    {criticalIncidents}
                </p>
            </div>
        </div>
    )
}
