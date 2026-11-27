import posthog from 'posthog-js'

export const DEFAULT_POSTHOG_HOST = 'https://us.i.posthog.com'

export const SENSITIVE_QUERY_PARAMS = new Set([
  'token',
  'session_id',
  'payment_intent',
  'payment_intent_client_secret',
  'code',
  'state',
  'email',
])

const URL_PROPERTY_KEYS = new Set([
  '$current_url',
  '$referrer',
  '$initial_current_url',
  '$initial_referrer',
  'url',
  'href',
])

const PLACEHOLDER_KEY_PATTERN =
  /^(?:phc_)?(?:x+|your[_-]?.*|placeholder.*|changeme.*|replace[_-]?me.*|example.*|dummy.*|fake.*|test[_-]?key.*|<.*>)$/i

let initialized = false

export function isPlaceholderPostHogKey(key) {
  if (typeof key !== 'string') return true
  const trimmed = key.trim()
  if (!trimmed) return true
  return PLACEHOLDER_KEY_PATTERN.test(trimmed)
}

export function isPostHogEnabled(env = import.meta.env) {
  if (!env || env.VITE_HAFAPASS_DEMO_DATA === '1') return false
  if (isPlaceholderPostHogKey(env.VITE_PUBLIC_POSTHOG_KEY)) return false
  const isProd = env.PROD === true || env.PROD === 'true'
  const enabledInDev = env.VITE_ENABLE_ANALYTICS_IN_DEV === 'true'
  return isProd || enabledInDev
}

export function sanitizePathForAnalytics(pathname) {
  if (typeof pathname !== 'string') return pathname
  return pathname
    .replace(/(\/tickets\/)[^/]+/gi, '$1[redacted]')
    .replace(/(\/email-confirm\/)[^/]+/gi, '$1[redacted]')
    .replace(/(\/email-preferences\/)[^/]+/gi, '$1[redacted]')
    .replace(/(\/unsubscribe\/)[^/]+/gi, '$1[redacted]')
    .replace(/(\/ticket-transfers\/)(?!accept(?:\/|$))[^/]+/gi, '$1[redacted]')
    .replace(/(\/organization-invitations\/)(?!accept(?:\/|$))[^/]+/gi, '$1[redacted]')
    .replace(/(\/platform-invitations\/)(?!accept(?:\/|$))[^/]+/gi, '$1[redacted]')
}

export function sanitizeUrlForAnalytics(
  rawUrl,
  origin = globalThis.location?.origin || 'https://hafapass.app',
) {
  if (typeof rawUrl !== 'string' || !rawUrl) return rawUrl

  const isAbsolute = /^https?:\/\//i.test(rawUrl)

  try {
    const parsed = new URL(rawUrl, origin)
    parsed.pathname = sanitizePathForAnalytics(parsed.pathname)

    for (const key of Array.from(parsed.searchParams.keys())) {
      if (SENSITIVE_QUERY_PARAMS.has(key.toLowerCase())) {
        parsed.searchParams.delete(key)
      }
    }

    if (parsed.hash && parsed.hash.includes('=')) {
      const hashParams = new URLSearchParams(parsed.hash.slice(1))
      let redactedHash = false
      for (const key of Array.from(hashParams.keys())) {
        if (SENSITIVE_QUERY_PARAMS.has(key.toLowerCase())) {
          hashParams.delete(key)
          redactedHash = true
        }
      }
      if (redactedHash) {
        const nextHash = hashParams.toString()
        parsed.hash = nextHash ? `#${nextHash}` : ''
      }
    }

    return isAbsolute
      ? parsed.toString()
      : `${parsed.pathname}${parsed.search}${parsed.hash}`
  } catch {
    return sanitizePathForAnalytics(rawUrl.split(/[?#]/)[0])
  }
}

export function sanitizePostHogProperties(properties) {
  if (!properties || typeof properties !== 'object') return properties

  const sanitized = { ...properties }
  for (const [key, value] of Object.entries(sanitized)) {
    const lowerKey = key.toLowerCase()
    if (SENSITIVE_QUERY_PARAMS.has(lowerKey)) {
      sanitized[key] = '[redacted]'
    } else if (typeof value === 'string' && URL_PROPERTY_KEYS.has(lowerKey)) {
      sanitized[key] = sanitizeUrlForAnalytics(value)
    } else if (
      typeof value === 'string' &&
      (lowerKey === '$pathname' || lowerKey === '$prev_pageview_pathname')
    ) {
      sanitized[key] = sanitizePathForAnalytics(value)
    } else if (typeof value === 'string' && /^https?:\/\//i.test(value)) {
      sanitized[key] = sanitizeUrlForAnalytics(value)
    }
  }
  return sanitized
}

export function buildPostHogOptions(env = import.meta.env) {
  const configuredHost = typeof env?.VITE_PUBLIC_POSTHOG_HOST === 'string'
    ? env.VITE_PUBLIC_POSTHOG_HOST.trim()
    : ''

  return {
    api_host: configuredHost || DEFAULT_POSTHOG_HOST,
    capture_pageview: false,
    capture_pageleave: true,
    autocapture: true,
    disable_session_recording: false,
    session_recording: {
      maskAllInputs: true,
      blockClass: 'ph-no-capture',
    },
    sanitize_properties: sanitizePostHogProperties,
  }
}

export function initPostHog(env = import.meta.env, client = posthog) {
  if (initialized) return true
  if (!isPostHogEnabled(env)) return false

  client.init(env.VITE_PUBLIC_POSTHOG_KEY.trim(), buildPostHogOptions(env))
  initialized = true
  return true
}

export function isPostHogInitialized() {
  return initialized
}

export function capturePostHogPageView(location, client = posthog) {
  if (!initialized || !location) return false

  const origin = globalThis.location?.origin || 'https://hafapass.app'
  const rawUrl = `${origin}${location.pathname || '/'}${location.search || ''}${location.hash || ''}`
  const sanitizedUrl = sanitizeUrlForAnalytics(rawUrl, origin)

  client.capture('$pageview', {
    $current_url: sanitizedUrl,
  })
  return true
}

export function resetPostHogStateForTests() {
  initialized = false
}
