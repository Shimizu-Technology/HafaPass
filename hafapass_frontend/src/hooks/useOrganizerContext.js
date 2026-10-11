import { useCallback, useLayoutEffect, useRef, useSyncExternalStore } from 'react'
import { getApiAuthContext, subscribeApiAuthContext } from '../api/client'
import { currentScannerOwner } from '../utils/admissionStore'
import { useLocation } from 'react-router-dom'

const selectionSnapshot = () => JSON.stringify([window.localStorage.getItem('hafapass_organization_id'), currentScannerOwner()])
const subscribeSelection = callback => {
  const changed = event => {
    if (['hafapass_organization_id', 'hafapass_scanner_user_id', null].includes(event.key)) callback()
  }
  window.addEventListener('storage', changed)
  return () => window.removeEventListener('storage', changed)
}

export function useOrganizerIdentity() {
  const authContext = useSyncExternalStore(subscribeApiAuthContext, getApiAuthContext)
  const selection = useSyncExternalStore(subscribeSelection, selectionSnapshot)
  const [organizationId, owner] = JSON.parse(selection)
  const accountKey = JSON.stringify([authContext?.generation, authContext?.userId, authContext?.sessionId, owner])
  const ready = authContext ? authContext.ready && authContext.userId === owner : !import.meta.env.VITE_CLERK_PUBLISHABLE_KEY
  return { authContext, organizationId, owner, accountKey, ready }
}

export function useOrganizerPageVisit(resourcePath) {
  const location = useLocation()
  const path = location.pathname.replace(/\/$/, '')
  const visit = useRef({ path, generation: 0 })
  if (visit.current.path !== path) visit.current = { path, generation: visit.current.generation + 1 }
  return { active: path === resourcePath, generation: visit.current.generation }
}

export function useOrganizerRequests({ authContext, organizationId, owner }, resourcePath) {
  const location = useLocation()
  const routeActive = useRef(true)
  // An exiting animated outlet can remain mounted after navigation. Withdraw
  // its authority permanently, even if the user returns to the same path.
  if (resourcePath && location.pathname.replace(/\/$/, '') !== resourcePath) routeActive.current = false
  const mounted = useRef(false)
  const requests = useRef(new Set())
  const current = useCallback(() => mounted.current && routeActive.current && getApiAuthContext() === authContext
    && currentScannerOwner() === owner && window.localStorage.getItem('hafapass_organization_id') === organizationId,
  [authContext, organizationId, owner])

  useLayoutEffect(() => {
    mounted.current = true
    const owned = requests.current
    return () => { mounted.current = false; owned.forEach(controller => controller.abort()); owned.clear() }
  }, [current])

  useLayoutEffect(() => {
    if (!routeActive.current) requests.current.forEach(controller => controller.abort())
  }, [location.pathname])

  const beginRequest = useCallback(() => {
    if (!current()) return null
    const controller = new AbortController()
    requests.current.add(controller)
    return {
      controller,
      config: { signal: controller.signal, organizationId, ...(authContext ? { authContext } : {}) },
      current: () => current() && !controller.signal.aborted,
      release: () => requests.current.delete(controller),
    }
  }, [authContext, organizationId, current])
  return { current, beginRequest }
}
