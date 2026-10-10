import axios from 'axios'
import { Sentry } from '../monitoring'
import { monitoringPath } from '../utils/telemetryPrivacy'
export { monitoringPath } from '../utils/telemetryPrivacy'

const apiClient = axios.create({
  baseURL: import.meta.env.VITE_API_URL || 'http://localhost:3000/api/v1',
  headers: {
    'Content-Type': 'application/json',
  },
})

let authContext = null
let authGeneration = 0
const authSubscribers = new Set()

export const getApiAuthContext = () => authContext
export function subscribeApiAuthContext(callback) {
  authSubscribers.add(callback)
  return () => authSubscribers.delete(callback)
}

function assertCurrentAuth(expected) {
  // Axios copies custom configuration objects when merging request options.
  if (expected && (!authContext?.ready || !expected.ready
    || expected.generation !== authContext.generation || expected.userId !== authContext.userId
    || expected.sessionId !== authContext.sessionId)) {
    throw new axios.CanceledError('Account authorization changed')
  }
}

// Request interceptor to attach auth token when available
apiClient.interceptors.request.use(async (config) => {
  // Account-sensitive callers can bind a request to the installed Clerk session.
  // A token that resolves after a session change must never reach the transport.
  assertCurrentAuth(config.authContext)
  const organizationId = window.localStorage.getItem('hafapass_organization_id')
  if (organizationId) config.headers['X-Organization-Id'] = organizationId

  if (apiClient._authTokenGetter) {
    try {
      const token = await apiClient._authTokenGetter()
      assertCurrentAuth(config.authContext)
      if (config.authContext && !token) throw new Error('Account authorization is not ready')
      if (token) {
        config.headers.Authorization = `Bearer ${token}`
      }
    } catch (error) {
      if (config.authContext) throw error
    }
  } else if (config.authContext) {
    throw new Error('Account authorization is not ready')
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
export function setAuthTokenGetter(getter, identity = {}) {
  apiClient._authTokenGetter = getter
  const installed = Object.freeze({
    generation: ++authGeneration,
    userId: identity.userId || null,
    sessionId: identity.sessionId || null,
    ready: Boolean(getter && identity.ready && identity.userId && identity.sessionId),
  })
  authContext = installed
  authSubscribers.forEach(callback => callback())
  return () => {
    if (authContext !== installed) return
    apiClient._authTokenGetter = null
    authContext = null
    authSubscribers.forEach(callback => callback())
  }
}

export default apiClient
