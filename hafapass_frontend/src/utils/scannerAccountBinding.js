export const SCANNER_OWNER_KEY = 'hafapass_scanner_user_id'
const PENDING_BINDING_KEY = 'hafapass_scanner_binding_pending'
const WITHDRAWN_OWNER = '!'
let bindingBlocked = false
let revision = 0
let withdrawalRevision = 0
const listeners = new Set()

const notify = () => { ++revision; listeners.forEach(listener => listener()) }
const storageChanged = event => {
  if ((!event.storageArea || event.storageArea === window.localStorage)
    && (event.key === null || [SCANNER_OWNER_KEY, PENDING_BINDING_KEY].includes(event.key))) {
    if (event.key === null || (event.key === PENDING_BINDING_KEY && event.newValue !== null)
      || (event.key === SCANNER_OWNER_KEY && (event.newValue === null || event.newValue === WITHDRAWN_OWNER))) {
      ++withdrawalRevision
      // A peer can finish sign-out before this tab resolves Clerk. Keep our
      // own withdrawal pending across remount/reload until preparation succeeds.
      try { window.sessionStorage.setItem(PENDING_BINDING_KEY, 'pending') } catch { bindingBlocked = true }
    }
    notify()
  }
}

export function subscribeScannerBinding(listener) {
  if (!listeners.size) window.addEventListener('storage', storageChanged)
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
    if (!listeners.size) window.removeEventListener('storage', storageChanged)
  }
}
export const scannerBindingRevision = () => revision
export const scannerWithdrawalRevision = () => withdrawalRevision

export function captureScannerBindingContext() {
  try {
    return { owner: window.localStorage.getItem(SCANNER_OWNER_KEY),
      pending: window.localStorage.getItem(PENDING_BINDING_KEY),
      sessionPending: window.sessionStorage.getItem(PENDING_BINDING_KEY), revision }
  } catch { return null }
}

export function scannerBindingContextCurrent(context) {
  const latest = captureScannerBindingContext()
  return Boolean(context && latest && Object.keys(context).every(key => context[key] === latest[key]))
}

export function hasPendingScannerBinding() {
  if (bindingBlocked) return true
  const context = captureScannerBindingContext()
  return !context || context.pending !== null || context.sessionPending !== null || context.owner === WITHDRAWN_OWNER
}

export function currentScannerOwner() {
  if (hasPendingScannerBinding()) return null
  try {
    return window.localStorage.getItem(SCANNER_OWNER_KEY)
      || (!import.meta.env.PROD && !import.meta.env.VITE_CLERK_PUBLISHABLE_KEY ? 'local-preview' : null)
  } catch { return null }
}

// Withdraw before opening IndexedDB. A failed/interrupted purge must remain
// inaccessible across route changes, Clerk loading, and a fresh app boot.
export function withdrawScannerBinding() {
  bindingBlocked = true
  ++withdrawalRevision
  // Creating a key can fail at quota while shrinking an existing owner succeeds.
  // The sentinel is deliberately not a Clerk identity or preview authorization.
  try { window.localStorage.setItem(PENDING_BINDING_KEY, 'pending') } catch {
    try { window.localStorage.setItem(SCANNER_OWNER_KEY, WITHDRAWN_OWNER) } catch {
      try { window.localStorage.removeItem(SCANNER_OWNER_KEY) } catch { /* Continue the IndexedDB purge even when storage cannot be changed. */ }
    }
    // Protect a reload of this tab even when all localStorage writes fail.
    try { window.sessionStorage.setItem(PENDING_BINDING_KEY, 'pending') } catch { /* The in-memory lock and IndexedDB purge still apply. */ }
  }
  notify()
}

export function completeScannerBinding(owner, { context } = {}) {
  if (context && !scannerBindingContextCurrent(context)) throw Object.assign(new Error('Scanner binding changed in another tab'), { manifestContextChanged: true })
  bindingBlocked = true
  try {
    if (owner) window.localStorage.setItem(SCANNER_OWNER_KEY, owner)
    else window.localStorage.removeItem(SCANNER_OWNER_KEY)
    window.localStorage.removeItem(PENDING_BINDING_KEY)
    window.sessionStorage.removeItem(PENDING_BINDING_KEY)
    bindingBlocked = false
  } finally { notify() }
}
