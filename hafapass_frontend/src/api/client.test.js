import { afterEach, describe, expect, it, vi } from 'vitest'
import apiClient, { getApiAuthContext, monitoringPath, setAuthTokenGetter, subscribeApiAuthContext } from './client'

describe('monitoringPath', () => {
  it('removes query data and opaque identifiers from monitored paths', () => {
    expect(monitoringPath('/orders/123/confirmation?email=guest@example.com'))
      .toBe('/orders/:id/confirmation')
    expect(monitoringPath('/tickets/4c2aa90e-1f34-4e87-847e-f705a0c7c782'))
      .toBe('/tickets/:id')
  })
})

describe('session-bound API requests', () => {
  const originalAdapter = apiClient.defaults.adapter
  let clearBinding
  afterEach(() => {
    clearBinding?.()
    apiClient.defaults.adapter = originalAdapter
    window.localStorage.clear()
  })

  it.each([null, new Error('Clerk token retrieval failed')])('never sends an anonymous account lookup when token retrieval returns %s', async token => {
    clearBinding = setAuthTokenGetter(() => token instanceof Error ? Promise.reject(token) : Promise.resolve(token), {
      userId: 'buyer-a', sessionId: 'session-a', ready: true,
    })
    const adapter = vi.fn()
    apiClient.defaults.adapter = adapter
    await expect(apiClient.get('/me', { authContext: getApiAuthContext() })).rejects.toThrow()
    expect(adapter).not.toHaveBeenCalled()
  })

  it('cancels a pending token from an old session before the request reaches transport', async () => {
    let finishToken
    let tokenRequested
    const requested = new Promise(resolve => { tokenRequested = resolve })
    clearBinding = setAuthTokenGetter(() => {
      tokenRequested()
      return new Promise(resolve => { finishToken = resolve })
    }, { userId: 'buyer-a', sessionId: 'session-a', ready: true })
    const adapter = vi.fn()
    apiClient.defaults.adapter = adapter
    const request = apiClient.get('/me', { authContext: getApiAuthContext() })
    const refused = expect(request).rejects.toMatchObject({ code: 'ERR_CANCELED' })
    await requested
    clearBinding = setAuthTokenGetter(() => Promise.resolve('token-b'), { userId: 'buyer-b', sessionId: 'session-b', ready: true })
    finishToken('token-a')
    await refused
    expect(adapter).not.toHaveBeenCalled()
  })

  it('notifies readiness changes and prevents an older cleanup from erasing a newer binding', () => {
    const listener = vi.fn()
    const unsubscribe = subscribeApiAuthContext(listener)
    const clearOld = setAuthTokenGetter(() => Promise.resolve('token-a'), { userId: 'buyer-a', sessionId: 'session-a', ready: true })
    const old = getApiAuthContext()
    clearBinding = setAuthTokenGetter(() => Promise.resolve('token-b'), { userId: 'buyer-b', sessionId: 'session-b', ready: true })
    const current = getApiAuthContext()
    expect(current.generation).toBeGreaterThan(old.generation)
    expect(Object.keys(current).sort()).toEqual(['generation', 'ready', 'sessionId', 'userId'])
    clearOld()
    expect(getApiAuthContext()).toBe(current)
    expect(listener).toHaveBeenCalledTimes(2)
    unsubscribe()
    clearBinding()
    expect(getApiAuthContext()).toBeNull()
    expect(listener).toHaveBeenCalledTimes(2)
  })

  it('preserves anonymous public API requests without account-bound options', async () => {
    clearBinding = setAuthTokenGetter(null)
    const adapter = vi.fn(config => Promise.resolve({ config, status: 200, statusText: 'OK', headers: {}, data: { events: [] } }))
    apiClient.defaults.adapter = adapter
    expect((await apiClient.get('/events')).data.events).toEqual([])
    expect(adapter.mock.calls[0][0].headers.has('Authorization')).toBe(false)
  })
})
