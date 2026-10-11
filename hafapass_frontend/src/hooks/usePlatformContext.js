import { useCallback, useLayoutEffect, useRef, useSyncExternalStore } from 'react'
import { useLocation } from 'react-router-dom'
import { getApiAuthContext, subscribeApiAuthContext } from '../api/client'

export function usePlatformIdentity() {
  const authContext = useSyncExternalStore(subscribeApiAuthContext, getApiAuthContext)
  return {
    authContext,
    accountKey: JSON.stringify([authContext?.generation, authContext?.userId, authContext?.sessionId]),
    ready: authContext ? authContext.ready : !import.meta.env.VITE_CLERK_PUBLISHABLE_KEY,
  }
}

export function usePlatformVisit(resourcePath) {
  const { pathname } = useLocation()
  const visit = useRef({ pathname, generation: 0 })
  if (visit.current.pathname !== pathname) visit.current = { pathname, generation: visit.current.generation + 1 }
  return { ...visit.current, active: pathname.replace(/\/$/, '') === resourcePath }
}

// Platform roles have account/session authority, independently of the selected
// organizer. Pin that authority while Axios waits for a token and fence callbacks.
export function usePlatformRequests({ authContext }, resourcePath) {
  const { pathname } = useLocation()
  const routeActive = useRef(true)
  if (pathname.replace(/\/$/, '') !== resourcePath) routeActive.current = false
  const mounted = useRef(false)
  const requests = useRef(new Set())
  const current = useCallback(() => mounted.current && routeActive.current && getApiAuthContext() === authContext, [authContext])
  useLayoutEffect(() => {
    mounted.current = true
    const owned = requests.current
    return () => { mounted.current = false; owned.forEach(controller => controller.abort()); owned.clear() }
  }, [current])
  useLayoutEffect(() => {
    if (!routeActive.current) requests.current.forEach(controller => controller.abort())
  }, [pathname])
  const beginRequest = useCallback(() => {
    if (!current()) return null
    const controller = new AbortController()
    requests.current.add(controller)
    return {
      config: { signal: controller.signal, ...(authContext ? { authContext } : {}) },
      current: () => current() && !controller.signal.aborted,
      abort: () => controller.abort(),
      release: () => requests.current.delete(controller),
    }
  }, [authContext, current])
  return { current, beginRequest }
}
