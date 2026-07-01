import { useCallback, useEffect, useState } from "react"
import { notificationsApi } from "../services/api"
import type { Notification } from "../types"

const severityColors: Record<string, string> = {
    critical: "border-red-500 bg-red-950",
    high: "border-orange-500 bg-orange-950",
    medium: "border-yellow-500 bg-yellow-950",
    low: "border-blue-500 bg-blue-950",
    info: "border-gray-500 bg-gray-900",
}

const channelIcon: Record<string, string> = {
    email: "📧",
    platform: "🔔",
    slack: "💬",
}

export default function NotificationsList() {
    const [notifications, setNotifications] = useState<Notification[]>([])
    const [loading, setLoading] = useState(true)

    const fetchNotifications = useCallback(async () => {
        setLoading(true)
        try {
            const data = await notificationsApi.getAll()
            setNotifications(data.notifications)
        } catch (err) {
            console.error(err)
        }
        setLoading(false)
    }, [])

    useEffect(() => {
        void Promise.resolve().then(fetchNotifications)
    }, [fetchNotifications])

    return (
        <div>
            <div className="flex justify-between items-center mb-4">
                <p className="text-gray-400 text-sm">
                    {notifications.length} notifications
                </p>
                <button
                    onClick={fetchNotifications}
                    className="bg-gray-700 hover:bg-gray-600 text-white px-4 py-2 rounded text-sm"
                >
                    Refresh
                </button>
            </div>

            {loading ? (
                <div className="text-center text-gray-400 py-8">
                    Loading notifications...
                </div>
            ) : notifications.length === 0 ? (
                <div className="text-center text-gray-400 py-8">
                    No notifications yet
                </div>
            ) : (
                <div className="space-y-3">
                    {notifications.map((notification) => (
                        <div
                            key={notification.id}
                            className={`rounded-lg border-l-4 p-4 ${severityColors[notification.severity] || severityColors.info}`}
                        >
                            <div className="flex items-start justify-between">
                                <div className="flex items-start gap-3">
                                    <span className="text-xl">
                                        {channelIcon[notification.channel] ||
                                            "🔔"}
                                    </span>
                                    <div>
                                        <p className="text-white font-medium">
                                            {notification.message}
                                        </p>
                                        <p className="text-gray-400 text-sm mt-1">
                                            {notification.source} •{" "}
                                            {notification.environment} •{" "}
                                            {notification.channel}
                                        </p>
                                    </div>
                                </div>
                                <div className="text-right shrink-0 ml-4">
                                    <span
                                        className={`text-xs font-medium px-2 py-1 rounded ${
                                            notification.severity === "critical"
                                                ? "bg-red-600 text-white"
                                                : notification.severity ===
                                                    "high"
                                                  ? "bg-orange-600 text-white"
                                                  : "bg-gray-600 text-white"
                                        }`}
                                    >
                                        {notification.severity.toUpperCase()}
                                    </span>
                                    <p className="text-gray-400 text-xs mt-2">
                                        {new Date(
                                            notification.sentAt,
                                        ).toLocaleString()}
                                    </p>
                                </div>
                            </div>
                        </div>
                    ))}
                </div>
            )}
        </div>
    )
}
