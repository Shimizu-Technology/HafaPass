import { useCallback, useLayoutEffect, useRef } from 'react'
import { usePlatformIdentity, getAdminAuthority, subscribeAdminAuthority, withdrawAdminAuthority } from './usePlatformContext'
import apiClient, { getApiAuthContext, subscribeApiAuthContext } from '../api/client'

export function useCapturedDialogIdentity() {
  const identity = usePlatformIdentity('admin')
  return { ...identity, key: identity.accountKey }
}

const contextError = () => Object.assign(new Error('Dialog authorization changed'), { name: 'DialogContextChanged' })

// Capture only on an explicit open. Every operation keeps that exact open-cycle
// and auth object; it cannot borrow a later account's token or dialog lifetime.
export default function useCapturedPlatformDialog(open) {
  const mounted = useRef(false)
  const captured = useRef(null)
  const generation = useRef(0)
  const withdraw = useCallback(() => {
    const scope = captured.current
    if (!scope) return
    scope.active = false
    scope.requests.forEach(controller => controller.abort())
    scope.requests.clear()
  }, [])
  useLayoutEffect(() => {
    mounted.current = true
    // Withdraw synchronously with credential replacement, before React's next
    // commit or Axios's queued interceptor. This also fences dev/no-auth scopes.
    const unsubscribe = subscribeApiAuthContext(() => {
      if (captured.current && getApiAuthContext() !== captured.current.authContext) withdraw()
    })
    const unsubscribeAuthority = subscribeAdminAuthority(() => {
      if (captured.current && (getAdminAuthority().denied || getAdminAuthority().generation !== captured.current.authorityGeneration)) withdraw()
    })
    return () => { unsubscribeAuthority(); unsubscribe(); mounted.current = false; withdraw() }
  }, [withdraw])
  useLayoutEffect(() => { if (!open) withdraw() }, [open, withdraw])

  const capture = () => {
    if (!mounted.current || captured.current?.busy) return false
    const authContext = getApiAuthContext()
    if (getAdminAuthority().denied || (authContext ? !authContext.ready : Boolean(import.meta.env.VITE_CLERK_PUBLISHABLE_KEY))) return false
    withdraw()
    captured.current = { authContext, authorityGeneration: getAdminAuthority().generation, generation: ++generation.current, active: true, busy: false, read: 0, requests: new Set() }
    return true
  }
  const begin = (kind = 'read') => {
    const scope = captured.current
    if (!scope || !mounted.current || !scope.active || getApiAuthContext() !== scope.authContext || (kind === 'mutation' && scope.busy)) return null
    if (kind === 'mutation') scope.busy = true
    const read = kind === 'read' ? ++scope.read : null
    const current = () => mounted.current && scope.active && captured.current === scope && getApiAuthContext() === scope.authContext && (read === null || read === scope.read)
    const invoke = async (method, url, body, config) => {
      if (!current()) throw contextError()
      const controller = new AbortController()
      scope.requests.add(controller)
      const bound = { ...config, signal: controller.signal, ...(scope.authContext ? { authContext: scope.authContext } : {}) }
      try {
        const response = await (['get', 'delete'].includes(method) ? apiClient[method](url, bound) : apiClient[method](url, body, bound))
        if (!current() || controller.signal.aborted) throw contextError()
        return response
      } catch (error) {
        if (current()) withdrawAdminAuthority(error, scope.authContext, scope.authorityGeneration)
        throw error
      } finally { scope.requests.delete(controller) }
    }
    return { current, finish: () => { if (kind === 'mutation') scope.busy = false }, api: {
      get: (url, config) => invoke('get', url, undefined, config),
      delete: (url, config) => invoke('delete', url, undefined, config),
      post: (url, body, config) => invoke('post', url, body, config),
      patch: (url, body, config) => invoke('patch', url, body, config),
      put: (url, body, config) => invoke('put', url, body, config),
    } }
  }
  const canClose = useCallback(() => !captured.current?.busy, [])
  return { capture, begin, canClose }
}
