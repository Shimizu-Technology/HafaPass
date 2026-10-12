export function safeReturnPath(value) {
  if (typeof value !== 'string' || !value.startsWith('/') || value.startsWith('//') || /[\\\r\n]/.test(value)) return '/'
  try {
    const url = new URL(value, window.location.origin)
    return url.origin === window.location.origin ? `${url.pathname}${url.search}${url.hash}` : '/'
  } catch {
    return '/'
  }
}

export function signInDestination(location) {
  const destination = `${location.pathname}${location.search}${location.hash}`
  return `/sign-in?returnTo=${encodeURIComponent(destination)}`
}

const intentKey = 'hafapass:auth-return-intent:v1'
const intentLifetime = 30 * 60 * 1000

export function createAuthReturnIntent(destination) {
  return { id: crypto.randomUUID(), destination: safeReturnPath(destination), expiresAt: Date.now() + intentLifetime }
}

export function readAuthReturnIntent() {
  try {
    const intent = JSON.parse(window.sessionStorage.getItem(intentKey) || 'null')
    if (typeof intent?.id !== 'string' || !intent.id || !Number.isFinite(intent.expiresAt)
      || intent.expiresAt <= Date.now() || intent.expiresAt > Date.now() + intentLifetime
      || typeof intent.destination !== 'string' || safeReturnPath(intent.destination) !== intent.destination) return null
    return intent
  } catch { return null }
}

export function storeAuthReturnIntent(intent) {
  try { window.sessionStorage.setItem(intentKey, JSON.stringify(intent)) } catch { /* The mounted auth journey still retains its in-memory intent. */ }
}

export function clearAuthReturnIntent(intentId) {
  try {
    if (readAuthReturnIntent()?.id === intentId) window.sessionStorage.removeItem(intentKey)
  } catch { /* Expiry and a fresh entry still prevent an old intent being reused. */ }
}
