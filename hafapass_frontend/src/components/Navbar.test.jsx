import 'fake-indexeddb/auto'
import { act, render, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import userEvent from '@testing-library/user-event'
import { AxiosError } from 'axios'

const auth = vi.hoisted(() => ({ isLoaded: true, isSignedIn: true, userId: 'buyer-a', sessionId: 'session-a', user: { id: 'buyer-a' }, getToken: vi.fn() }))
vi.mock('@clerk/clerk-react', () => ({
  ClerkProvider: ({ children }) => children,
  useAuth: () => auth,
  useUser: () => auth,
  SignedIn: ({ children }) => auth.isSignedIn ? children : null,
  UserButton: () => <button>Account options</button>,
}))
vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: key => key === 'nav.admin' ? 'Admin' : key }) }))
vi.mock('./LanguageSwitcher', () => ({ default: () => null }))
vi.mock('../monitoring', () => ({ Sentry: { setUser: vi.fn(), captureException: vi.fn() } }))

let Navbar, Wrapper, apiClient, setAuthTokenGetter
const response = (config, userId = 'buyer-a', role = 'admin') => ({ config, data: { clerk_id: userId, role }, status: 200, statusText: 'OK', headers: {} })
const rejection = (config, status) => new AxiosError('Account lookup unavailable', undefined, config, null, { config, status, data: {} })
const bind = () => setAuthTokenGetter(auth.getToken, { userId: auth.userId, sessionId: auth.sessionId, ready: auth.isLoaded && auth.isSignedIn })
const view = (wrapped = false, path = '/') => <MemoryRouter initialEntries={[path]}>{wrapped ? <Wrapper><Navbar /></Wrapper> : <Navbar />}</MemoryRouter>

describe('account-bound navbar with the real API authentication interceptor', () => {
  beforeEach(async () => {
    vi.resetModules()
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_nav_fixture')
    window.localStorage.clear()
    Object.assign(auth, { isLoaded: true, isSignedIn: true, userId: 'buyer-a', sessionId: 'session-a', user: { id: 'buyer-a' }, getToken: vi.fn().mockResolvedValue('token-a') })
    ;({ default: apiClient, setAuthTokenGetter } = await import('../api/client'))
    ;({ default: Wrapper } = await import('./ClerkProviderWrapper'))
    ;({ default: Navbar } = await import('./Navbar'))
    apiClient.defaults.adapter = vi.fn(config => Promise.resolve(response(config)))
  })
  afterEach(() => vi.unstubAllEnvs())

  it('waits for real bootstrap and asynchronous token retrieval before loading desktop and mobile admin navigation', async () => {
    let finishToken
    auth.getToken.mockReturnValue(new Promise(resolve => { finishToken = resolve }))
    Object.assign(auth, { isLoaded: false, isSignedIn: false, userId: null, sessionId: null, user: null })
    const { rerender } = render(view(true))
    expect(apiClient.defaults.adapter).not.toHaveBeenCalled()
    Object.assign(auth, { isLoaded: true, isSignedIn: true, userId: 'buyer-a', sessionId: 'session-a', user: { id: 'buyer-a' } })
    rerender(view(true))
    await waitFor(() => expect(auth.getToken).toHaveBeenCalled())
    expect(apiClient.defaults.adapter).not.toHaveBeenCalled()
    await act(async () => finishToken('token-a'))
    expect(await screen.findByRole('link', { name: 'Admin' })).toHaveAttribute('href', '/admin')
    expect(apiClient.defaults.adapter.mock.calls[0][0].headers.get('Authorization')).toBe('Bearer token-a')
    await userEvent.setup().click(screen.getByRole('button', { name: 'Toggle menu' }))
    expect(screen.getAllByRole('link', { name: 'Admin' })).toHaveLength(2)
  })

  it('makes a failed authoritative role lookup retryable without remounting or sending anonymous requests', async () => {
    apiClient.defaults.adapter.mockImplementationOnce(config => Promise.reject(rejection(config, 503)))
    render(view(true))
    expect(await screen.findByRole('alert')).toHaveTextContent('Account access')
    expect(screen.queryByRole('link', { name: 'Admin' })).not.toBeInTheDocument()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Retry account access' }))
    expect(await screen.findByRole('link', { name: 'Admin' })).toBeInTheDocument()
    expect(apiClient.defaults.adapter).toHaveBeenCalledTimes(2)
    expect(apiClient.defaults.adapter.mock.calls.every(([config]) => config.headers.get('Authorization') === 'Bearer token-a')).toBe(true)
  })

  it('clears admin navigation immediately for a new actor and ignores an old admin response', async () => {
    let finishOld
    apiClient.defaults.adapter.mockImplementationOnce(config => new Promise(resolve => { finishOld = () => resolve(response(config)) }))
      .mockImplementation(config => Promise.resolve(response(config, 'buyer-b', 'attendee')))
    bind()
    const { rerender } = render(view())
    await waitFor(() => expect(apiClient.defaults.adapter).toHaveBeenCalledTimes(1))
    Object.assign(auth, { userId: 'buyer-b', sessionId: 'session-b', user: { id: 'buyer-b' }, getToken: vi.fn().mockResolvedValue('token-b') })
    bind()
    rerender(view())
    await waitFor(() => expect(apiClient.defaults.adapter).toHaveBeenCalledTimes(2))
    await act(async () => finishOld())
    expect(screen.queryByRole('link', { name: 'Admin' })).not.toBeInTheDocument()
    expect(apiClient.defaults.adapter.mock.calls[1][0].headers.get('Authorization')).toBe('Bearer token-b')
  })

  it('does not carry an already displayed admin role through sign-out and another sign-in', async () => {
    bind()
    const { rerender } = render(view())
    await screen.findByRole('link', { name: 'Admin' })
    Object.assign(auth, { isSignedIn: false, userId: null, sessionId: null, user: null })
    bind()
    rerender(view())
    expect(screen.queryByRole('link', { name: 'Admin' })).not.toBeInTheDocument()
    Object.assign(auth, { isSignedIn: true, userId: 'buyer-b', sessionId: 'session-b', user: { id: 'buyer-b' }, getToken: vi.fn().mockResolvedValue('token-b') })
    apiClient.defaults.adapter.mockImplementation(() => new Promise(() => {}))
    bind()
    rerender(view())
    expect(screen.queryByRole('link', { name: 'Admin' })).not.toBeInTheDocument()
  })

  it('requires the backend response to identify the current Clerk actor', async () => {
    apiClient.defaults.adapter.mockImplementation(config => Promise.resolve(response(config, 'different-buyer', 'admin')))
    render(view(true))
    expect(await screen.findByRole('alert')).toHaveTextContent('Account access')
    expect(screen.queryByRole('link', { name: 'Admin' })).not.toBeInTheDocument()
  })

  it('removes an already displayed admin link during an actor or session transition', async () => {
    bind()
    const { rerender } = render(view())
    await screen.findByRole('link', { name: 'Admin' })
    Object.assign(auth, { sessionId: 'session-renewed', getToken: vi.fn(() => new Promise(() => {})) })
    bind()
    rerender(view())
    expect(screen.queryByRole('link', { name: 'Admin' })).not.toBeInTheDocument()
    Object.assign(auth, { userId: 'buyer-b', sessionId: 'session-b', user: { id: 'buyer-b', publicMetadata: { role: 'admin' } } })
    bind()
    rerender(view())
    expect(screen.queryByRole('link', { name: 'Admin' })).not.toBeInTheDocument()
  })

  it('retries on a real token binding change after token retrieval was unavailable', async () => {
    auth.getToken.mockRejectedValueOnce(new Error('Session token unavailable'))
    bind()
    render(view())
    expect(await screen.findByRole('alert')).toHaveTextContent('Account access')
    expect(apiClient.defaults.adapter).not.toHaveBeenCalled()
    await act(async () => bind())
    expect(await screen.findByRole('link', { name: 'Admin' })).toBeInTheDocument()
    expect(apiClient.defaults.adapter).toHaveBeenCalledTimes(1)
  })

  it('makes the mobile Admin destination selectable and closes the menu after navigation', async () => {
    render(view(true))
    await screen.findByRole('link', { name: 'Admin' })
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Toggle menu' }))
    const mobile = screen.getByRole('navigation', { name: 'Mobile navigation' })
    await user.click(within(mobile).getByRole('link', { name: 'Admin' }))
    expect(screen.queryByRole('navigation', { name: 'Mobile navigation' })).not.toBeInTheDocument()
  })

  it('keeps the public buyer links on public routes', async () => {
    render(view(true, '/events'))
    await screen.findByRole('link', { name: 'Admin' })
    const primary = screen.getByRole('navigation', { name: 'Primary navigation' })
    for (const name of ['nav.events', 'Discover', 'nav.myTickets', 'Saved', 'nav.scanner', 'nav.dashboard']) {
      expect(within(primary).getByRole('link', { name })).toBeInTheDocument()
    }
    expect(screen.queryByRole('link', { name: /View public site/ })).not.toBeInTheDocument()
  })

  it.each(['/dashboard', '/dashboard/events/6/edit', '/admin/users', '/support'])('switches %s to workspace navigation', async path => {
    render(view(true, path))
    const admin = await screen.findByRole('link', { name: 'Admin' })
    expect(admin).toHaveAttribute('href', '/admin')
    const primary = screen.getByRole('navigation', { name: 'Primary navigation' })
    expect(within(primary).getByRole('link', { name: 'nav.dashboard' })).toHaveAttribute('href', '/dashboard')
    expect(within(primary).getByRole('link', { name: 'nav.scanner' })).toHaveAttribute('href', '/dashboard/scanner')
    expect(within(primary).getByRole('link', { name: 'Settings' })).toHaveAttribute('href', '/dashboard/settings')
    expect(within(primary).getByRole('link', { name: 'Support' })).toHaveAttribute('href', '/support')
    for (const name of ['nav.events', 'Discover', 'nav.myTickets', 'Saved']) expect(screen.queryByRole('link', { name })).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: /View public site/ })).toHaveAttribute('href', '/')
    expect(screen.queryByRole('button', { name: 'Search events' })).not.toBeInTheDocument()
  })

  it.each([['attendee', []], ['support', ['Support']]])('gates workspace platform links for the %s role', async (role, visible) => {
    apiClient.defaults.adapter.mockImplementation(config => Promise.resolve(response(config, 'buyer-a', role)))
    render(view(true, '/dashboard'))
    await waitFor(() => expect(apiClient.defaults.adapter).toHaveBeenCalled())
    await waitFor(() => expect(Boolean(screen.queryByRole('link', { name: 'Support' }))).toBe(visible.includes('Support')))
    expect(screen.queryByRole('link', { name: 'Admin' })).not.toBeInTheDocument()
    expect(screen.getAllByRole('link', { name: 'Settings' })).toHaveLength(1)
  })

  it('opens and closes the workspace mobile menu', async () => {
    render(view(true, '/dashboard/settings'))
    await screen.findByRole('link', { name: 'Admin' })
    const user = userEvent.setup()
    const toggle = screen.getByRole('button', { name: 'Toggle menu' })
    await user.click(toggle)
    const mobile = screen.getByRole('navigation', { name: 'Mobile navigation' })
    expect(within(mobile).getByRole('link', { name: 'Settings' })).toHaveAttribute('aria-current', 'page')
    expect(within(mobile).getByRole('link', { name: /View public site/ })).toHaveAttribute('href', '/')
    within(mobile).getByRole('link', { name: 'Settings' }).focus()
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('navigation', { name: 'Mobile navigation' })).not.toBeInTheDocument()
    expect(toggle).toHaveFocus()
  })
})
