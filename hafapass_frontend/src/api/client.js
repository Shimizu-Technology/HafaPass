import axios from 'axios'

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

// Helper to set the auth token getter (called from ClerkProvider wrapper)
export function setAuthTokenGetter(getter) {
  apiClient._authTokenGetter = getter
}

export default apiClient
