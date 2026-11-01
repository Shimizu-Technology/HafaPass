export const RELEASE_RELOAD_PREFIX = 'hafapass_release_reload:'

export function validRevision(value) {
  return /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/i.test(value || '') ? value.toLowerCase() : null
}

function protectedPath(pathname) {
  let path
  try { path = decodeURIComponent(pathname).toLowerCase().replace(/\/+$/, '') || '/' }
  catch { return { blocked: true } }
  // These flows stay protected even when hidden or after another route change.
  // Include organizer/admin workspaces conservatively: they contain live work.
  if (/^\/(checkout|payments?|orders|tickets|ticket-transfers|dashboard|admin|support|privacy|account|sign-in|sign-up|organization-invitations|platform-invitations|unsubscribe)(\/|$)/.test(path)) return { blocked: true }
  // Event details own button-driven quantities, seat selections and hold requests.
  // Defer throughout that task; leaving for a safe destination permits updates.
  if (/^\/events\/[^/]+(\/|$)/.test(path)) return { blocked: true }
  return { blocked: false, path }
}

// Applying a new release: never reload a page someone is looking at. Wait until
// it is hidden or the person moves on. A rendered not-found page may be a route
// this release adds.
export function canReloadForRelease({ pathname, hidden, navigated, unsaved, notFound }) {
  if (unsaved || protectedPath(pathname).blocked) return false
  return Boolean(notFound || hidden || navigated)
}

// Recovering a broken shell (a missing script after a deploy) on a visible
// public page is still allowed: the page cannot work without it.
export function canRecoverShell({ pathname, hidden, navigated, unsaved, notFound }) {
  if (unsaved) return false
  const { blocked, path } = protectedPath(pathname)
  if (blocked) return false
  const publicRoute = /^\/(?:events|host|discover|collections|about)?$/.test(path) || /^\/policies\/[^/]+$/.test(path)
  return Boolean(publicRoute || notFound || hidden || navigated)
}

// The caller supplies a revision from the shell the controlling worker serves,
// not just release.json: a new deploy can be online before its worker activates.
// It also supplies the latest published revision. A page loaded from the
// network can be newer than the worker's installed shell; only a shell that
// matches the latest release is an update, never an older one.
export function createReleaseReloadPolicy({ currentRevision, storage, reload, getState }) {
  let pending = null
  let pendingNavigationKey
  let reloading = false
  return {
    notice(shellRevision, latestRevision) {
      const candidate = validRevision(shellRevision)
      if (candidate && candidate === validRevision(latestRevision) && candidate !== currentRevision && candidate !== pending) {
        pending = candidate
        pendingNavigationKey = getState().navigationKey
      }
      this.attempt()
    },
    hasPending() { return Boolean(pending) && !reloading },
    // Records the once-per-revision guard. Without a durable guard, defer
    // rather than risk a loop.
    claim() {
      if (!pending || reloading) return false
      try {
        const key = RELEASE_RELOAD_PREFIX + pending
        if (storage.getItem(key)) return false
        storage.setItem(key, '1')
      } catch { return false }
      reloading = true
      return true
    },
    attempt() {
      if (!pending || reloading) return
      const state = getState()
      if (!canReloadForRelease({ ...state, navigated: state.navigationKey !== pendingNavigationKey })) return
      if (this.claim()) reload()
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
