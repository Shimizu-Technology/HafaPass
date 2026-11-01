import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { getApiAuthContext, monitoringPath, setAuthTokenGetter, subscribeApiAuthContext } from './client'
import { configureEnabledLanguages, setActiveLanguage } from '../utils/locale'
import { AxiosError } from 'axios'
import { apiErrorMessage, isTimeoutError } from './errors'

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

  it('rejects a bound organization changed before the request interceptor starts', async () => {
    const getToken = vi.fn().mockResolvedValue('synthetic-owner-token')
    clearBinding = setAuthTokenGetter(getToken, { userId: 'owner-of-both', sessionId: 'owner-session', ready: true })
    window.localStorage.setItem('hafapass_organization_id', '2')
    const adapter = vi.fn(config => Promise.resolve({ config, status: 200, statusText: 'OK', headers: {}, data: {} }))
    apiClient.defaults.adapter = adapter
    await expect(apiClient.put('/organizer_profile', { business_name: 'Alpha' }, { organizationId: '1', authContext: getApiAuthContext() }))
      .rejects.toMatchObject({ code: 'ERR_CANCELED' })
    expect(adapter).not.toHaveBeenCalled()
    expect(getToken).not.toHaveBeenCalled()
  })

  it.each(['1', null])('uses the captured organization %s instead of a stale supplied header', async organizationId => {
    clearBinding = setAuthTokenGetter(() => Promise.resolve('owner-token'), {
      userId: 'owner', sessionId: 'session', ready: true,
    })
    if (organizationId) window.localStorage.setItem('hafapass_organization_id', organizationId)
    const adapter = vi.fn(config => Promise.resolve({ config, status: 200, statusText: 'OK', headers: {}, data: {} }))
    apiClient.defaults.adapter = adapter
    await apiClient.put('/organizer_profile', { business_name: 'Captured profile' }, {
      organizationId, authContext: getApiAuthContext(), headers: { 'X-Organization-Id': 'stale-organization' },
    })
    const headers = adapter.mock.calls[0][0].headers
    if (organizationId) expect(headers.get('X-Organization-Id')).toBe(organizationId)
    else expect(headers.has('X-Organization-Id')).toBe(false)
  })

  it.each([false, true])('rejects an organization change during token acquisition (auth-bound: %s)', async authBound => {
    let finishToken, requestedToken
    const requested = new Promise(resolve => { requestedToken = resolve })
    window.localStorage.setItem('hafapass_organization_id', '1')
    clearBinding = setAuthTokenGetter(() => {
      requestedToken()
      return new Promise(resolve => { finishToken = resolve })
    }, { userId: 'owner', sessionId: 'session', ready: true })
    const adapter = vi.fn(config => Promise.resolve({ config, status: 200, statusText: 'OK', headers: {}, data: {} }))
    apiClient.defaults.adapter = adapter
    const request = apiClient.put('/organizer_profile', { business_name: 'Alpha' }, {
      organizationId: '1', ...(authBound ? { authContext: getApiAuthContext() } : {}),
    })
    const refused = expect(request).rejects.toMatchObject({ code: 'ERR_CANCELED' })
    await requested
    window.localStorage.setItem('hafapass_organization_id', '2')
    finishToken('original-token')
    await refused
    expect(adapter).not.toHaveBeenCalled()
  })
})

describe('request language', () => {
  const originalAdapter = apiClient.defaults.adapter
  beforeEach(() => configureEnabledLanguages('ko,ja,zh-Hant,zh,tl'))
  afterEach(() => {
    configureEnabledLanguages('en')
    apiClient.defaults.adapter = originalAdapter
    setActiveLanguage('en')
  })

  it('tells the API which language the app is showing unless a caller sets one', async () => {
    const adapter = vi.fn(config => Promise.resolve({ data: {}, status: 200, statusText: 'OK', headers: {}, config }))
    apiClient.defaults.adapter = adapter

    await apiClient.get('/events')
    expect(adapter.mock.calls[0][0].headers['Accept-Language']).toBe('en')

    setActiveLanguage('zh-Hant')
    await apiClient.get('/events')
    expect(adapter.mock.calls[1][0].headers['Accept-Language']).toBe('zh-Hant')

    await apiClient.get('/events', { headers: { 'Accept-Language': 'ja' } })
    expect(adapter.mock.calls[2][0].headers['Accept-Language']).toBe('ja')
  })
})

describe('request timeouts', () => {
  const originalAdapter = apiClient.defaults.adapter
  afterEach(() => { apiClient.defaults.adapter = originalAdapter })
  const sentTimeout = async (method, url, config = {}) => {
    let sent
    apiClient.defaults.adapter = async request => { sent = request; return { data: {}, status: 200, statusText: 'OK', headers: {}, config: request } }
    await apiClient.request({ method, url, ...config })
    return sent.timeout
  }

  it('ends stalled requests after 20 s and gives downloads and unkeyed order writes longer', async () => {
    expect(await sentTimeout('get', '/events')).toBe(20_000)
    expect(await sentTimeout('post', '/orders')).toBe(20_000)
    expect(await sentTimeout('get', '/organizer/events/4/attendees.csv', { responseType: 'blob' })).toBe(60_000)
    expect(await sentTimeout('post', '/orders/12/payment_resume')).toBe(45_000)
    expect(await sentTimeout('post', '/orders/12/tickets/3/transfer')).toBe(45_000)
    expect(await sentTimeout('post', '/orders/12/tickets/3/cancel', { headers: { 'Idempotency-Key': 'k' } })).toBe(20_000)
    expect(await sentTimeout('get', '/orders/12')).toBe(20_000)
    expect(await sentTimeout('get', '/me', { timeout: 8000 })).toBe(8000)
  })

  it('marks a timeout with a friendly slow-connection message but leaves other aborts alone', async () => {
    apiClient.defaults.adapter = async request => { throw new AxiosError('timeout of 20000ms exceeded', 'ECONNABORTED', request) }
    const timedOut = await apiClient.get('/events').catch(error => error)
    expect(isTimeoutError(timedOut)).toBe(true)
    expect(timedOut.message).toMatch(/connection is slow/i)
    expect(apiErrorMessage(timedOut, 'Fallback')).toBe(timedOut.message)

    apiClient.defaults.adapter = async request => { throw new AxiosError('Request aborted', 'ECONNABORTED', request) }
    const aborted = await apiClient.get('/events').catch(error => error)
    expect(isTimeoutError(aborted)).toBe(false)
    expect(apiErrorMessage(aborted, 'Fallback')).toBe('Fallback')
  })
})
