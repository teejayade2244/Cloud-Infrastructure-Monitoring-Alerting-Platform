export interface Event {
    id: string
    type: string
    environment: string
    severity: string
    message: string
    source: string
    timestamp: string
    status: string
    publishedToServiceBus?: boolean
}

export interface IncidentUpdate {
    message: string
    updatedBy: string
    status: string
    timestamp: string
}

export type Status = "open" | "investigating" | "resolved"

export interface Incident {
    id: string
    eventId: string
    title: string
    description: string
    severity: Severity
    environment: string
    status: Status
    assignedTo: string
    source: string
    createdAt: string
    resolvedAt: string | null
    updates: IncidentUpdate[]
}

export interface Notification {
    id: string
    eventId: string
    type: string
    severity: string
    message: string
    source: string
    environment: string
    channel: string
    sentAt: string
    status: string
}

export type Severity = "critical" | "high" | "medium" | "low" | "info"
export type Environment = "production" | "staging" | "development"
export type EventType =
    | "deployment"
    | "incident"
    | "alert"
    | "metric"
    | "recovery"
