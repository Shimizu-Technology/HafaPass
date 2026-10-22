import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { Link, MemoryRouter, Route, Routes } from 'react-router-dom'
import { AxiosError } from 'axios'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../../api/client'
import AdminDashboardPage from './AdminDashboardPage'
import ProviderReadinessPage from './ProviderReadinessPage'

vi.mock('./AdminLayout', () => ({ default: ({ children }) => <div>{children}</div> }))
vi.mock('../../components/ui/ScrollReveal', () => ({ StaggerContainer: ({ children }) => <div>{children}</div>, StaggerItem: ({ children }) => <div>{children}</div> }))
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no }); return { promise, resolve, reject } }
const response = (config, data) => ({ config, data, status: 200, statusText: 'OK', headers: {} })
const rejectResponse = (config, status, error) => Promise.reject(new AxiosError('Fixture rejection', undefined, config, null, { config, status, data: { error }, headers: {} }))
const capability = (reference = 'Private evidence A') => ({ capability: 'email_delivery', label: 'Email delivery', configured: true, enabled: false,
  status: 'disabled_pending_approval', required_controls: [], pending_submission: { id: 91, actor_user_id: 7, evidence_reference: reference } })
const data = name => ({ total_events: { draft: 1 }, total_users: { admin: 2 }, total_revenue_cents: 12345, total_tickets_sold: 2,
  recent_events: [], recent_orders: [{ id: 3, buyer_name: name, event_title: 'Synthetic event', total_cents: 1250, status: 'completed' }] })
const cases = [
  { Page: ProviderReadinessPage, route: '/admin/provider-readiness', endpoint: '/admin/platform_capabilities', body: name => ({ capabilities: [capability(name)] }), visible: name => screen.findByText(new RegExp(name)), retry: 'Retry provider readiness' },
  { Page: AdminDashboardPage, route: '/admin', endpoint: '/admin/dashboard', body: data, visible: name => screen.findByText(name), retry: 'Retry dashboard' },
]
let clearBinding, originalAdapter
const bind = (session = 'session-a', getter = () => Promise.resolve('token-a')) => { clearBinding = setAuthTokenGetter(getter, { userId: 'admin-a', sessionId: session, ready: true }) }
beforeEach(() => { originalAdapter = apiClient.defaults.adapter; bind() })
afterEach(() => { cleanup(); clearBinding?.(); apiClient.defaults.adapter = originalAdapter; vi.restoreAllMocks() })
const mount = entry => render(<MemoryRouter initialEntries={[entry.route]}><entry.Page /></MemoryRouter>)

for (const entry of cases) describe(`${entry.route} scoped administrator reads`, () => {
  it('discards old account reads after replacement and carries the captured token identity', async () => {
    const old = deferred(); let oldConfig
    apiClient.defaults.adapter = vi.fn(config => {
      if (config.authContext.sessionId === 'session-a') { oldConfig = config; return old.promise }
      return Promise.resolve(response(config, entry.body('Private B')))
    })
    mount(entry); await waitFor(() => expect(oldConfig).toBeDefined())
    await act(async () => bind('session-b', () => Promise.resolve('token-b')))
    await entry.visible('Private B')
    await act(async () => old.resolve(response(oldConfig, entry.body('Private A'))))
    expect(screen.queryByText(/Private A/)).not.toBeInTheDocument()
    expect(oldConfig.signal.aborted).toBe(true)
    expect(apiClient.defaults.adapter.mock.calls.at(-1)[0].headers.get('Authorization')).toBe('Bearer token-b')
  })
  it('never transports an old queued token after session replacement', async () => {
    const token = deferred(); const getter = vi.fn(() => token.promise); bind('session-a', getter)
    apiClient.defaults.adapter = vi.fn(config => Promise.resolve(response(config, entry.body('Current account'))))
    mount(entry); await waitFor(() => expect(getter).toHaveBeenCalled())
    expect(apiClient.defaults.adapter).not.toHaveBeenCalled()
    await act(async () => bind('session-b', () => Promise.resolve('token-b')))
    await entry.visible('Current account')
    await act(async () => token.resolve('token-a'))
    expect(apiClient.defaults.adapter).toHaveBeenCalledTimes(1)
  })
  it('withdraws a retained route and does not revive its old read on return', async () => {
    const old = deferred(); let oldConfig; let reads = 0
    apiClient.defaults.adapter = vi.fn(config => ++reads === 1 ? (oldConfig = config, old.promise) : Promise.resolve(response(config, entry.body('New visit'))))
    render(<MemoryRouter initialEntries={[entry.route]}><Routes><Route path="*" element={<><Link to="/events">Leave</Link><Link to={entry.route}>Return</Link><entry.Page /></>} /></Routes></MemoryRouter>)
    await waitFor(() => expect(oldConfig).toBeDefined())
    fireEvent.click(screen.getByRole('link', { name: 'Leave' })); expect(oldConfig.signal.aborted).toBe(true)
    fireEvent.click(screen.getByRole('link', { name: 'Return' })); await entry.visible('New visit')
    await act(async () => old.resolve(response(oldConfig, entry.body('Old visit'))))
    expect(screen.queryByText(/Old visit/)).not.toBeInTheDocument()
    expect(reads).toBe(2)
  })
  it.each([401, 403])('fails closed on current authority denial %s, then explicitly checks identity before reading again', async status => {
    let reads = 0
    apiClient.defaults.adapter = vi.fn(config => config.url === '/me'
      ? Promise.resolve(response(config, { role: 'admin', clerk_id: 'admin-a' }))
      : ++reads === 1 ? rejectResponse(config, status, status === 403 ? 'Admin access required' : 'Unauthorized') : Promise.resolve(response(config, entry.body('Restored records'))))
    mount(entry)
    fireEvent.click(await screen.findByRole('button', { name: 'Retry administrator access' }))
    await entry.visible('Restored records')
    expect(apiClient.defaults.adapter.mock.calls.map(([config]) => config.url)).toEqual([entry.endpoint, '/me', entry.endpoint])
  })
  it('recovers an ordinary outage using the captured same account', async () => {
    let reads = 0
    apiClient.defaults.adapter = vi.fn(config => ++reads === 1 ? rejectResponse(config, 503, 'Temporary outage') : Promise.resolve(response(config, entry.body('Recovered'))))
    mount(entry)
    fireEvent.click(await screen.findByRole('button', { name: entry.retry }))
    await entry.visible('Recovered')
    expect(apiClient.defaults.adapter.mock.calls.every(([config]) => config.authContext.sessionId === 'session-a')).toBe(true)
  })
})

describe('provider readiness captured mutations', () => {
  const entry = cases[0]
  const clickApprove = async () => fireEvent.click(await screen.findByRole('button', { name: 'Approve exact snapshot' }))
  it.each([401, 403])('purges evidence and actions on current decision authority denial %s', async status => {
    apiClient.defaults.adapter = vi.fn(config => config.method === 'get' ? Promise.resolve(response(config, entry.body('Private evidence')))
      : rejectResponse(config, status, status === 403 ? 'Admin access required' : 'Unauthorized'))
    mount(entry); await clickApprove()
    await screen.findByRole('button', { name: 'Retry administrator access' })
    expect(screen.queryByText(/Admin #7 submitted evidence/)).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Approve exact snapshot' })).not.toBeInTheDocument()
  })
  it.each([403, 503])('preserves a decision reason and retry control on business/network rejection %s', async status => {
    apiClient.defaults.adapter = vi.fn(config => config.method === 'get' ? Promise.resolve(response(config, entry.body('Private evidence')))
      : rejectResponse(config, status, status === 403 ? 'Independent administrator required' : 'Temporary outage'))
    mount(entry); await entry.visible('Private evidence')
    fireEvent.change(screen.getByLabelText('Decision reason (required for reject)'), { target: { value: 'Keep this reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Reject', exact: true }))
    await screen.findByRole('alert')
    expect(screen.getByLabelText('Decision reason (required for reject)')).toHaveValue('Keep this reason')
    expect(screen.getByRole('button', { name: 'Reject', exact: true })).toBeEnabled()
    expect(screen.queryByRole('button', { name: 'Retry administrator access' })).not.toBeInTheDocument()
  })
  it.each(['success', 'denial'])('ignores an old decision %s after the same actor changes session', async outcome => {
    const old = deferred(); let mutationConfig
    apiClient.defaults.adapter = vi.fn(config => config.method === 'post' ? (mutationConfig = config, old.promise)
      : Promise.resolve(response(config, entry.body(config.authContext.sessionId === 'session-a' ? 'Old evidence' : 'New evidence'))))
    mount(entry); await clickApprove(); await waitFor(() => expect(mutationConfig).toBeDefined())
    await act(async () => bind('session-b', () => Promise.resolve('token-b')))
    await entry.visible('New evidence')
    const before = apiClient.defaults.adapter.mock.calls.length
    await act(async () => outcome === 'success' ? old.resolve(response(mutationConfig, {}))
      : old.reject(new AxiosError('Denied', undefined, mutationConfig, null, { status: 403, data: { error: 'Admin access required' } })))
    expect(apiClient.defaults.adapter).toHaveBeenCalledTimes(before)
    expect(screen.getByRole('button', { name: 'Approve exact snapshot' })).toBeEnabled()
    expect(screen.queryByRole('button', { name: 'Retry administrator access' })).not.toBeInTheDocument()
  })
  it.each(['submit', 'revoke'])('pins the %s capability operation and its original payload to the current actor', async operation => {
    const item = { ...capability(), pending_submission: null, required_controls: ['policy_owner_approved'] }
    if (operation === 'revoke') item.latest_approval = { id: 92, active: true, evidence_reference: 'Current approval', expires_at: '2027-01-01T00:00:00Z' }
    apiClient.defaults.adapter = vi.fn(config => Promise.resolve(response(config, config.method === 'get' ? { capabilities: [item] } : {})))
    mount(entry); await screen.findByText('Email delivery')
    if (operation === 'submit') {
      fireEvent.change(screen.getByLabelText('Evidence reference'), { target: { value: 'restricted/test-evidence' } })
      fireEvent.change(screen.getByLabelText('SHA-256 evidence digest'), { target: { value: 'a'.repeat(64) } })
      fireEvent.click(screen.getByRole('checkbox'))
      fireEvent.click(screen.getByRole('button', { name: 'Submit evidence (can’t be edited later)' }))
    } else {
      fireEvent.change(screen.getByLabelText('Revocation reason'), { target: { value: 'Synthetic correction' } })
      fireEvent.click(screen.getByRole('button', { name: 'Revoke approval' }))
    }
    await waitFor(() => expect(apiClient.defaults.adapter.mock.calls.some(([config]) => config.method === 'post')).toBe(true))
    const config = apiClient.defaults.adapter.mock.calls.find(([request]) => request.method === 'post')[0]
    expect(config.url).toBe(operation === 'submit' ? '/admin/platform_capabilities/email_delivery/reviews' : '/admin/platform_capability_reviews/92/revoke')
    expect(config.authContext.sessionId).toBe('session-a')
    expect(config.headers.get('Authorization')).toBe('Bearer token-a')
    expect(config.signal).toBeInstanceOf(AbortSignal)
    expect(JSON.parse(config.data)).toMatchObject(operation === 'submit'
      ? { evidence_reference: 'restricted/test-evidence', evidence_digest: 'a'.repeat(64), controls: { policy_owner_approved: true } }
      : { reason: 'Synthetic correction' })
  })
  it('never transports a decision queued behind an old token after leaving the visit', async () => {
    const token = deferred(); let awaitToken = false; const getter = vi.fn(() => awaitToken ? token.promise : Promise.resolve('token-a')); bind('session-a', getter)
    apiClient.defaults.adapter = vi.fn(config => Promise.resolve(response(config, entry.body('Current evidence'))))
    render(<MemoryRouter initialEntries={[entry.route]}><Link to="/events">Leave</Link><ProviderReadinessPage /></MemoryRouter>)
    await entry.visible('Current evidence'); awaitToken = true; await clickApprove()
    await waitFor(() => expect(getter).toHaveBeenCalledTimes(2))
    fireEvent.click(screen.getByRole('link', { name: 'Leave' }))
    await act(async () => token.resolve('token-a'))
    expect(apiClient.defaults.adapter).toHaveBeenCalledTimes(1)
    expect(screen.queryByText(/Current evidence/)).not.toBeInTheDocument()
  })
})
