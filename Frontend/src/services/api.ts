import axios from "axios"

const APIM_BASE = "https://inframonitor-apim.azure-api.net"
const API_KEY = import.meta.env.VITE_APIM_KEY

const headers = {
    "Ocp-Apim-Subscription-Key": API_KEY,
    "Content-Type": "application/json",
}

export const eventsApi = {
    getAll: async (params?: {
        environment?: string
        severity?: string
        type?: string
    }) => {
        const res = await axios.get(`${APIM_BASE}/events-api/events`, {
            headers,
            params,
        })
        return res.data
    },
    publish: async (event: {
        type: string
        environment: string
        severity: string
        message: string
        source: string
    }) => {
        const res = await axios.post(`${APIM_BASE}/events-api/events`, event, {
            headers,
        })
        return res.data
    },
}

export const notificationsApi = {
    getAll: async () => {
        const res = await axios.get(`${APIM_BASE}/incidents-api/notifications`, { headers })
        return res.data
    }
}

// export const notificationsApi = {
//     getAll: async () => {
//         const res = await axios.get(`${APIM_BASE}/incidents-api/notifications`, { headers })
//         return res.data
//     }
// }

export const incidentsApi = {
    getAll: async (params?: {
        severity?: string
        status?: string
        environment?: string
    }) => {
        const res = await axios.get(`${APIM_BASE}/incidents-api/incidents`, {
            headers,
            params,
        })
        return res.data
    },
    getById: async (id: string, severity: string) => {
        const res = await axios.get(
            `${APIM_BASE}/incidents-api/incidents/${id}`,
            {
                headers,
                params: { severity },
            },
        )
        return res.data
    },
    update: async (
        id: string,
        severity: string,
        data: {
            status: string
            assignedTo?: string
            message: string
            updatedBy: string
        },
    ) => {
        const res = await axios.patch(
            `${APIM_BASE}/incidents-api/incidents/${id}`,
            data,
            {
                headers,
                params: { severity },
            },
        )
        return res.data
    },
}
