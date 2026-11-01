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

// Applying a new release: never reload a page someone is reading. Wait until it
// is hidden or the person moves on. A public page that has only just loaded
// (a stale cached shell served on this very load) may update straight away,
// before anyone has started reading. A rendered not-found page may be a route
// this release adds.
export function canReloadForRelease({ pathname, hidden, navigated, unsaved, notFound, fresh }) {
  if (unsaved) return false
  const { blocked, path } = protectedPath(pathname)
  if (blocked) return false
  return Boolean(notFound || hidden || navigated || (fresh && isPublicRoute(path)))
}

// Recovering a broken shell (a missing script after a deploy) on a visible
// public page is still allowed: the page cannot work without it.
export function canRecoverShell({ pathname, hidden, navigated, unsaved, notFound }) {
  if (unsaved) return false
  const { blocked, path } = protectedPath(pathname)
  if (blocked) return false
  return Boolean(isPublicRoute(path) || notFound || hidden || navigated)
}

function isPublicRoute(path) {
  return /^\/(?:events|host|discover|collections|about)?$/.test(path) || /^\/policies\/[^/]+$/.test(path)
}

// The caller supplies a revision from the shell the controlling worker serves,
// not just release.json: a new deploy can be online before its worker activates.
// It also supplies the latest published revision. A page loaded from the
// network can be newer than the worker's installed shell; only a shell that
// matches the latest release is an update, never an older one.
// An update applies on the next route change or while the page is hidden.
export function createReleaseReloadPolicy({ currentRevision, storage, reload, getState }) {
  let pending = null
  let pendingNavigationKey
  let reloading = false
  return {
    notice(shellRevision, latestRevision, { activated = false } = {}) {
      const candidate = validRevision(shellRevision)
      const latest = validRevision(latestRevision)
      // A newer published release supersedes an update still waiting to apply.
      if (latest && pending && pending !== latest) pending = null
      // Without a readable latest release, only a worker that just activated
      // (whose shell is new by definition) can establish an update.
      const current = latest ? candidate === latest : activated
      if (candidate && current && candidate !== currentRevision && candidate !== pending) {
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
