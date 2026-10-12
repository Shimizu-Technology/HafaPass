import { useCallback, useLayoutEffect, useRef, useSyncExternalStore } from 'react'
import { useLocation } from 'react-router-dom'
import apiClient, { getApiAuthContext, subscribeApiAuthContext } from '../api/client'

// Administrator permissions can change without replacing the Clerk session.
// Keep this authority separate from support and organizer access.
let adminAuthority = { authContext: getApiAuthContext(), generation: 0, denied: false }
const authoritySubscribers = new Set()
export const getAdminAuthority = () => adminAuthority
export function subscribeAdminAuthority(callback) {
  authoritySubscribers.add(callback)
  return () => authoritySubscribers.delete(callback)
}
const replaceAuthority = update => {
  adminAuthority = { ...adminAuthority, ...update, generation: adminAuthority.generation + 1 }
  authoritySubscribers.forEach(callback => callback())
}
subscribeApiAuthContext(() => {
  if (getApiAuthContext() !== adminAuthority.authContext) replaceAuthority({ authContext: getApiAuthContext(), denied: false })
})
export function withdrawAdminAuthority(error, authContext, generation) {
  const denied = error.response?.status === 401
    || (error.response?.status === 403 && error.response?.data?.error === 'Admin access required')
  if (!denied || getApiAuthContext() !== authContext || adminAuthority.authContext !== authContext
    || adminAuthority.generation !== generation) return false
  replaceAuthority({ denied: true })
  return true
}
export async function recheckAdminAuthority(authContext, generation) {
  const current = () => getApiAuthContext() === authContext && adminAuthority.authContext === authContext
    && adminAuthority.generation === generation && adminAuthority.denied
  if (!current()) return false
  const response = await apiClient.get('/me', authContext ? { authContext } : {})
  if (!current()) return false
  if (response.data.role !== 'admin' || (authContext?.userId && response.data.clerk_id !== authContext.userId)) {
    throw new Error('Administrator access has not been restored. Sign in with an authorized account or contact another administrator.')
  }
  replaceAuthority({ denied: false })
  return true
}

export function usePlatformIdentity(requiredRole) {
  const authContext = useSyncExternalStore(subscribeApiAuthContext, getApiAuthContext)
  const authority = useSyncExternalStore(subscribeAdminAuthority, getAdminAuthority)
  return {
    authContext, requiredRole, authorityGeneration: requiredRole === 'admin' ? authority.generation : undefined,
    authorityDenied: requiredRole === 'admin' && authority.denied && authority.authContext === authContext,
    accountKey: JSON.stringify([authContext?.generation, authContext?.userId, authContext?.sessionId, requiredRole === 'admin' ? authority.generation : null]),
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
export function usePlatformRequests({ authContext, requiredRole, authorityGeneration }, resourcePath) {
  const { pathname } = useLocation()
  const routeActive = useRef(true)
  if (pathname.replace(/\/$/, '') !== resourcePath) routeActive.current = false
  const mounted = useRef(false)
  const requests = useRef(new Set())
  const current = useCallback(() => mounted.current && routeActive.current && getApiAuthContext() === authContext
    && (requiredRole !== 'admin' || (!adminAuthority.denied && adminAuthority.generation === authorityGeneration)), [authContext, requiredRole, authorityGeneration])
  useLayoutEffect(() => {
    mounted.current = true
    const owned = requests.current
    const unsubscribe = subscribeAdminAuthority(() => {
      if (requiredRole === 'admin' && !current()) owned.forEach(controller => controller.abort())
    })
    return () => { unsubscribe(); mounted.current = false; owned.forEach(controller => controller.abort()); owned.clear() }
  }, [current, requiredRole])
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
      handleError: error => current() && requiredRole === 'admin' && withdrawAdminAuthority(error, authContext, authorityGeneration),
      abort: () => controller.abort(),
      release: () => requests.current.delete(controller),
    }
  }, [authContext, current, requiredRole, authorityGeneration])
  return { current, beginRequest }
}
