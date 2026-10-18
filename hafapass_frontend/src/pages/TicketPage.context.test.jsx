import 'fake-indexeddb/auto'
import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Link, MemoryRouter, Route, Routes } from 'react-router-dom'
import { AxiosError } from 'axios'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const auth = vi.hoisted(() => ({ authLoaded: true, userLoaded: true, userId: null, sessionId: null, getToken: vi.fn() }))
vi.mock('@clerk/clerk-react', () => ({
  ClerkProvider: ({ children }) => children,
  useAuth: () => ({ isLoaded: auth.authLoaded, userId: auth.userId, sessionId: auth.sessionId, getToken: auth.getToken }),
  useUser: () => ({ isLoaded: auth.userLoaded, isSignedIn: Boolean(auth.userId), user: auth.userId ? { id: auth.userId } : null }),
}))
vi.mock('../components/Navbar', () => ({ default: () => null }))
vi.mock('../components/Footer', () => ({ default: () => null }))
vi.mock('../components/EnvironmentBanner', () => ({ default: () => null }))
vi.mock('../components/QRCode', () => ({ default: ({ value }) => <div role="img" aria-label="Entry QR" data-credential={value} /> }))
vi.mock('../monitoring', () => ({ Sentry: { setUser: vi.fn(), captureException: vi.fn() } }))

const dto = (id, scan = `scan-${id}`) => ({ id, status: 'issued', admission_allowed: true, scan_credential: scan,
  wallet_availability: { apple: true, google: true },
  event: { title: `Ticket event ${id}`, status: 'published', starts_at: '2026-11-20T07:00:00Z', timezone: 'Pacific/Guam', venue_name: 'QA Venue' },
  ticket_type: { name: 'Admission' } })
const response = (config, data) => ({ config, data, status: 200, statusText: 'OK', headers: {} })
const deferred = () => {
  let resolve
  const promise = new Promise(finish => { resolve = finish })
  return { promise, resolve }
}

let Page, Layout, Wrapper, api, access, createUrl, revokeUrl, click
function view(next = '/tickets/display-b?order=2') {
  return <MemoryRouter initialEntries={['/tickets/display-a?order=1']}><Wrapper>
    <Link to={next}>Next ticket</Link>
    <Routes><Route element={<Layout />}><Route path="/tickets/:credential" element={<Page />} /></Route></Routes>
  </Wrapper></MemoryRouter>
}

describe('ticket context boundaries with the real router, wrapper and API interceptor', () => {
  beforeEach(async () => {
    vi.resetModules()
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_ticket_context')
    window.localStorage.clear()
    window.sessionStorage.clear()
    Object.assign(auth, { authLoaded: true, userLoaded: true, userId: null, sessionId: null, getToken: vi.fn().mockResolvedValue(null) })
    ;({ default: api } = await import('../api/client'))
    access = await import('../utils/orderAccess')
    ;({ default: Wrapper } = await import('../components/ClerkProviderWrapper'))
    ;({ default: Layout } = await import('../components/Layout'))
    ;({ default: Page } = await import('./TicketPage'))
    await (await import('../utils/admissionStore')).clearAllAdmissionData()
    createUrl = vi.fn(() => 'blob:ticket-context')
    revokeUrl = vi.fn()
    vi.stubGlobal('URL', class extends URL {
      static createObjectURL = createUrl
      static revokeObjectURL = revokeUrl
    })
    vi.spyOn(window, 'scrollTo').mockImplementation(() => {})
    click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
  })
  afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); vi.unstubAllEnvs() })

  it.each([false, true])('retains the current ticket when an old authorized fetch resolves last (same credential: %s)', async sameCredential => {
    access.saveOrderAccess(1, 'guest-one')
    access.saveOrderAccess(2, 'guest-two')
    const old = deferred()
    let oldConfig
    api.defaults.adapter = vi.fn(config => {
      if (config.headers.get('X-Guest-Order-Token') === 'guest-one') { oldConfig = config; return old.promise }
      return Promise.resolve(response(config, sameCredential ? dto(1, null) : dto(2)))
    })
    render(view(sameCredential ? '/tickets/display-a?order=2' : undefined))
    await waitFor(() => expect(oldConfig).toBeDefined())
    await userEvent.setup().click(screen.getByRole('link', { name: 'Next ticket' }))
    await screen.findByRole('heading', { name: `Ticket event ${sameCredential ? 1 : 2}` })
    await act(async () => old.resolve(response(oldConfig, dto(1))))
    if (sameCredential) expect(screen.queryByRole('img', { name: 'Entry QR' })).not.toBeInTheDocument()
    else expect(screen.getByRole('img', { name: 'Entry QR' })).toHaveAttribute('data-credential', 'scan-2')
    expect(api.defaults.adapter.mock.calls.at(-1)[0].headers.get('X-Guest-Order-Token')).toBe('guest-two')
  })

  it.each([['Download PDF', 'download', 'route'], ['Apple Wallet', 'wallet/apple', 'route'],
    ['Download PDF', 'download', 'account'], ['Apple Wallet', 'wallet/apple', 'account']])(
    'suppresses late %s artifacts after a %s response crosses the %s boundary', async (label, suffix, boundary) => {
      Object.assign(auth, { userId: 'buyer-a', sessionId: 'session-a', getToken: vi.fn().mockResolvedValue('token-a') })
      const old = deferred()
      let oldConfig
      api.defaults.adapter = vi.fn(config => {
        if (config.url.endsWith(`/${suffix}`)) { oldConfig = config; return old.promise }
        return Promise.resolve(response(config, config.headers.get('Authorization') === 'Bearer token-b'
          ? dto(1, null) : dto(config.url.includes('display-b') ? 2 : 1)))
      })
      const { rerender } = render(view())
      await userEvent.setup().click(await screen.findByRole('button', { name: label }))
      await waitFor(() => expect(oldConfig).toBeDefined())
      if (boundary === 'route') {
        await userEvent.setup().click(screen.getByRole('link', { name: 'Next ticket' }))
        await screen.findByRole('heading', { name: 'Ticket event 2' })
      } else {
        Object.assign(auth, { userId: 'buyer-b', sessionId: 'session-b', getToken: vi.fn().mockResolvedValue('token-b') })
        rerender(view())
        await screen.findByText('Entry code unavailable')
      }
      await act(async () => old.resolve(response(oldConfig, new Blob(['synthetic artifact']))))
      expect(createUrl).not.toHaveBeenCalled()
      expect(click).not.toHaveBeenCalled()
      expect(revokeUrl).not.toHaveBeenCalled()
    },
  )

  it('does not let an old blob parse set an error or reset a new ticket download', async () => {
    const parse = deferred()
    const nextDownload = deferred()
    let nextConfig
    const text = vi.fn(() => parse.promise)
    api.defaults.adapter = vi.fn(config => {
      if (config.url === '/tickets/display-a/download') return Promise.reject(new AxiosError('unsupported', undefined, config, null,
        { config, status: 422, data: { text }, headers: {} }))
      if (config.url === '/tickets/display-b/download') { nextConfig = config; return nextDownload.promise }
      return Promise.resolve(response(config, dto(config.url.includes('display-b') ? 2 : 1)))
    })
    render(view())
    await userEvent.setup().click(await screen.findByRole('button', { name: 'Download PDF' }))
    await waitFor(() => expect(text).toHaveBeenCalled())
    await userEvent.setup().click(screen.getByRole('link', { name: 'Next ticket' }))
    await screen.findByRole('heading', { name: 'Ticket event 2' })
    await userEvent.setup().click(screen.getByRole('button', { name: 'Download PDF' }))
    await waitFor(() => expect(nextConfig).toBeDefined())
    await act(async () => parse.resolve(JSON.stringify({ error_code: 'unsupported_pdf_text' })))
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Generating...' })).toBeDisabled()
    await act(async () => nextDownload.resolve(response(nextConfig, new Blob(['current pdf']))))
    expect(createUrl).toHaveBeenCalledTimes(1)
    expect(click).toHaveBeenCalledTimes(1)
    expect(click.mock.instances[0]).toHaveAttribute('download', 'hafapass-ticket-2.pdf')
    expect(revokeUrl).toHaveBeenCalledWith('blob:ticket-context')
  })

  it('blocks the old QR while authoritative auth changes before the user resource settles', async () => {
    Object.assign(auth, { userId: 'buyer-a', sessionId: 'session-a', getToken: vi.fn().mockResolvedValue('token-a') })
    api.defaults.adapter = vi.fn(config => Promise.resolve(response(config, dto(1))))
    const { rerender } = render(view())
    await screen.findByRole('img', { name: 'Entry QR' })
    Object.assign(auth, { authLoaded: false, userLoaded: false, userId: null, sessionId: null })
    rerender(view())
    expect(screen.queryByRole('img', { name: 'Entry QR' })).not.toBeInTheDocument()
  })

  it('fences a ticket token lookup that completes after the Clerk session changes', async () => {
    const token = deferred()
    Object.assign(auth, { userId: 'buyer-a', sessionId: 'session-a', getToken: vi.fn(() => token.promise) })
    api.defaults.adapter = vi.fn(config => Promise.resolve(response(config, dto(1, null))))
    const { rerender } = render(view())
    await waitFor(() => expect(auth.getToken).toHaveBeenCalled())
    expect(api.defaults.adapter).not.toHaveBeenCalled()
    Object.assign(auth, { userId: 'buyer-b', sessionId: 'session-b', getToken: vi.fn().mockResolvedValue('token-b') })
    rerender(view())
    await screen.findByText('Entry code unavailable')
    await act(async () => token.resolve('token-a'))
    expect(api.defaults.adapter).toHaveBeenCalledTimes(1)
    expect(api.defaults.adapter.mock.calls[0][0].headers.get('Authorization')).toBe('Bearer token-b')
  })

  it('keeps current Apple Wallet available and cleans its successful artifact URL', async () => {
    access.saveOrderAccess(1, 'guest-one')
    api.defaults.adapter = vi.fn(config => Promise.resolve(response(config,
      config.url.endsWith('/wallet/apple') ? new Blob(['current wallet']) : dto(1))))
    render(view())
    await userEvent.setup().click(await screen.findByRole('button', { name: 'Apple Wallet' }))
    await waitFor(() => expect(click).toHaveBeenCalledTimes(1))
    expect(click.mock.instances[0]).toHaveAttribute('download', 'hafapass-ticket-1.pkpass')
    expect(api.defaults.adapter.mock.calls.at(-1)[0].headers.get('X-Guest-Order-Token')).toBe('guest-one')
    expect(revokeUrl).toHaveBeenCalledWith('blob:ticket-context')
    expect(screen.getByRole('button', { name: 'Apple Wallet' })).toBeEnabled()
  })
})
