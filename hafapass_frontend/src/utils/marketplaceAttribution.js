const VISITOR_KEY = 'hafapass_anonymous_id'
const ATTRIBUTION_KEY = 'hafapass_attribution'

export function anonymousId() {
  let value = localStorage.getItem(VISITOR_KEY)
  if (!value) {
    value = crypto.randomUUID()
    localStorage.setItem(VISITOR_KEY, value)
  }
  return value
}

export function saveAttribution(attribution) {
  const values = Object.fromEntries(Object.entries(attribution).filter(([, value]) => value))
  localStorage.setItem(ATTRIBUTION_KEY, JSON.stringify({ ...currentAttribution(), ...values, captured_at: new Date().toISOString() }))
}

export function currentAttribution() {
  try {
    const stored = JSON.parse(localStorage.getItem(ATTRIBUTION_KEY) || 'null')
    if (!stored) return {}
    if (Date.now() - new Date(stored.captured_at).getTime() > 30 * 24 * 60 * 60 * 1000) return {}
    return stored
  } catch {
    return {}
  }
}

export function captureQueryAttribution(search) {
  const params = new URLSearchParams(search)
  const values = {
    source: params.get('utm_source'), medium: params.get('utm_medium'), campaign: params.get('utm_campaign'),
    distribution_code: params.get('distribution_code'), event_referral_code: params.get('event_referral_code'),
  }
  if (Object.values(values).some(Boolean)) saveAttribution(values)
}

export function trackFunnel(apiClient, eventId, stage) {
  const attribution = currentAttribution()
  return apiClient.post('/marketplace_funnel_events', {
    event_id: eventId, stage, anonymous_id: anonymousId(), ...attribution,
  }).catch(() => {})
}
