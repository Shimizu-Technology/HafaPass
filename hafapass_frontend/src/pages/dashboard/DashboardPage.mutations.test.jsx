import { act, cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { getApiAuthContext, setAuthTokenGetter } from '../../api/client'
import DashboardPage from './DashboardPage'
import { uploadImage } from '../../utils/uploads'

vi.mock('../../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn(), post: vi.fn(), put: vi.fn() } }))
vi.mock('../../utils/uploads', () => ({ uploadImage: vi.fn() }))
const owners = [1, 2].map(id => ({ id, name: id === 1 ? 'Alpha organization' : 'Beta organization', role: 'owner', permissions: { manage_organization: true, manage_events: true } }))
// Verification needs a description (the API refuses it otherwise), so the
// fixture has one and the setup checklist's Submit for review is available.
const profile = name => ({ business_name: name, business_description: 'Island events', verification_phone: '+1-671-555-1234', verification_link: 'https://example.com/organizer', organization: { role: 'owner' }, policy_accepted: true, verification_status: 'unverified' })
const deferred = () => {
  let resolve, reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}
let profiles, clearAuth
const mount = () => render(<MemoryRouter initialEntries={['/dashboard']}><DashboardPage /></MemoryRouter>)
const closeEditor = () => userEvent.click(screen.getByRole('heading', { name: 'Edit Profile' }).parentElement.querySelector('button'))
const bind = (userId = 'actor-a', sessionId = 'session-a', getToken = () => Promise.resolve('synthetic-token')) => {
  window.localStorage.setItem('hafapass_scanner_user_id', userId)
  clearAuth = setAuthTokenGetter(getToken, { userId, sessionId, ready: true })
}
const submitVerification = async () => {
  await userEvent.click(await screen.findByRole('button', { name: 'Submit for review' }))
  await userEvent.click(screen.getByRole('button', { name: 'Send request' }))
}
const switchTo = async id => {
  await userEvent.selectOptions(screen.getByLabelText('Organization'), String(id))
  await screen.findByRole('heading', { name: `Welcome, ${profiles[id].business_name}` })
}

beforeEach(() => {
  vi.clearAllMocks()
  apiClient.get.mockReset(); apiClient.post.mockReset(); apiClient.put.mockReset()
  uploadImage.mockReset()
  window.localStorage.clear()
  window.sessionStorage.clear()
  window.localStorage.setItem('hafapass_organization_id', '1')
  profiles = { 1: profile('Alpha'), 2: profile('Beta') }
  apiClient.get.mockImplementation((path, config) => {
    const org = config?.organizationId || window.localStorage.getItem('hafapass_organization_id')
    if (path === '/organizer/organizations') return Promise.resolve({ data: owners })
    if (path === '/organizer_profile') return Promise.resolve({ data: { ...profiles[org] } })
    if (path === '/organizer/events') return Promise.resolve({ data: { events: [] } })
    throw new Error(`Unexpected ${path}`)
  })
})
afterEach(() => { cleanup(); clearAuth?.(); clearAuth = null; vi.unstubAllEnvs() })

describe('dashboard mutation ownership', () => {
  it.each([
    ['https://storage.invalid/uploads/logo.webp', 'storage.invalid', true],
    ['https://off-host.invalid/uploads/logo.webp', 'storage.invalid', false],
  ])('previews only a logo from the approved host (%s)', async (logo, host, visible) => {
    profiles[1] = { ...profiles[1], logo_url: logo, image_asset_host: host }
    mount()
    await userEvent.click(await screen.findByTitle('Edit Profile'))
    expect(screen.queryByRole('img', { name: 'Logo' }) !== null).toBe(visible)
  })
  it.each(['page', 'search'])('keeps a readiness mutation live while changing the event %s', async navigation => {
    const pending = deferred()
    const normalGet = apiClient.get.getMockImplementation()
    apiClient.get.mockImplementation((path, config) => path === '/organizer/events'
      ? Promise.resolve({ data: { events: [{ id: config.params.page, title: `Event page ${config.params.page}`, status: 'published' }],
        meta: { current_page: config.params.page, total_pages: 2, total_count: 21 } } }) : normalGet(path, config))
    apiClient.post.mockReturnValueOnce(pending.promise)
    mount()
    await submitVerification()
    const readinessConfig = apiClient.post.mock.calls[0][2]
    const profileReads = apiClient.get.mock.calls.filter(([path]) => path !== '/organizer/events')
    if (navigation === 'page') await userEvent.click(screen.getByRole('button', { name: 'Next', exact: true }))
    else {
      await userEvent.type(screen.getByLabelText('Find an event'), 'venue')
      await userEvent.click(screen.getByRole('button', { name: 'Search events', exact: true }))
    }
    await waitFor(() => expect(apiClient.get).toHaveBeenLastCalledWith('/organizer/events', expect.objectContaining({
      params: { q: navigation === 'search' ? 'venue' : '', page: navigation === 'page' ? 2 : 1 }, organizationId: '1',
    })))
    expect(readinessConfig.signal.aborted).toBe(false)
    expect(screen.getByRole('button', { name: 'Sending…' })).toBeDisabled()
    expect(apiClient.get.mock.calls.filter(([path]) => path !== '/organizer/events')).toEqual(profileReads)
    await act(async () => pending.resolve({ data: { ...profiles[1], verification_status: 'pending' } }))
    expect(screen.getByText("We're reviewing your account")).toBeInTheDocument()
    expect(screen.getByLabelText('Find an event')).toHaveValue(navigation === 'search' ? 'venue' : '')
    expect(screen.getByText(`Page ${navigation === 'page' ? 2 : 1} of 2 · 21 results`)).toBeInTheDocument()
  })

  it.each([true, false])('loads each organization once, including initial auto-selection (%s)', async stored => {
    if (!stored) window.localStorage.removeItem('hafapass_organization_id')
    mount()
    await screen.findByRole('heading', { name: 'Welcome, Alpha' })
    for (const path of ['/organizer/organizations', '/organizer_profile', '/organizer/events']) {
      expect(apiClient.get.mock.calls.filter(([url]) => url === path)).toHaveLength(1)
    }
    await switchTo(2)
    for (const path of ['/organizer/organizations', '/organizer_profile', '/organizer/events']) {
      expect(apiClient.get.mock.calls.filter(([url]) => url === path)).toHaveLength(2)
    }
    expect(apiClient.get.mock.calls.filter(([url]) => url === '/organizer_profile').map(([, config]) => config.organizationId)).toEqual(['1', '2'])
  })

  it.each(['success', 'error'])('ignores a paged Alpha list %s after switching organizations', async outcome => {
    const old = deferred()
    const normalGet = apiClient.get.getMockImplementation()
    apiClient.get.mockImplementation((path, config) => {
      if (path !== '/organizer/events') return normalGet(path, config)
      if (config.params.page === 2) return old.promise
      return Promise.resolve({ data: { events: [{ id: 101, title: `Organization ${config.organizationId} event`, status: 'published' }],
        meta: { current_page: 1, total_pages: 2, total_count: 21 } } })
    })
    mount()
    await userEvent.click(await screen.findByRole('button', { name: 'Next', exact: true }))
    const oldConfig = apiClient.get.mock.calls.at(-1)[1]
    await switchTo(2)
    expect(oldConfig.signal.aborted).toBe(true)
    await act(async () => outcome === 'success'
      ? old.resolve({ data: { events: [{ id: 102, title: 'Obsolete Alpha list', status: 'published' }] } })
      : old.reject({ response: { status: 503 } }))
    expect(screen.getByRole('heading', { name: 'Welcome, Beta' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: /Organization 2 event/ })).toBeInTheDocument()
    expect(screen.queryByText(/Obsolete Alpha|Failed to load/)).not.toBeInTheDocument()
  })

  it.each(['success', 'failure'])('withdraws Alpha rows and controls throughout a delayed Beta organization switch (%s)', async outcome => {
    const betaProfile = deferred(), betaEvents = deferred()
    const normalGet = apiClient.get.getMockImplementation()
    apiClient.get.mockImplementation((path, config) => {
      const org = config?.organizationId || window.localStorage.getItem('hafapass_organization_id')
      if (path === '/organizer_profile' && org === '2') return betaProfile.promise
      if (path === '/organizer/events') return org === '2' ? betaEvents.promise : Promise.resolve({ data: { events: [{ id: 101, title: 'Private Alpha event', status: 'published', permissions: { scan: true, edit_event_content: true }, ticket_types: [{ quantity_sold: 19 }] }], meta: { total_count: 21, total_pages: 2 } } })
      return normalGet(path, config)
    })
    mount()
    await screen.findByRole('link', { name: /Private Alpha event/ })
    await userEvent.selectOptions(screen.getByLabelText('Organization'), '2')
    expect(screen.getByRole('status')).toHaveTextContent('Loading Beta organization')
    expect(screen.queryByRole('link', { name: /Private Alpha event/ })).not.toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'Welcome, Alpha' })).not.toBeInTheDocument()
    expect(screen.queryByTitle('Edit Profile')).not.toBeInTheDocument()
    expect(screen.queryByText('19 sold')).not.toBeInTheDocument()
    expect(screen.queryByText('Get ready to sell tickets')).not.toBeInTheDocument()
    if (outcome === 'failure') {
      await act(async () => betaProfile.reject({ response: { status: 503 } }))
      await screen.findByText('Failed to load dashboard. Please try again.')
      expect(screen.queryByText(/Private Alpha/)).not.toBeInTheDocument()
      expect(screen.queryByText('19 sold')).not.toBeInTheDocument()
      expect(screen.queryByTitle('Edit Profile')).not.toBeInTheDocument()
    } else {
      await act(async () => betaProfile.resolve({ data: profiles[2] }))
      await waitFor(() => expect(apiClient.get).toHaveBeenCalledWith('/organizer/events', expect.objectContaining({ organizationId: '2' })))
      expect(screen.getByRole('status')).toHaveTextContent('Loading Beta organization')
      expect(screen.queryByRole('link', { name: /Private Alpha event/ })).not.toBeInTheDocument()
      await act(async () => betaEvents.resolve({ data: { events: [{ id: 202, title: 'Authorized Beta event', status: 'published', permissions: { scan: true } }] } }))
      expect(await screen.findByRole('link', { name: /Authorized Beta event/ })).toBeInTheDocument()
      expect(screen.queryByText(/Private Alpha/)).not.toBeInTheDocument()
    }
  })

  it.each(['success', 'error'])('ignores a late Alpha readiness %s and its finally while Beta is busy', async outcome => {
    const old = deferred(), current = deferred()
    apiClient.post.mockReturnValueOnce(old.promise).mockReturnValueOnce(current.promise)
    mount()
    await submitVerification()
    const oldConfig = apiClient.post.mock.calls[0][2]
    await switchTo(2)
    await submitVerification()
    await act(async () => outcome === 'success' ? old.resolve({ data: profile('Stale Alpha') }) : old.reject({ response: { data: { error: 'Old Alpha failure' } } }))
    expect(screen.getByRole('heading', { name: 'Welcome, Beta' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Sending…' })).toBeDisabled()
    expect(screen.queryByText('Old Alpha failure')).not.toBeInTheDocument()
    expect(oldConfig.organizationId).toBe('1')
    expect(oldConfig.signal.aborted).toBe(true)
    await act(async () => current.resolve({ data: { ...profiles[2], verification_status: 'pending' } }))
    expect(screen.getByText("We're reviewing your account")).toBeInTheDocument()
  })

  it('does not revive an old Alpha operation after switching away and back', async () => {
    const old = deferred(), current = deferred()
    apiClient.post.mockReturnValueOnce(old.promise).mockReturnValueOnce(current.promise)
    mount()
    await submitVerification()
    await switchTo(2); await switchTo(1)
    await submitVerification()
    await act(async () => old.resolve({ data: profile('Old Alpha visit') }))
    expect(screen.getByRole('heading', { name: 'Welcome, Alpha' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Sending…' })).toBeDisabled()
    await act(async () => current.resolve({ data: { ...profiles[1], verification_status: 'pending' } }))
    expect(screen.getByText("We're reviewing your account")).toBeInTheDocument()
  })

  it.each(['success', 'error'])('keeps a new Beta editor draft when an old Alpha save completes with %s', async outcome => {
    const old = deferred()
    apiClient.put.mockReturnValueOnce(old.promise)
    mount()
    await userEvent.click(await screen.findByTitle('Edit Profile'))
    await userEvent.click(screen.getByRole('button', { name: 'Save', exact: true }))
    await closeEditor()
    await switchTo(2)
    await userEvent.click(screen.getByTitle('Edit Profile'))
    const name = screen.getByDisplayValue('Beta')
    await userEvent.clear(name); await userEvent.type(name, 'Beta draft')
    const reads = apiClient.get.mock.calls.length
    await act(async () => outcome === 'success' ? old.resolve({ data: profiles[1] }) : old.reject(new Error('Old save failure')))
    expect(screen.getByRole('heading', { name: 'Edit Profile' })).toBeInTheDocument()
    expect(screen.getByDisplayValue('Beta draft')).toBeInTheDocument()
    expect(apiClient.get.mock.calls).toHaveLength(reads)
    apiClient.put.mockImplementation((_path, payload) => { profiles[2] = { ...profiles[2], ...payload }; return Promise.resolve({ data: profiles[2] }) })
    await userEvent.click(screen.getByRole('button', { name: 'Save', exact: true }))
    expect(await screen.findByRole('heading', { name: 'Welcome, Beta draft' })).toBeInTheDocument()
    expect(apiClient.put.mock.calls[1][2].organizationId).toBe('2')
  })

  it('protects a reopened editor in the same organization from the prior modal save', async () => {
    const old = deferred()
    apiClient.put.mockReturnValueOnce(old.promise)
    mount()
    await userEvent.click(await screen.findByTitle('Edit Profile'))
    await userEvent.click(screen.getByRole('button', { name: 'Save', exact: true }))
    await closeEditor()
    await userEvent.click(screen.getByTitle('Edit Profile'))
    await userEvent.type(screen.getAllByDisplayValue('Alpha').at(-1), ' newer draft')
    await act(async () => old.resolve({ data: profiles[1] }))
    expect(screen.getByDisplayValue('Alpha newer draft')).toBeInTheDocument()
  })

  it('withdraws an old logo upload callback and never places its URL into Beta’s profile save', async () => {
    const old = deferred()
    uploadImage.mockReturnValueOnce(old.promise)
    mount()
    await userEvent.click(await screen.findByTitle('Edit Profile'))
    await userEvent.upload(document.querySelector('input[type="file"]'), new File(['synthetic-image'], 'alpha.png', { type: 'image/png' }))
    const ownerCurrent = uploadImage.mock.calls[0][2]
    expect(ownerCurrent()).toBe(true)
    await closeEditor(); await switchTo(2)
    await userEvent.click(screen.getByTitle('Edit Profile'))
    await act(async () => old.resolve('https://synthetic.invalid/alpha-logo.png'))
    expect(ownerCurrent()).toBe(false)
    apiClient.put.mockResolvedValueOnce({ data: profiles[2] })
    await userEvent.click(screen.getByRole('button', { name: 'Save', exact: true }))
    await screen.findByRole('heading', { name: 'Welcome, Beta' })
    expect(apiClient.put.mock.calls[0][1].logo_url).toBeNull()
  })

  it.each(['session', 'account', 'remount'])('withdraws readiness completion authority across a %s change', async kind => {
    bind()
    const old = deferred()
    apiClient.post.mockReturnValueOnce(old.promise)
    const first = mount()
    await submitVerification()
    profiles[1] = profile('Fresh owner context')
    if (kind === 'remount') { first.unmount(); mount() }
    else await act(async () => bind(kind === 'account' ? 'actor-b' : 'actor-a', 'session-b'))
    await screen.findByRole('heading', { name: 'Welcome, Fresh owner context' })
    await act(async () => old.resolve({ data: profile('Stale owner context') }))
    expect(screen.getByRole('heading', { name: 'Welcome, Fresh owner context' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Submit for review' })).toBeEnabled()
  })

  it.each([false, true])('binds readiness before token acquisition and never transports a withdrawn visit (return to Alpha: %s)', async returnToAlpha => {
    const actual = await vi.importActual('../../api/client')
    const token = deferred()
    const originalAdapter = actual.default.defaults.adapter
    const adapter = vi.fn()
    actual.default.defaults.adapter = adapter
    bind('actor-a', 'session-a', () => token.promise)
    apiClient.post.mockImplementation((...args) => actual.default.post(...args))
    try {
      mount()
      await submitVerification()
      expect(apiClient.post.mock.calls[0][2].authContext).toBe(getApiAuthContext())
      await switchTo(2)
      if (returnToAlpha) await switchTo(1)
      await act(async () => token.resolve('old-token'))
      expect(adapter).not.toHaveBeenCalled()
      expect(screen.getByRole('heading', { name: returnToAlpha ? 'Welcome, Alpha' : 'Welcome, Beta' })).toBeInTheDocument()
    } finally { actual.default.defaults.adapter = originalAdapter }
  })

  it('does not load an account-sensitive dashboard before authorization is ready', async () => {
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'synthetic-clerk-key')
    mount()
    expect(screen.getByRole('status')).toHaveTextContent('Preparing your account')
    expect(apiClient.get).not.toHaveBeenCalled()
    await act(async () => bind())
    await screen.findByRole('heading', { name: 'Welcome, Alpha' })
  })

  it('does not refresh or change a new actor’s first-time profile draft after an old creation finishes', async () => {
    bind()
    window.localStorage.removeItem('hafapass_organization_id')
    apiClient.get.mockImplementation(path => path === '/organizer/organizations'
      ? Promise.resolve({ data: [] }) : Promise.reject({ response: { status: 404 } }))
    const old = deferred()
    apiClient.post.mockReturnValueOnce(old.promise)
    mount()
    await userEvent.type(await screen.findByLabelText(/Business Name/), 'Alpha setup')
    await userEvent.click(screen.getByRole('button', { name: 'Create Organizer Profile' }))
    await act(async () => bind('actor-b', 'session-b'))
    await userEvent.type(await screen.findByLabelText(/Business Name/), 'Beta setup draft')
    const reads = apiClient.get.mock.calls.length
    await act(async () => old.resolve({ data: profile('Alpha setup') }))
    expect(screen.getByLabelText(/Business Name/)).toHaveValue('Beta setup draft')
    expect(apiClient.get.mock.calls).toHaveLength(reads)
    expect(apiClient.post.mock.calls[0][2].organizationId).toBeNull()
    expect(apiClient.post.mock.calls[0][2].authContext.userId).toBe('actor-a')
  })
})
