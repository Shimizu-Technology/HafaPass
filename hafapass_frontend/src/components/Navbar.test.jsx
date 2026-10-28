import 'fake-indexeddb/auto'
import { act, render, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter, useNavigate } from 'react-router-dom'
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
vi.mock('./LanguageSwitcher', () => ({ default: () => null }))
vi.mock('../monitoring', () => ({ Sentry: { setUser: vi.fn(), captureException: vi.fn() } }))

let Navbar, Wrapper, apiClient, setAuthTokenGetter, workspace
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
    workspace = await import('../utils/workspace')
    apiClient.defaults.adapter = vi.fn(config => Promise.resolve(response(config)))
  })
  afterEach(() => vi.unstubAllEnvs())

  it('synchronizes the mounted header and browser theme across routes and scrolling', async () => {
    Object.assign(auth, { isSignedIn: false, userId: null, sessionId: null, user: null })
    const theme = document.createElement('meta')
    theme.name = 'theme-color'
    theme.content = '#ffffff'
    document.head.append(theme)
    function RouteControls() {
      const navigate = useNavigate()
      return <>{['/', '/host', '/events', '/discover', '/collections/weekend', '/my-tickets', '/saved', '/sign-in', '/sign-up', '/sign-in/factor-one', '/about', '/tickets/guest-pass'].map(path =>
        <button key={path} onClick={() => navigate(path)}>Go to {path}</button>)}</>
    }
    const user = userEvent.setup()
    const assertTheme = async dark => {
      await waitFor(() => {
        expect(screen.getByRole('banner')).toHaveClass(dark ? 'bg-brand-950' : 'bg-white')
        expect(theme).toHaveAttribute('content', dark ? '#032827' : '#ffffff')
      })
    }
    const scroll = async y => {
      await act(() => {
        Object.defineProperty(window, 'scrollY', { configurable: true, value: y })
        window.dispatchEvent(new Event('scroll'))
      })
    }
    try {
      render(<MemoryRouter initialEntries={['/events']}><Navbar /><RouteControls /></MemoryRouter>)
      await assertTheme(true)
      for (const path of ['/', '/host', '/events', '/discover', '/collections/weekend', '/my-tickets', '/saved', '/sign-in', '/sign-up', '/sign-in/factor-one', '/tickets/guest-pass']) {
        await user.click(screen.getByRole('button', { name: `Go to ${path}`, exact: true }))
        await assertTheme(true)
        await scroll(100)
        await assertTheme(path.startsWith('/tickets/') || path.startsWith('/sign-'))
        await scroll(0)
        await assertTheme(true)
        await user.click(screen.getByRole('button', { name: 'Go to /about', exact: true }))
        await assertTheme(false)
      }
    } finally {
      theme.remove()
      await scroll(0)
    }
  })

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
    for (const name of ["Events", 'Discover', "My Tickets", 'Saved', "Scanner", "Dashboard"]) {
      expect(within(primary).getByRole('link', { name })).toBeInTheDocument()
    }
    expect(screen.queryByRole('link', { name: /View public site/ })).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: "Host an event" })).not.toBeInTheDocument()
  })

  it('offers guests the host landing page in the desktop and mobile navigation', async () => {
    Object.assign(auth, { isSignedIn: false, userId: null, sessionId: null, user: null })
    render(view(true, '/events'))
    const primary = screen.getByRole('navigation', { name: 'Primary navigation' })
    expect(within(primary).getByRole('link', { name: "Host an event" })).toHaveAttribute('href', '/host')
    await userEvent.setup().click(screen.getByRole('button', { name: 'Toggle menu' }))
    const mobile = screen.getByRole('navigation', { name: 'Mobile navigation' })
    expect(within(mobile).getByRole('link', { name: "Host an event" })).toHaveAttribute('href', '/host')
  })

  // Settings follows the same organization permissions the dashboard uses.
  const owner = { id: 7, name: 'Island Nights', role: 'owner', permissions: { manage_members: true, manage_payout_settings: true } }
  const scanner = { id: 8, name: 'Door team', role: 'scanner', permissions: { scan: true } }
  const serve = (organizations, role = 'admin') => apiClient.defaults.adapter.mockImplementation(config => Promise.resolve(
    config.url === '/organizer/organizations' ? { config, data: organizations, status: 200, statusText: 'OK', headers: {} } : response(config, 'buyer-a', role)))
  const organizationCalls = () => apiClient.defaults.adapter.mock.calls.filter(([config]) => config.url === '/organizer/organizations')
  const allowSettings = () => serve([owner])

  it.each(['/dashboard', '/dashboard/events/6/edit', '/admin/users', '/support'])('switches %s to workspace navigation', async path => {
    allowSettings()
    render(view(true, path))
    const admin = await screen.findByRole('link', { name: 'Admin' })
    await screen.findByRole('link', { name: "Settings" })
    expect(admin).toHaveAttribute('href', '/admin')
    const primary = screen.getByRole('navigation', { name: 'Primary navigation' })
    expect(within(primary).getByRole('link', { name: "Dashboard" })).toHaveAttribute('href', '/dashboard')
    expect(within(primary).getByRole('link', { name: "Scanner" })).toHaveAttribute('href', '/dashboard/scanner')
    expect(within(primary).getByRole('link', { name: "Settings" })).toHaveAttribute('href', '/dashboard/settings')
    expect(within(primary).getByRole('link', { name: "Support" })).toHaveAttribute('href', '/support')
    for (const name of ["Events", 'Discover', "My Tickets", 'Saved']) expect(screen.queryByRole('link', { name })).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: "View public site" })).toHaveAttribute('href', '/')
    expect(screen.getByRole('link', { name: "HåfaPass workspace home" })).toHaveAttribute('href', '/dashboard')
    expect(screen.queryByRole('button', { name: 'Search events' })).not.toBeInTheDocument()
  })

  it.each([['attendee', false], ['support', true]])('gates workspace platform links for the %s role once the role has loaded', async (role, support) => {
    apiClient.defaults.adapter.mockImplementation(config => Promise.resolve(response(config, 'buyer-a', role)))
    render(view(true, '/dashboard'))
    await waitFor(() => expect(workspace.getAccountRole().role).toBe(role))
    expect(Boolean(screen.queryByRole('link', { name: "Support" }))).toBe(support)
    expect(screen.queryByRole('link', { name: 'Admin' })).not.toBeInTheDocument()
  })

  it('shows Settings on an event workspace deep link for an owner without visiting the dashboard', async () => {
    window.localStorage.setItem('hafapass_organization_id', '7')
    serve([owner, scanner], 'attendee')
    render(view(true, '/dashboard/events/6/edit'))
    expect(await screen.findByRole('link', { name: "Settings" })).toHaveAttribute('href', '/dashboard/settings')
    expect(organizationCalls()).toHaveLength(1)
    expect(organizationCalls()[0][0].headers.get('Authorization')).toBe('Bearer token-a')
  })

  it.each([
    { id: 7, role: 'manager', permissions: { view_activity_events: true } },
    { id: 7, role: 'finance', permissions: { view_activity_finance: true } },
    { id: 7, role: 'marketer', activity_access: true, permissions: { manage_marketing: true } },
  ])('opens Settings directly on Activity for an activity-only teammate (%j)', async organization => {
    window.localStorage.setItem('hafapass_organization_id', '7')
    serve([organization], 'attendee')
    render(view(true, '/dashboard/settings/activity'))
    expect(await screen.findByRole('link', { name: 'Settings' })).toHaveAttribute('href', '/dashboard/settings/activity')
    expect(screen.getByRole('link', { name: 'Settings' })).toHaveAttribute('aria-current', 'page')
  })

  it('hides Settings for a scanner and updates when the selected organization changes', async () => {
    window.localStorage.setItem('hafapass_organization_id', '8')
    serve([owner, scanner], 'attendee')
    render(view(true, '/dashboard/events/6'))
    await waitFor(() => expect(organizationCalls()).toHaveLength(1))
    await waitFor(() => expect(workspace.getAccountRole().role).toBe('attendee'))
    expect(screen.queryByRole('link', { name: "Settings" })).not.toBeInTheDocument()
    await act(() => {
      window.localStorage.setItem('hafapass_organization_id', '7')
      window.dispatchEvent(new StorageEvent('storage', { key: 'hafapass_organization_id' }))
    })
    expect(screen.getByRole('link', { name: "Settings" })).toBeInTheDocument()
    expect(organizationCalls()).toHaveLength(1)
  })

  it('drops Settings on sign-out and reloads it for the next account', async () => {
    window.localStorage.setItem('hafapass_organization_id', '7')
    serve([owner])
    bind()
    const { rerender } = render(view(false, '/dashboard'))
    await screen.findByRole('link', { name: "Settings" })
    Object.assign(auth, { isSignedIn: false, userId: null, sessionId: null, user: null })
    bind()
    rerender(view(false, '/dashboard'))
    expect(screen.queryByRole('link', { name: "Settings" })).not.toBeInTheDocument()
    Object.assign(auth, { isSignedIn: true, userId: 'buyer-b', sessionId: 'session-b', user: { id: 'buyer-b' }, getToken: vi.fn().mockResolvedValue('token-b') })
    serve([scanner])
    bind()
    rerender(view(false, '/dashboard'))
    await waitFor(() => expect(organizationCalls()).toHaveLength(2))
    expect(organizationCalls()[1][0].headers.get('Authorization')).toBe('Bearer token-b')
    expect(screen.queryByRole('link', { name: "Settings" })).not.toBeInTheDocument()
  })

  it('shares one organization lookup with a dashboard load that starts at the same time', async () => {
    window.localStorage.setItem('hafapass_organization_id', '7')
    let finish
    apiClient.defaults.adapter.mockImplementation(config => config.url === '/organizer/organizations'
      ? new Promise(resolve => { finish = () => resolve({ config, data: [owner], status: 200, statusText: 'OK', headers: {} }) })
      : Promise.resolve(response(config)))
    const { loadOrganizerOrganizations } = await import('../utils/organizerOrganizations')
    const { getApiAuthContext } = await import('../api/client')
    render(view(true, '/dashboard'))
    await waitFor(() => expect(organizationCalls()).toHaveLength(1))
    const dashboardLoad = loadOrganizerOrganizations(getApiAuthContext())
    await act(async () => finish())
    expect((await dashboardLoad).data).toEqual([owner])
    expect(await screen.findByRole('link', { name: "Settings" })).toBeInTheDocument()
    expect(organizationCalls()).toHaveLength(1)
  })

  it('opens and closes the workspace mobile menu', async () => {
    allowSettings()
    render(view(true, '/dashboard/settings'))
    await screen.findByRole('link', { name: "Settings" })
    const user = userEvent.setup()
    const toggle = screen.getByRole('button', { name: 'Toggle menu' })
    await user.click(toggle)
    const mobile = screen.getByRole('navigation', { name: 'Mobile navigation' })
    expect(within(mobile).getByRole('link', { name: "Settings" })).toHaveAttribute('aria-current', 'page')
    expect(within(mobile).getByRole('link', { name: "View public site" })).toHaveAttribute('href', '/')
    within(mobile).getByRole('link', { name: "Settings" }).focus()
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('navigation', { name: 'Mobile navigation' })).not.toBeInTheDocument()
    expect(toggle).toHaveFocus()
  })

  // Least privilege: links follow what /me says this account can use.
  const serveWorkspace = (workspaceFlags, role = 'attendee') => apiClient.defaults.adapter.mockImplementation(config => Promise.resolve(
    config.url === '/me' ? { config, data: { clerk_id: 'buyer-a', role, workspace: workspaceFlags }, status: 200, statusText: 'OK', headers: {} }
      : { config, data: [], status: 200, statusText: 'OK', headers: {} }))

  it('offers a buyer without a team "Host an event" instead of Scanner and Dashboard', async () => {
    serveWorkspace({ organizer: false, scanner: false })
    render(view(true, '/events'))
    const primary = screen.getByRole('navigation', { name: 'Primary navigation' })
    expect(await within(primary).findByRole('link', { name: "Host an event" })).toHaveAttribute('href', '/dashboard')
    expect(within(primary).queryByRole('link', { name: "Scanner" })).not.toBeInTheDocument()
    expect(within(primary).queryByRole('link', { name: "Dashboard" })).not.toBeInTheDocument()
  })

  it('shows Dashboard without Scanner to a marketer and both to door staff', async () => {
    serveWorkspace({ organizer: true, scanner: false })
    const first = render(view(true, '/events'))
    let primary = screen.getByRole('navigation', { name: 'Primary navigation' })
    expect(await within(primary).findByRole('link', { name: "Dashboard" })).toBeInTheDocument()
    expect(within(primary).queryByRole('link', { name: "Scanner" })).not.toBeInTheDocument()
    first.unmount()

    serveWorkspace({ organizer: true, scanner: true })
    render(view(true, '/dashboard'))
    primary = screen.getByRole('navigation', { name: 'Primary navigation' })
    expect(await within(primary).findByRole('link', { name: "Scanner" })).toHaveAttribute('href', '/dashboard/scanner')
  })

  it('hides workspace Dashboard and Scanner from support staff without a team', async () => {
    serveWorkspace({ organizer: false, scanner: false }, 'support')
    render(view(true, '/support'))
    const primary = screen.getByRole('navigation', { name: 'Primary navigation' })
    expect(await within(primary).findByRole('link', { name: "Support" })).toBeInTheDocument()
    expect(within(primary).queryByRole('link', { name: "Dashboard" })).not.toBeInTheDocument()
    expect(within(primary).queryByRole('link', { name: "Scanner" })).not.toBeInTheDocument()
  })
})
