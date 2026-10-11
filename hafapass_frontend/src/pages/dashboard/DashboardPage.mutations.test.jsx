import { act, cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { getApiAuthContext, setAuthTokenGetter } from '../../api/client'
import DashboardPage from './DashboardPage'
import { uploadImage } from '../../utils/uploads'

vi.mock('../../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn(), post: vi.fn(), put: vi.fn() } }))
vi.mock('../../utils/uploads', () => ({ uploadImage: vi.fn() }))
const owners = [1, 2].map(id => ({ id, name: id === 1 ? 'Alpha organization' : 'Beta organization', role: 'owner', permissions: { manage_organization: true, manage_events: true } }))
const profile = name => ({ business_name: name, business_description: '', policy_accepted: true, verification_status: 'unverified' })
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
const switchTo = async id => {
  await userEvent.selectOptions(screen.getByLabelText('Organization'), String(id))
  await screen.findByRole('heading', { name: `Welcome, ${profiles[id].business_name}` })
}

beforeEach(() => {
  vi.clearAllMocks()
  apiClient.get.mockReset(); apiClient.post.mockReset(); apiClient.put.mockReset()
  uploadImage.mockReset()
  window.localStorage.clear()
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
  it.each(['success', 'error'])('ignores a late Alpha readiness %s and its finally while Beta is busy', async outcome => {
    const old = deferred(), current = deferred()
    apiClient.post.mockReturnValueOnce(old.promise).mockReturnValueOnce(current.promise)
    mount()
    await userEvent.click(await screen.findByRole('button', { name: 'Submit for review' }))
    const oldConfig = apiClient.post.mock.calls[0][2]
    await switchTo(2)
    await userEvent.click(screen.getByRole('button', { name: 'Submit for review' }))
    await act(async () => outcome === 'success' ? old.resolve({ data: profile('Stale Alpha') }) : old.reject({ response: { data: { error: 'Old Alpha failure' } } }))
    expect(screen.getByRole('heading', { name: 'Welcome, Beta' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Submit for review' })).toBeDisabled()
    expect(screen.queryByText('Old Alpha failure')).not.toBeInTheDocument()
    expect(oldConfig.organizationId).toBe('1')
    expect(oldConfig.signal.aborted).toBe(true)
    await act(async () => current.resolve({ data: { ...profiles[2], verification_status: 'pending' } }))
    expect(screen.getByText('pending')).toBeInTheDocument()
  })

  it('does not revive an old Alpha operation after switching away and back', async () => {
    const old = deferred(), current = deferred()
    apiClient.post.mockReturnValueOnce(old.promise).mockReturnValueOnce(current.promise)
    mount()
    await userEvent.click(await screen.findByRole('button', { name: 'Submit for review' }))
    await switchTo(2); await switchTo(1)
    await userEvent.click(screen.getByRole('button', { name: 'Submit for review' }))
    await act(async () => old.resolve({ data: profile('Old Alpha visit') }))
    expect(screen.getByRole('heading', { name: 'Welcome, Alpha' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Submit for review' })).toBeDisabled()
    await act(async () => current.resolve({ data: { ...profiles[1], verification_status: 'pending' } }))
    expect(screen.getByText('pending')).toBeInTheDocument()
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
    await userEvent.type(screen.getByDisplayValue('Alpha'), ' newer draft')
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
    await userEvent.click(await screen.findByRole('button', { name: 'Submit for review' }))
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
      await userEvent.click(await screen.findByRole('button', { name: 'Submit for review' }))
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
