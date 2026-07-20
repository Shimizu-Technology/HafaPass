import axios from 'axios'
import { Sentry } from '../monitoring'

export function monitoringPath(url) {
  return url
    ?.split('?')[0]
    .replace(/\/[0-9a-f-]{8,}/gi, '/:id')
    .replace(/\/\d+/g, '/:id')
}

const apiClient = axios.create({
  baseURL: import.meta.env.VITE_API_URL || 'http://localhost:3000/api/v1',
  headers: {
    'Content-Type': 'application/json',
  },
})

// Request interceptor to attach auth token when available
apiClient.interceptors.request.use(async (config) => {
  // Clerk token will be attached here once auth is configured (Task 3)
  // The token is set via setAuthToken() called from the ClerkProvider wrapper
  if (apiClient._authTokenGetter) {
    try {
      const token = await apiClient._authTokenGetter()
      if (token) {
        config.headers.Authorization = `Bearer ${token}`
      }
    } catch {
      // Silently fail if token retrieval fails
    }
  }
  return config
})

apiClient.interceptors.response.use(
  response => response,
  (error) => {
    if (error.response?.status >= 500) {
      const monitoringError = new Error(`API request failed with status ${error.response.status}`)
      monitoringError.name = 'ApiRequestError'

      Sentry.captureException(monitoringError, {
        tags: {
          api_method: error.config?.method,
          api_path: monitoringPath(error.config?.url),
          api_status: error.response.status,
        },
      })
    }
    return Promise.reject(error)
  },
)

// Helper to set the auth token getter (called from ClerkProvider wrapper)
export function setAuthTokenGetter(getter) {
  apiClient._authTokenGetter = getter
}

export default apiClient
