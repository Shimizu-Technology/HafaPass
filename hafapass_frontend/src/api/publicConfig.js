import apiClient from './client'

let pending

// Share overlapping boot requests, without caching fee/payment policy after
// the request settles. Later visits and retries still get fresh server data.
export function loadPublicConfig() {
  pending ||= Promise.resolve().then(() => apiClient.get('/config')).finally(() => { pending = null })
  return pending
}
