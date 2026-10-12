export const SCANNER_OWNER_KEY = 'hafapass_scanner_user_id'
const PENDING_BINDING_KEY = 'hafapass_scanner_binding_pending'
let bindingBlocked = false

export function hasPendingScannerBinding() {
  if (bindingBlocked) return true
  try { return window.localStorage.getItem(PENDING_BINDING_KEY) !== null } catch { return true }
}

export function currentScannerOwner() {
  if (hasPendingScannerBinding()) return null
  try { return window.localStorage.getItem(SCANNER_OWNER_KEY) || (import.meta.env.PROD ? null : 'local-preview') } catch { return null }
}

// Withdraw before opening IndexedDB. A failed/interrupted purge must remain
// inaccessible across route changes, Clerk loading, and a fresh app boot.
export function withdrawScannerBinding() {
  bindingBlocked = true
  window.localStorage.setItem(PENDING_BINDING_KEY, 'pending')
}

export function completeScannerBinding(owner) {
  if (owner) window.localStorage.setItem(SCANNER_OWNER_KEY, owner)
  else window.localStorage.removeItem(SCANNER_OWNER_KEY)
  window.localStorage.removeItem(PENDING_BINDING_KEY)
  bindingBlocked = false
}
