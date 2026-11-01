import { useContext, useEffect, useLayoutEffect, useRef } from 'react'
import { useLocation } from 'react-router-dom'
import { registerSW } from 'virtual:pwa-register'
import { DraftProtectionContext } from '../hooks/useDraftProtection'
import { canRecoverShell, canReloadForRelease, createReleaseReloadPolicy, trackUnsavedInputs, validRevision } from '../utils/releaseUpdate'

export default function ReleaseUpdateCoordinator() {
  const location = useLocation()
  const drafts = useContext(DraftProtectionContext)
  const route = useRef(location)
  const policy = useRef(null)
  useLayoutEffect(() => {
    route.current = location
  }, [location])
  useEffect(() => { policy.current?.attempt() }, [location])

  useEffect(() => {
    // Development has no worker; production and preview share this.
    const currentRevision = validRevision(import.meta.env.VITE_SENTRY_RELEASE)
    if (!import.meta.env.PROD) return undefined
    if (!currentRevision) {
      // Source archives still need the offline shell. Without revision identity,
      // register normally but suppress unconditional update reloads.
      registerSW({ immediate: true, onNeedReload: () => {} })
      return undefined
    }
    let disposed = false
    let checking = false
    let registration
    const inputs = trackUnsavedInputs(document)
    const getState = () => ({
      pathname: route.current.pathname,
      hidden: document.visibilityState === 'hidden',
      // Hash-only changes keep the same task mounted; wait for a real departure.
      navigationKey: JSON.stringify([route.current.pathname, route.current.search]),
      unsaved: Boolean(drafts?.hasUnsavedDraft(route.current.pathname)) || inputs.hasUnsaved(),
      notFound: Boolean(document.querySelector('[data-release-safe="not-found"]')),
    })
    const reloadPolicy = createReleaseReloadPolicy({
      currentRevision,
      storage: { getItem: key => window.sessionStorage.getItem(key), setItem: (key, value) => window.sessionStorage.setItem(key, value) },
      reload: () => window.location.reload(),
      getState,
    })
    policy.current = reloadPolicy
    // The pre-bundle missing-chunk guard uses the same task/draft protection
    // once the app is mounted. Early boot failures still use its own throttle.
    window.hafapassCanRecoverShell = () => canRecoverShell(getState())

    async function fetchResource(url, read) {
      const controller = new AbortController()
      const timeout = window.setTimeout(() => controller.abort(), 5000)
      try {
        const response = await fetch(url, { cache: 'no-store', signal: controller.signal })
        return { ok: response.ok, body: response.ok ? await read(response) : null }
      }
      finally { window.clearTimeout(timeout) }
    }
    async function readRelease() {
      // release.json is deliberately outside the precache/runtime caches.
      const { ok, body } = await fetchResource('/release.json', response => response.json())
      return ok ? validRevision(body.revision) : null
    }
    async function readShell(latest) {
      try {
        // This request intentionally goes through the current worker's precache.
        const [shell, latestRevision] = await Promise.all([
          fetchResource('/index.html', response => response.text()),
          latest === undefined ? readRelease() : latest,
        ])
        if (!shell.ok || disposed) return
        const html = new DOMParser().parseFromString(shell.body, 'text/html')
        if (!disposed) reloadPolicy.notice(html.querySelector('meta[name="hafapass-revision"]')?.content, latestRevision)
      } catch { /* Offline without a prepared shell: retry on reconnect. */ }
    }
    async function check() {
      if (checking || disposed) return
      checking = true
      let latest
      try {
        latest = await readRelease()
        if (!disposed && latest && latest !== currentRevision) {
          await registration?.update()
        }
      } catch { /* Never disturb an offline event. */ }
      finally { await readShell(latest ?? null); checking = false }
    }
    registerSW({
      immediate: true,
      // Suppress the virtual module's unconditional autoUpdate reload.
      onNeedReload: () => readShell(),
      onRegisteredSW: (_url, value) => { registration = value; if (!disposed) void check() },
    })
    const onVisibility = () => { reloadPolicy.attempt(); if (!document.hidden) void check() }
    const onOnline = () => { void check() }
    // Listen directly too: updates initiated by another tab can claim this one.
    const onControllerChange = () => { void readShell() }
    navigator.serviceWorker?.addEventListener('controllerchange', onControllerChange)
    document.addEventListener('visibilitychange', onVisibility)
    // With an update waiting, the next ordinary link to a safe page becomes a
    // single full page load instead of a route change followed by a reload.
    const onClick = event => {
      if (!reloadPolicy.hasPending() || event.defaultPrevented || event.button !== 0
        || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
      const anchor = event.target.closest?.('a[href]')
      if (!anchor || (anchor.target && anchor.target !== '_self') || anchor.hasAttribute('download')) return
      const url = new URL(anchor.href, window.location.href)
      if (url.origin !== window.location.origin) return
      if (url.pathname === window.location.pathname && url.search === window.location.search) return
      if (getState().unsaved) return
      if (!canReloadForRelease({ pathname: url.pathname, navigated: true })) return
      if (!reloadPolicy.claim()) return
      event.preventDefault()
      event.stopPropagation()
      window.location.assign(url.href)
    }
    document.addEventListener('click', onClick, true)
    window.addEventListener('online', onOnline)
    const timer = window.setInterval(check, 60_000)
    // Lazy not-found rendering and form removal can establish a safe moment.
    const observer = new MutationObserver(() => reloadPolicy.attempt())
    observer.observe(document.body, { childList: true, subtree: true })
    void check()
    return () => {
      disposed = true
      policy.current = null
      delete window.hafapassCanRecoverShell
      inputs.dispose()
      observer.disconnect()
      window.clearInterval(timer)
      navigator.serviceWorker?.removeEventListener('controllerchange', onControllerChange)
      document.removeEventListener('visibilitychange', onVisibility)
      document.removeEventListener('click', onClick, true)
      window.removeEventListener('online', onOnline)
    }
  }, [drafts])
  return null
}
