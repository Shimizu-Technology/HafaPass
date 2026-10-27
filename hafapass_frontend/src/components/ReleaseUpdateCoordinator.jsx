import { useContext, useEffect, useLayoutEffect, useRef } from 'react'
import { useLocation } from 'react-router-dom'
import { registerSW } from 'virtual:pwa-register'
import { DraftProtectionContext } from '../hooks/useDraftProtection'
import { canReloadForRelease, createReleaseReloadPolicy, trackUnsavedInputs, validRevision } from '../utils/releaseUpdate'

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
    // Development has no revision or worker; production and preview share this.
    const currentRevision = validRevision(import.meta.env.VITE_SENTRY_RELEASE)
    if (!import.meta.env.PROD || !currentRevision) return undefined
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
    window.hafapassCanRecoverShell = () => canReloadForRelease(getState())

    async function fetchResource(url) {
      const controller = new AbortController()
      const timeout = window.setTimeout(() => controller.abort(), 5000)
      try { return await fetch(url, { cache: 'no-store', signal: controller.signal }) }
      finally { window.clearTimeout(timeout) }
    }
    async function readShell() {
      try {
        // This request intentionally goes through the current worker's precache.
        const response = await fetchResource('/index.html')
        if (!response.ok || disposed) return
        const html = new DOMParser().parseFromString(await response.text(), 'text/html')
        if (!disposed) reloadPolicy.notice(html.querySelector('meta[name="hafapass-revision"]')?.content)
      } catch { /* Offline without a prepared shell: retry on reconnect. */ }
    }
    async function check() {
      if (checking || disposed) return
      checking = true
      try {
        // release.json is deliberately outside the precache/runtime caches.
        const response = await fetchResource('/release.json')
        const revision = response.ok ? validRevision((await response.json()).revision) : null
        if (revision && revision !== currentRevision) {
          await registration?.update()
        }
      } catch { /* Never disturb an offline event. */ }
      finally { await readShell(); checking = false }
    }
    registerSW({
      immediate: true,
      // Suppress the virtual module's unconditional autoUpdate reload.
      onNeedReload: readShell,
      onRegisteredSW: (_url, value) => { registration = value; if (!disposed) void check() },
    })
    const onVisibility = () => { reloadPolicy.attempt(); if (!document.hidden) void check() }
    const onOnline = () => { void check() }
    // Listen directly too: updates initiated by another tab can claim this one.
    navigator.serviceWorker?.addEventListener('controllerchange', readShell)
    document.addEventListener('visibilitychange', onVisibility)
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
      navigator.serviceWorker?.removeEventListener('controllerchange', readShell)
      document.removeEventListener('visibilitychange', onVisibility)
      window.removeEventListener('online', onOnline)
    }
  }, [drafts])
  return null
}
