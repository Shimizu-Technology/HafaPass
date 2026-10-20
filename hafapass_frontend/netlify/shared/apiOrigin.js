// The Rails API origin for edge functions comes from the Netlify environment
// variable HAFAPASS_API_ORIGIN (e.g. https://api.example.com, no /api/v1).
// It is configuration so the API can move hosts without a code change.
export const API_ORIGIN_ENV = 'HAFAPASS_API_ORIGIN'

export function apiOrigin(env = globalThis.Netlify?.env) {
  try {
    const url = new URL(String(env?.get(API_ORIGIN_ENV) || '').trim())
    return ['https:', 'http:'].includes(url.protocol) ? url.origin : null
  } catch {
    return null
  }
}
