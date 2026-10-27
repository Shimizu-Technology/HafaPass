export const RELEASE_RELOAD_PREFIX = 'hafapass_release_reload:'

export function validRevision(value) {
  return /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/i.test(value || '') ? value.toLowerCase() : null
}

export function canReloadForRelease({ pathname, hidden, navigated, unsaved, notFound }) {
  if (unsaved) return false
  let path
  try { path = decodeURIComponent(pathname).toLowerCase().replace(/\/+$/, '') || '/' }
  catch { return false }
  // These flows stay protected even when hidden or after another route change.
  // Include organizer/admin workspaces conservatively: they contain live work.
  if (/^\/(checkout|payments?|orders|tickets|ticket-transfers|dashboard|admin|support|privacy|account|sign-in|sign-up|organization-invitations|platform-invitations|unsubscribe)(\/|$)/.test(path)) return false
  // Event details own button-driven quantities, seat selections and hold requests.
  // Defer throughout that task; leaving for a safe destination permits updates.
  if (/^\/events\/[^/]+(\/|$)/.test(path)) return false
  const publicRoute = /^\/(?:events|host|discover|collections|about)?$/.test(path) || /^\/policies\/[^/]+$/.test(path)
  return Boolean(publicRoute || notFound || hidden || navigated)
}

// The caller supplies a revision from the shell the controlling worker serves,
// not just release.json: a new deploy can be online before its worker activates.
export function createReleaseReloadPolicy({ currentRevision, storage, reload, getState }) {
  let pending = null
  let pendingNavigationKey
  let reloading = false
  return {
    notice(revision) {
      const candidate = validRevision(revision)
      if (candidate && candidate !== currentRevision && candidate !== pending) {
        pending = candidate
        pendingNavigationKey = getState().navigationKey
      }
      this.attempt()
    },
    attempt() {
      if (!pending || reloading) return
      const state = getState()
      if (!canReloadForRelease({ ...state, navigated: state.navigationKey !== pendingNavigationKey })) return
      try {
        const key = RELEASE_RELOAD_PREFIX + pending
        if (storage.getItem(key)) return
        storage.setItem(key, '1')
      } catch { return } // Without a durable guard, defer rather than risk a loop.
      reloading = true
      reload()
    },
  }
}

// Covers forms which do not register with DraftNavigationProvider, including
// controlled React inputs whose defaultValue changes along with their value.
// A submission is not proof of a save; keep protection until the control leaves.
export function trackUnsavedInputs(doc) {
  const edited = new Set()
  const input = event => {
    const target = event.target.closest?.('input:not([type=button]):not([type=submit]):not([type=reset]), textarea, select, [contenteditable="true"], [contenteditable=""], [contenteditable="plaintext-only"]')
    if (target) edited.add(target)
  }
  doc.addEventListener('input', input, true)
  doc.addEventListener('change', input, true)
  return {
    hasUnsaved() {
      for (const element of edited) if (!element.isConnected) edited.delete(element)
      return edited.size > 0
    },
    dispose() {
      doc.removeEventListener('input', input, true)
      doc.removeEventListener('change', input, true)
    },
  }
}
