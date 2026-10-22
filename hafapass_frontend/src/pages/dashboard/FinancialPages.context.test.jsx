import { StrictMode } from 'react'
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Link, MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../../api/client'
import SettingsPage from './SettingsPage'
import AttendeesPage from './AttendeesPage'
import EventAnalyticsPage from './EventAnalyticsPage'
import BoxOfficePage from './BoxOfficePage'
import RefundsPage from './RefundsPage'

vi.mock('../../api/client', async original => ({ ...(await original()), default: { get: vi.fn(), post: vi.fn(), patch: vi.fn(), delete: vi.fn() } }))
// The parent owns these records. A scoped navigation header cannot protect them.
vi.mock('../../components/EventWorkspace', () => ({ default: ({ children }) => <div>{children}</div> }))
vi.mock('../../hooks/useLaunchCapabilities', () => ({ default: () => ({}) }))
vi.mock('../../components/QRCode', () => ({ default: () => <p>Private door QR</p> }))
vi.mock('../../components/SeatSelector', () => ({ default: () => null }))
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no }); return { promise, resolve, reject } }
const permissions = { box_office: true, refund: true, manage_finance: true, payout: true, view_attendees: true, view_finance: true }
const event = id => ({ id: Number(id), organization_id: 1, title: `Event ${id}`, timezone: 'Pacific/Guam', status: 'completed', ticket_types: [{ id: Number(id), name: `Entry ${id}`, quantity_available: 20, quantity_sold: 0, price_cents: 500 }], permissions })
const order = id => ({ id: Number(id) * 10, buyer_name: `Buyer ${id}`, buyer_email: `buyer${id}@example.invalid`, total_cents: 500, refundable_cents: 500, ticket_count: 1 })
const finance = { preview: {}, settlements: [{ id: 1, available_to_payout_cents: 500, status: 'finalized' }], connected_account: { payout_ready: true }, payouts: [] }
const binders = []
function bind(owner = 'actor-a', sessionId = 'session-a') {
  window.localStorage.setItem('hafapass_scanner_user_id', owner)
  binders.push(setAuthTokenGetter(() => Promise.resolve('synthetic-token'), { userId: owner, sessionId, ready: true }))
}
function selectOrganization(id) {
  window.localStorage.setItem('hafapass_organization_id', String(id))
  window.dispatchEvent(new StorageEvent('storage', { key: 'hafapass_organization_id' }))
}
function fixtures(url, config) {
  const id = url.match(/events\/(\d+)/)?.[1] || '37'
  const org = config?.organizationId || '1'
  if (url === '/organizer/organization') return { id: Number(org), name: `Organization ${org}`, role: 'owner' }
  if (url === '/organizer/memberships' || url === '/organizer/connected_accounts') return []
  if (url.includes('/attendees')) return { attendees: [{ id: Number(id), attendee_name: `Attendee ${id}`, attendee_email: 'synthetic@example.invalid', status: 'issued', ticket_type: 'Entry' }], meta: { total_pages: 1 } }
  if (url.endsWith('/orders')) return { orders: [order(id)] }
  if (url.endsWith('/stats')) return { recent_orders: [order(id)], tickets_by_type: [], total_tickets_sold: 1, tickets_checked_in: 0 }
  if (url.endsWith('/finance')) return finance
  if (url.endsWith('/summary')) return {}
  if (url.includes('card_present')) return { status: 'unavailable', payment_ready: false }
  return event(id)
}
function mount(Page, tool) {
  return render(<MemoryRouter initialEntries={[`/dashboard/events/37/${tool}`]}>
    <Link to={`/dashboard/events/38/${tool}`}>Open Beta</Link><Link to={`/dashboard/events/37/${tool}`}>Open Alpha</Link>
    <Routes><Route path={`/dashboard/events/:id/${tool}`} element={<Page />} /></Routes>
  </MemoryRouter>)
}
beforeEach(() => {
  vi.clearAllMocks(); window.localStorage.clear(); window.sessionStorage.clear()
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '')
  vi.stubEnv('VITE_SUPPORT_EMAIL', 'operator@example.test')
  window.localStorage.setItem('hafapass_organization_id', '1'); bind()
  apiClient.get.mockImplementation((url, config) => Promise.resolve({ data: fixtures(url, config) }))
})
afterEach(() => { binders.splice(0).forEach(clear => clear()); vi.unstubAllGlobals(); vi.unstubAllEnvs(); vi.restoreAllMocks() })

describe('organization settings authority', () => {
  it.each(['success', 'error'])('does not expose an Alpha invitation %s after organization replacement', async outcome => {
    const old = deferred()
    apiClient.post.mockReturnValueOnce(old.promise)
    render(<MemoryRouter initialEntries={['/dashboard/settings']}><SettingsPage /></MemoryRouter>)
    await screen.findByText('Organization 1')
    await userEvent.type(screen.getByLabelText('Teammate email'), 'guest@example.invalid')
    await userEvent.click(screen.getByRole('button', { name: 'Invite', exact: true }))
    expect(apiClient.post.mock.calls[0][2]).toMatchObject({ organizationId: '1', authContext: { userId: 'actor-a' } })
    await act(async () => selectOrganization(2))
    await screen.findByText('Organization 2')
    await act(async () => outcome === 'success' ? old.resolve({ data: { invitation_token: 'old-private-token', id: 1 } }) : old.reject(new Error('Old invite failure')))
    expect(screen.queryByLabelText('Invitation link')).not.toBeInTheDocument()
    expect(screen.queryByText('Could not create invitation.')).not.toBeInTheDocument()
    apiClient.post.mockResolvedValueOnce({ data: { invitation_token: 'current-token', id: 2 } })
    await userEvent.type(screen.getByLabelText('Teammate email'), 'new@example.invalid')
    await userEvent.click(screen.getByRole('button', { name: 'Invite', exact: true }))
    await screen.findByLabelText('Invitation link')
    expect(apiClient.post.mock.calls[1][2].organizationId).toBe('2')
  })
})

it('blocks an old settings mutation before transport when token acquisition outlives organization selection', async () => {
  const actual = await vi.importActual('../../api/client')
  const token = deferred()
  const getter = vi.fn(() => token.promise)
  binders.push(setAuthTokenGetter(getter, { userId: 'actor-a', sessionId: 'slow-token', ready: true }))
  const adapter = vi.fn(async config => ({ config, data: { invitation_token: 'must-not-send' }, status: 200, statusText: 'OK', headers: {} }))
  const previousAdapter = actual.default.defaults.adapter
  actual.default.defaults.adapter = adapter
  apiClient.post.mockImplementation((...args) => actual.default.post(...args))
  try {
    render(<MemoryRouter initialEntries={['/dashboard/settings']}><SettingsPage /></MemoryRouter>)
    await screen.findByText('Organization 1')
    await userEvent.type(screen.getByLabelText('Teammate email'), 'guest@example.invalid')
    await userEvent.click(screen.getByRole('button', { name: 'Invite', exact: true }))
    await waitFor(() => expect(getter).toHaveBeenCalled())
    await act(async () => selectOrganization(2))
    await screen.findByText('Organization 2')
    await act(async () => token.resolve('synthetic-delayed-token'))
    expect(adapter).not.toHaveBeenCalled()
    expect(screen.queryByLabelText('Invitation link')).not.toBeInTheDocument()
  } finally { actual.default.defaults.adapter = previousAdapter }
})

describe('private event records', () => {
  it.each([[AttendeesPage, 'attendees', 'Attendee'], [EventAnalyticsPage, 'analytics', 'Buyer']])('rejects old %s records after route replacement', async (Page, tool, noun) => {
    const old = deferred()
    const suffix = tool === 'attendees' ? '/attendees' : '/stats'
    apiClient.get.mockImplementation((url, config) => url.includes('/events/37') && url.includes(suffix)
      ? old.promise : Promise.resolve({ data: fixtures(url, config) }))
    mount(Page, tool)
    await userEvent.click(screen.getByRole('link', { name: 'Open Beta' }))
    await screen.findAllByText(`${noun} 38`)
    await act(async () => old.resolve({ data: fixtures(`/organizer/events/37${suffix}`) }))
    expect(screen.queryByText(`${noun} 37`)).not.toBeInTheDocument()
    expect(screen.getAllByText(`${noun} 38`).length).toBeGreaterThan(0)
  })
  it('keeps a newer attendee search when an earlier query finishes last', async () => {
    const old = deferred()
    apiClient.get.mockImplementation((url, config) => url.includes('search=old') ? old.promise : Promise.resolve({ data: fixtures(url, config) }))
    mount(AttendeesPage, 'attendees')
    await screen.findAllByText('Attendee 37')
    await act(async () => fireEvent.change(screen.getByPlaceholderText('Search name, email or order #...'), { target: { value: 'old' } }))
    await act(async () => fireEvent.change(screen.getByPlaceholderText('Search name, email or order #...'), { target: { value: 'new' } }))
    await screen.findAllByText('Attendee 37')
    await act(async () => old.resolve({ data: { attendees: [{ id: 9, attendee_name: 'Old private result', status: 'issued' }] } }))
    expect(screen.queryByText('Old private result')).not.toBeInTheDocument()
  })
  it('keeps finance readers away from mutation and attendee tools', async () => {
    apiClient.get.mockImplementation((url, config) => Promise.resolve({ data: url === '/organizer/events/37' ? { ...event(37), permissions: { view_finance: true } } : fixtures(url, config) }))
    mount(EventAnalyticsPage, 'analytics')
    await screen.findByText('Event 37')
    expect(screen.queryByRole('button', { name: /Finalize/ })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /^Pay / })).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'View attendee list' })).not.toBeInTheDocument()
  })
})

it('recovers attendee outages with the current filters without declaring the list empty', async () => {
  let failing = true
  apiClient.get.mockImplementation((url, config) => url.includes('/attendees') && failing ? Promise.reject(new Error('Synthetic outage')) : Promise.resolve({ data: fixtures(url, config) }))
  mount(AttendeesPage, 'attendees')
  await screen.findByRole('alert')
  await act(async () => fireEvent.change(screen.getByPlaceholderText('Search name, email or order #...'), { target: { value: 'guests' } }))
  await screen.findByRole('alert')
  expect(screen.queryByText('No attendees match these filters.')).not.toBeInTheDocument()
  failing = false
  await userEvent.click(screen.getByRole('button', { name: 'Retry attendee list' }))
  await screen.findAllByText('Attendee 37')
  expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  expect(screen.getByPlaceholderText('Search name, email or order #...')).toHaveValue('guests')
  expect(apiClient.get.mock.calls.filter(([url]) => url.includes('/attendees')).at(-1)[0]).toContain('search=guests')
})

it('does not refresh Alpha finances after an old finalization resolves on Beta', async () => {
  const old = deferred()
  apiClient.post.mockReturnValueOnce(old.promise)
  mount(EventAnalyticsPage, 'analytics')
  await userEvent.click(await screen.findByRole('button', { name: 'Finalize current version' }))
  expect(apiClient.post.mock.calls[0][2]).toMatchObject({ organizationId: '1', authContext: { userId: 'actor-a' } })
  const initialFinanceReads = apiClient.get.mock.calls.filter(([url]) => url === '/organizer/events/37/finance').length
  await userEvent.click(screen.getByRole('link', { name: 'Open Beta' }))
  await screen.findByText('Event 38')
  await act(async () => old.resolve({ data: { status: 'finalized' } }))
  expect(apiClient.get.mock.calls.filter(([url]) => url === '/organizer/events/37/finance')).toHaveLength(initialFinanceReads)
  expect(screen.getByText('Event 38')).toBeInTheDocument()
})

for (const [Page, tool] of [[AttendeesPage, 'attendees'], [EventAnalyticsPage, 'analytics'], [BoxOfficePage, 'box-office'], [RefundsPage, 'refunds']]) {
  it.each(['organization', 'account', 'session'])(`${tool} rejects stale records after %s replacement`, async replacement => {
    const old = deferred()
    let oldScope = true
    apiClient.get.mockImplementation((url, config) => oldScope ? old.promise : config?.organizationId === '2' ? Promise.reject({ response: { status: 403 } }) : Promise.resolve({ data: fixtures(url, config) }))
    mount(Page, tool)
    oldScope = false
    await act(async () => replacement === 'organization' ? selectOrganization(2)
      : bind(replacement === 'account' ? 'actor-b' : 'actor-a', 'session-b'))
    const expected = tool === 'attendees' ? 'Attendee 37' : tool === 'box-office' ? 'Event 37' : tool === 'analytics' ? 'Buyer 37' : /Order #370/
    const currentText = replacement === 'organization' ? tool === 'refunds' ? /Your refund access changed/ : tool === 'box-office' ? 'Failed to load event.' : tool === 'analytics' ? /Your event access changed/ : /Your attendee access changed/ : expected
    await screen.findAllByText(currentText)
    await act(async () => old.resolve({ data: { ...event(37), title: 'Old private context', recent_orders: [], attendees: [], preview: {} } }))
    expect(screen.queryByText('Old private context')).not.toBeInTheDocument()
    expect(screen.getAllByText(currentText).length).toBeGreaterThan(0)
  })
}

for (const [Page, tool, kind] of [[BoxOfficePage, 'box-office', 'box-office'], [RefundsPage, 'refunds', 'refund']]) {
  it.each(['success', 'error'])(`${kind} preserves the original uncertain operation across a route change and late %s`, async outcome => {
    const old = deferred()
    const saved = kind === 'box-office' ? { key: 'original-sale', payload: { line_items: [{ ticket_type_id: 37, quantity: 1 }], payment_method: 'door_cash' }, total_cents: 500 }
      : { key: 'original-refund', orderId: 370, payload: { reason: 'Saved reason' } }
    const key = `hafapass:pending-${kind}:actor-a:37`
    window.sessionStorage.setItem(key, JSON.stringify(saved))
    apiClient.post.mockReturnValueOnce(old.promise)
    mount(Page, tool)
    const retry = await screen.findByRole('button', { name: kind === 'box-office' ? /Retry saved sale/ : 'Retry saved refund' })
    await userEvent.click(retry)
    expect(apiClient.post.mock.calls[0][2]).toMatchObject({ organizationId: '1', headers: { 'Idempotency-Key': saved.key } })
    await userEvent.click(screen.getByRole('link', { name: 'Open Beta' }))
    if (kind === 'box-office') await screen.findByText('Event 38')
    else await screen.findByText(/Order #380/)
    await act(async () => outcome === 'success' ? old.resolve({ data: { id: 370, status: 'succeeded', tickets: [] } }) : old.reject(new Error('Old uncertain failure')))
    expect(JSON.parse(window.sessionStorage.getItem(key))).toEqual(saved)
    expect(window.sessionStorage.getItem(`hafapass:pending-${kind}:v2:actor-a:1:38`)).toBeNull()
    expect(screen.queryByText('Private door QR')).not.toBeInTheDocument()
    expect(screen.queryByText('Refund confirmed by the payment provider.')).not.toBeInTheDocument()
    await userEvent.click(screen.getByRole('link', { name: 'Open Alpha' }))
    await screen.findByRole('button', { name: kind === 'box-office' ? /Retry saved sale/ : 'Retry saved refund' })
  })
}

for (const [Page, tool, kind] of [[BoxOfficePage, 'box-office', 'box-office'], [RefundsPage, 'refunds', 'refund']]) {
  it(`${kind} never imports or retries an Alpha legacy operation under Beta organization`, async () => {
    const saved = kind === 'box-office' ? { key: 'legacy-alpha-sale', payload: { line_items: [{ ticket_type_id: 37, quantity: 1 }], payment_method: 'door_cash', buyer_name: 'Private Alpha buyer' }, total_cents: 500 }
      : { key: 'legacy-alpha-refund', orderId: 370, payload: { reason: 'Private Alpha reason' } }
    const legacyKey = `hafapass:pending-${kind}:actor-a:37`
    const alphaKey = `hafapass:pending-${kind}:v2:actor-a:1:37`
    window.sessionStorage.setItem(legacyKey, JSON.stringify(saved))
    apiClient.get.mockImplementation((url, config) => config?.organizationId === '2' ? Promise.reject({ response: { status: 403 } }) : Promise.resolve({ data: fixtures(url, config) }))
    mount(Page, tool)
    await screen.findByRole('button', { name: kind === 'box-office' ? /Retry saved sale/ : 'Retry saved refund' })
    expect(JSON.parse(window.sessionStorage.getItem(alphaKey))).toEqual(saved)
    await act(async () => selectOrganization(2))
    await screen.findByRole('alert')
    expect(screen.queryByRole('button', { name: /Retry saved (sale|refund)/ })).not.toBeInTheDocument()
    expect(screen.queryByText(/Private Alpha/)).not.toBeInTheDocument()
    expect(window.sessionStorage.getItem(`hafapass:pending-${kind}:v2:actor-a:2:37`)).toBeNull()
    expect(JSON.parse(window.sessionStorage.getItem(legacyKey))).toEqual(saved)
    expect(apiClient.post).not.toHaveBeenCalled()
    await act(async () => selectOrganization(1))
    apiClient.post.mockResolvedValueOnce({ data: { id: 370, status: 'pending', tickets: [] } })
    await userEvent.click(await screen.findByRole('button', { name: kind === 'box-office' ? /Retry saved sale/ : 'Retry saved refund' }))
    expect(apiClient.post.mock.calls[0]).toEqual([expect.stringContaining('/events/37/'), saved.payload, expect.objectContaining({ organizationId: '1', headers: { 'Idempotency-Key': saved.key } })])
  })
}

it('retains a failed event-detail load alongside a successful attendee list until retry', async () => {
  let fail = true
  apiClient.get.mockImplementation((url, config) => url === '/organizer/events/37' && fail ? Promise.reject(new Error('Synthetic detail outage')) : Promise.resolve({ data: fixtures(url, config) }))
  mount(AttendeesPage, 'attendees')
  await screen.findAllByText('Attendee 37')
  expect(await screen.findByRole('alert')).toHaveTextContent('Failed to load event details.')
  fail = false
  await userEvent.click(screen.getByRole('button', { name: 'Retry attendee list' }))
  await waitFor(() => expect(screen.queryByRole('alert')).not.toBeInTheDocument())
})

it('keeps the newer organization snapshot when StrictMode initial loading is repeated', async () => {
  const old = deferred()
  let organizationLoads = 0
  apiClient.get.mockImplementation((url, config) => url === '/organizer/organization' && ++organizationLoads === 1 ? old.promise : Promise.resolve({ data: fixtures(url, config) }))
  render(<StrictMode><MemoryRouter initialEntries={['/dashboard/settings']}><SettingsPage /></MemoryRouter></StrictMode>)
  await screen.findByText('Organization 1')
  await act(async () => old.resolve({ data: { id: 1, name: 'Old organization snapshot', role: 'owner' } }))
  expect(screen.queryByText('Old organization snapshot')).not.toBeInTheDocument()
  expect(screen.getByText('Organization 1')).toBeInTheDocument()
})

it('retains a saved sale when access refusal cannot confirm the earlier payment outcome', async () => {
  const saved = { key: 'original-saved-sale', payload: { line_items: [{ ticket_type_id: 37, quantity: 1 }], payment_method: 'door_cash' }, total_cents: 500 }
  const key = 'hafapass:pending-box-office:v2:actor-a:1:37'
  window.sessionStorage.setItem(key, JSON.stringify(saved))
  apiClient.post.mockRejectedValue({ response: { status: 403, data: { error: 'Access revoked' } } })
  mount(BoxOfficePage, 'box-office')
  await userEvent.click(await screen.findByRole('button', { name: /Retry saved sale/ }))
  await screen.findByText('Access revoked')
  expect(JSON.parse(window.sessionStorage.getItem(key))).toEqual(saved)
  expect(screen.getByRole('button', { name: 'Cash', exact: true })).toBeDisabled()
  expect(screen.getByRole('button', { name: /Retry saved sale/ })).toBeInTheDocument()
})

for (const [Page, tool, kind] of [[BoxOfficePage, 'box-office', 'box-office'], [RefundsPage, 'refunds', 'refund']]) {
  it(`${kind} does not expose a saved operation after the effective permission is withdrawn`, async () => {
    const saved = kind === 'box-office' ? { key: 'private-saved-sale', payload: { line_items: [{ ticket_type_id: 37, quantity: 1 }], payment_method: 'door_cash', buyer_name: 'Protected buyer' }, total_cents: 500 }
      : { key: 'private-saved-refund', orderId: 370, payload: { reason: 'Protected reason' } }
    const key = `hafapass:pending-${kind}:v2:actor-a:1:37`
    window.sessionStorage.setItem(key, JSON.stringify(saved))
    apiClient.get.mockImplementation((url, config) => Promise.resolve({ data: url === '/organizer/events/37' ? { ...event(37), permissions: { view_events: true } } : fixtures(url, config) }))
    mount(Page, tool)
    await screen.findByRole('alert')
    expect(screen.queryByRole('button', { name: /Retry saved (sale|refund)/ })).not.toBeInTheDocument()
    expect(JSON.parse(window.sessionStorage.getItem(key))).toEqual(saved)
    expect(apiClient.post).not.toHaveBeenCalled()
  })
}

for (const [Page, tool, kind] of [[BoxOfficePage, 'box-office', 'box-office'], [RefundsPage, 'refunds', 'refund']]) {
  const invalid = ['{broken', 'null', 'false', '0', '{}', JSON.stringify({ key: 'existing-key', payload: {} })]
  it.each(invalid)(`${kind} preserves an invalid v2 journal %s without sending or replacing a money request`, async raw => {
    const key = `hafapass:pending-${kind}:v2:actor-a:1:37`
    window.sessionStorage.setItem(key, raw)
    mount(Page, tool)
    expect(await screen.findByRole('alert')).toHaveTextContent('Money actions are paused')
    expect(screen.getByRole('link', { name: 'Contact support', exact: true })).toHaveAttribute('href', expect.stringMatching(/^mailto:/))
    if (kind === 'box-office') {
      expect(screen.getByRole('button', { name: 'Add Entry 37' })).toBeDisabled()
      const retry = screen.getByRole('button', { name: /Retry saved sale/ })
      expect(retry).toBeDisabled(); await userEvent.click(retry)
    } else {
      expect(screen.getByRole('button', { name: 'Refund', exact: true })).toBeDisabled()
      expect(screen.queryByRole('button', { name: 'Retry saved refund' })).not.toBeInTheDocument()
    }
    expect(apiClient.post).not.toHaveBeenCalled()
    expect(window.sessionStorage.getItem(key)).toBe(raw)
  })
  it(`${kind} does not import an invalid legacy journal or start a new operation`, async () => {
    const legacy = `hafapass:pending-${kind}:actor-a:37`
    const current = `hafapass:pending-${kind}:v2:actor-a:1:37`
    window.sessionStorage.setItem(legacy, '{broken')
    mount(Page, tool)
    expect(await screen.findByRole('alert')).toHaveTextContent('Money actions are paused')
    expect(window.sessionStorage.getItem(legacy)).toBe('{broken')
    expect(window.sessionStorage.getItem(current)).toBeNull()
    expect(apiClient.post).not.toHaveBeenCalled()
  })
  it(`${kind} fails closed when its recovery storage cannot be read`, async () => {
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(function (key) {
      if (key.startsWith(`hafapass:pending-${kind}`)) throw new Error('Synthetic storage refusal')
      return key === 'hafapass_organization_id' ? '1' : key === 'hafapass_scanner_user_id' ? 'actor-a' : null
    })
    mount(Page, tool)
    expect(await screen.findByRole('alert')).toHaveTextContent('Money actions are paused')
    expect(apiClient.post).not.toHaveBeenCalled()
  })
  it(`${kind} keeps a valid legacy operation paused if migration cannot be persisted`, async () => {
    const saved = kind === 'box-office' ? { key: 'original-key', payload: { line_items: [{ ticket_type_id: 37, quantity: 1 }], payment_method: 'door_cash' }, total_cents: 500 }
      : { key: 'original-key', orderId: 370, payload: { reason: 'Original reason' } }
    const legacy = `hafapass:pending-${kind}:actor-a:37`
    const current = `hafapass:pending-${kind}:v2:actor-a:1:37`
    window.sessionStorage.setItem(legacy, JSON.stringify(saved))
    const originalSet = Storage.prototype.setItem
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(function (key, value) {
      if (key === current) throw new Error('Synthetic migration failure')
      return originalSet.call(this, key, value)
    })
    mount(Page, tool)
    expect(await screen.findByRole('alert')).toHaveTextContent('Money actions are paused')
    expect(JSON.parse(window.sessionStorage.getItem(legacy))).toEqual(saved)
    expect(window.sessionStorage.getItem(current)).toBeNull()
    expect(apiClient.post).not.toHaveBeenCalled()
  })
}

describe('attendee list totals and export', () => {
  it('shows blob API errors and a useful door-list rate-limit message', async () => {
    apiClient.post.mockImplementation(url => url.endsWith('/sales_exports')
      ? Promise.reject({ response: { status: 422,
        data: new Blob([JSON.stringify({ error: 'Invalid export columns' })], { type: 'application/json' }) } })
      : Promise.resolve({ data: {} }))
    apiClient.get.mockImplementation((url, config) => url.includes('/sales_exports/door_list?')
      ? Promise.reject({ response: { status: 429, data: new Blob(['{}']) } })
      : Promise.resolve({ data: fixtures(url, config) }))
    mount(AttendeesPage, 'attendees')
    await screen.findAllByText('Attendee 37')
    await userEvent.click(screen.getByRole('button', { name: 'Export this list' }))
    await userEvent.click(screen.getByRole('button', { name: 'Download CSV' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Invalid export columns')
    await userEvent.click(screen.getByRole('button', { name: 'Print door list' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Try again later')
  })

  it('shows the API total count and notes when filters narrow it', async () => {
    apiClient.get.mockImplementation((url, config) => Promise.resolve({ data: url.includes('/attendees?')
      ? { attendees: [{ id: 1, attendee_name: 'Attendee one', status: 'issued', ticket_type: 'Entry' }], meta: { total_pages: 1, total_count: url.includes('status=checked_in') ? 1 : 17 } }
      : fixtures(url, config) }))
    mount(AttendeesPage, 'attendees')
    expect(await screen.findByText('17 attendees')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Filters & sort' }))
    fireEvent.change(screen.getByLabelText('Filter attendees by status'), { target: { value: 'checked_in' } })
    expect(await screen.findByText('1 attendee match these filters')).toBeInTheDocument()
  })

  it('downloads the API attendee CSV export with scoped ownership', async () => {
    const blob = new Blob(['name,email\n'], { type: 'text/csv' })
    const createObjectURL = vi.fn(() => 'blob:attendees'); const revokeObjectURL = vi.fn()
    vi.stubGlobal('URL', class extends URL { static createObjectURL = createObjectURL; static revokeObjectURL = revokeObjectURL })
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
    apiClient.get.mockImplementation((url, config) => Promise.resolve({ data: fixtures(url, config) }))
    apiClient.post.mockResolvedValue({ data: blob, status: 200 })
    mount(AttendeesPage, 'attendees')
    await screen.findAllByText('Attendee 37')
    await userEvent.click(screen.getByRole('button', { name: 'Export this list' }))
    await userEvent.click(screen.getByRole('button', { name: 'Download CSV' }))
    await waitFor(() => expect(click).toHaveBeenCalledTimes(1))
    const call = apiClient.post.mock.calls.find(([url]) => url === '/organizer/events/37/sales_exports')
    expect(call[2]).toMatchObject({ responseType: 'blob', organizationId: '1', authContext: { userId: 'actor-a' } })
    expect(createObjectURL).toHaveBeenCalledWith(blob)
    expect(revokeObjectURL).toHaveBeenCalledWith('blob:attendees')
  })

  it('keeps a pending export alive across a filter change but cancels it when access is withdrawn', async () => {
    const blob = new Blob(['name,email\n'], { type: 'text/csv' })
    vi.stubGlobal('URL', class extends URL { static createObjectURL = vi.fn(() => 'blob:attendees'); static revokeObjectURL = vi.fn() })
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
    let exportRead = deferred()
    let denyList = false
    apiClient.post.mockImplementation(url => url.endsWith('/sales_exports') ? exportRead.promise : Promise.resolve({ data: {} }))
    apiClient.get.mockImplementation((url, config) => denyList && url.includes('/attendees?') ? Promise.reject({ response: { status: 403 } })
      : Promise.resolve({ data: fixtures(url, config) }))
    mount(AttendeesPage, 'attendees')
    await screen.findAllByText('Attendee 37')
    await userEvent.click(screen.getByRole('button', { name: 'Export this list' }))
    await userEvent.click(screen.getByRole('button', { name: 'Download CSV' }))
    fireEvent.change(screen.getByPlaceholderText('Search name, email or order #...'), { target: { value: 'checked' } })
    await waitFor(() => expect(apiClient.get.mock.calls.some(([url]) => url.includes('search=checked'))).toBe(true))
    await screen.findAllByText('Attendee 37')
    const firstExport = apiClient.post.mock.calls.filter(([url]) => url.endsWith('/sales_exports'))[0][2]
    expect(firstExport.signal.aborted).toBe(false)
    await act(async () => exportRead.resolve({ data: blob, status: 200 }))
    await waitFor(() => expect(click).toHaveBeenCalledTimes(1))

    exportRead = deferred()
    await userEvent.click(screen.getByRole('button', { name: 'Export this list' }))
    await userEvent.click(screen.getByRole('button', { name: 'Download CSV' }))
    const secondExport = apiClient.post.mock.calls.filter(([url]) => url.endsWith('/sales_exports'))[1][2]
    denyList = true
    fireEvent.change(screen.getByPlaceholderText('Search name, email or order #...'), { target: { value: 'issued' } })
    expect(await screen.findByRole('alert')).toHaveTextContent('Your attendee access changed')
    expect(secondExport.signal.aborted).toBe(true)
    await act(async () => exportRead.resolve({ data: blob, status: 200 }))
    expect(click).toHaveBeenCalledTimes(1)
  })
})
