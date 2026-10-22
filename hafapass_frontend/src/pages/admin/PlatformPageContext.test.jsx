import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { Link, MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../../api/client'
import AdminUsersPage from './AdminUsersPage'
import AdminOrdersPage from './AdminOrdersPage'
import AdminEventsPage from './AdminEventsPage'
import SupportPage from '../support/SupportPage'

vi.mock('../../api/client', async original => ({ ...await original(), default: { get: vi.fn(), patch: vi.fn(), post: vi.fn() } }))
vi.mock('./AdminLayout', () => ({ default: ({ children }) => <div>{children}</div> }))
vi.mock('../../components/PilotReadinessReviewDialog', () => ({ default: () => null }))
vi.mock('../../components/PilotValidationReviewDialog', () => ({ default: () => null }))
vi.mock('../../components/EventDayRehearsalReviewDialog', () => ({ default: () => null }))
vi.mock('../../components/LiveMoneyProofReviewDialog', () => ({ default: () => null }))
vi.mock('../../components/LivePilotOperationsDialog', () => ({ default: () => null }))
vi.mock('../../components/PilotCloseoutDialog', () => ({ default: () => null }))
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done }); return { promise, resolve } }
let clearAuth
beforeEach(() => { vi.clearAllMocks(); localStorage.clear(); setAuthTokenGetter(null)(); clearAuth = () => {} })
afterEach(() => { cleanup(); clearAuth(); vi.restoreAllMocks() })
const cases = [
  [AdminUsersPage, '/admin/users', 'Search users by name or email', name => ({ users: [{ id: 3, email: `${name}@example.invalid`, first_name: name, last_name: '', role: 'attendee', created_at: '2026-01-01', orders_count: 0 }], meta: {} })],
  [AdminOrdersPage, '/admin/orders', 'Search orders by order number, buyer name or email', name => ({ orders: [{ id: 3, buyer_name: name, buyer_email: `${name}@example.invalid`, status: 'completed', tickets: [], created_at: '2026-01-01', net_cents: 0 }], meta: {} })],
  [AdminEventsPage, '/admin/events', 'Search events...', name => ({ events: [{ id: 3, title: name, status: 'draft', category: 'other', tickets_sold: 0, revenue_cents: 0 }], meta: {} })],
]
const searchControl = label => label.endsWith('...') ? screen.getByPlaceholderText(label) : screen.getByRole('textbox', { name: label })
describe('platform list isolation and recovery', () => {
  for (const [Page, path, label, records] of cases) {
    it(`${path} keeps the newer filter when the earlier response finishes last`, async () => {
      const old = deferred()
      apiClient.get.mockImplementation((url, config) => config.params.search ? Promise.resolve({ data: records('Current') }) : old.promise)
      render(<MemoryRouter initialEntries={[path]}><Page /></MemoryRouter>)
      await waitFor(() => expect(apiClient.get).toHaveBeenCalled())
      const oldConfig = apiClient.get.mock.calls[0][1]
      fireEvent.change(searchControl(label), { target: { value: 'Current' } })
      expect((await screen.findAllByText('Current')).length).toBeGreaterThan(0)
      await act(async () => old.resolve({ data: records('Old') }))
      expect(screen.queryByText('Old')).not.toBeInTheDocument()
      expect(oldConfig.signal.aborted).toBe(true)
    })
    it(`${path} offers a read retry with the same filters instead of a false empty result`, async () => {
      apiClient.get.mockResolvedValueOnce({ data: records('Initial') }).mockRejectedValueOnce(new Error('outage')).mockResolvedValue({ data: records('Recovered') })
      render(<MemoryRouter initialEntries={[path]}><Page /></MemoryRouter>)
      await screen.findAllByText('Initial')
      fireEvent.change(searchControl(label), { target: { value: 'kept' } })
      expect(await screen.findByRole('alert')).toHaveTextContent('Your filters have been kept')
      expect(screen.queryByText(/^No .* found/)).not.toBeInTheDocument()
      fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
      await screen.findAllByText('Recovered')
      expect(searchControl(label)).toHaveValue('kept')
      expect(apiClient.get.mock.calls.at(-1)[1].params.search).toBe('kept')
    })
    it(`${path} clears records and fences old callbacks when the same account changes sessions`, async () => {
      clearAuth = setAuthTokenGetter(() => Promise.resolve('synthetic-a'), { userId: 'same-user', sessionId: 'a', ready: true })
      const old = deferred()
      apiClient.get.mockImplementation((url, config) => config.authContext.sessionId === 'a' ? old.promise : Promise.resolve({ data: records('Session B') }))
      render(<MemoryRouter initialEntries={[path]}><Page /></MemoryRouter>)
      await waitFor(() => expect(apiClient.get).toHaveBeenCalled())
      await act(async () => { clearAuth = setAuthTokenGetter(() => Promise.resolve('synthetic-b'), { userId: 'same-user', sessionId: 'b', ready: true }) })
      await screen.findAllByText('Session B')
      await act(async () => old.resolve({ data: records('Session A') }))
      expect(screen.queryByText('Session A')).not.toBeInTheDocument()
      expect(apiClient.get.mock.calls[0][1].signal.aborted).toBe(true)
    })
  }
  it('withdraws an exiting platform page instead of starting reads for the next route', async () => {
    apiClient.get.mockResolvedValue({ data: cases[0][3]('Visible') })
    render(<MemoryRouter initialEntries={['/admin/users']}><Routes><Route path="*" element={<><Link to="/admin/orders">Leave users</Link><Link to="/admin/users">Return users</Link><AdminUsersPage /></>} /></Routes></MemoryRouter>)
    await screen.findAllByText('Visible')
    const before = apiClient.get.mock.calls.length
    fireEvent.click(screen.getByRole('link', { name: 'Leave users' }))
    expect(screen.queryByRole('textbox', { name: 'Search users by name or email' })).not.toBeInTheDocument()
    expect(apiClient.get).toHaveBeenCalledTimes(before)
    fireEvent.click(screen.getByRole('link', { name: 'Return users' }))
    await screen.findAllByText('Visible')
    expect(apiClient.get).toHaveBeenCalledTimes(before + 1)
  })
  it('does not apply a received role update to a replacement admin session', async () => {
    clearAuth = setAuthTokenGetter(() => Promise.resolve('a'), { userId: 'same-user', sessionId: 'a', ready: true })
    apiClient.get.mockResolvedValue({ data: cases[0][3]('Visible') })
    const update = deferred(); apiClient.patch.mockReturnValue(update.promise)
    render(<MemoryRouter initialEntries={['/admin/users']}><AdminUsersPage /></MemoryRouter>)
    await screen.findAllByText('Visible')
    fireEvent.change(screen.getAllByRole('combobox', { name: 'Role for Visible@example.invalid' })[0], { target: { value: 'support' } })
    fireEvent.click(screen.getByRole('button', { name: 'Change role' }))
    expect(apiClient.patch.mock.calls[0][2].authContext.sessionId).toBe('a')
    await act(async () => { clearAuth = setAuthTokenGetter(() => Promise.resolve('b'), { userId: 'same-user', sessionId: 'b', ready: true }) })
    await screen.findAllByText('Visible')
    await act(async () => update.resolve({ data: { ...cases[0][3]('Visible').users[0], role: 'support' } }))
    // Attendee and organizer both show as "No staff access" (value "member").
    for (const control of screen.getAllByRole('combobox', { name: 'Role for Visible@example.invalid' })) expect(control).toHaveValue('member')
  })
  it('order disclosure works with a named focusable button', async () => {
    apiClient.get.mockResolvedValue({ data: { orders: [{ ...cases[1][3]('Buyer').orders[0], order_items: [], payments: [], refunds: [], reconciliation_exceptions: [] }], meta: {} } })
    render(<MemoryRouter initialEntries={['/admin/orders']}><AdminOrdersPage /></MemoryRouter>)
    const button = await screen.findByRole('button', { name: 'Order 3 details' })
    button.focus(); expect(button).toHaveFocus(); expect(button).toHaveAttribute('aria-expanded', 'false')
    fireEvent.click(button)
    expect(button).toHaveAttribute('aria-expanded', 'true')
    expect(screen.getByText('Financial ledger')).toBeInTheDocument()
  })
  it('a failed support search does not claim there were no matching records', async () => {
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url.endsWith('/search') ? { orders: [], tickets: [], events: [] } : { deliveries: [] } }))
    render(<MemoryRouter initialEntries={['/support']}><SupportPage /></MemoryRouter>)
    const input = screen.getByLabelText('Order, ticket, attendee, or event lookup')
    fireEvent.change(input, { target: { value: 'first' } }); fireEvent.click(screen.getByRole('button', { name: 'Search' }))
    await screen.findByText(/No matching records/)
    apiClient.get.mockRejectedValueOnce(new Error('outage'))
    fireEvent.change(input, { target: { value: 'second' } }); fireEvent.click(screen.getByRole('button', { name: 'Search' }))
    await screen.findByText(/Lookup failed/)
    expect(screen.queryByText(/No matching records/)).not.toBeInTheDocument()
    expect(input).toHaveValue('second')
  })
  it('withdraws private delivery rows after a current explicit support access denial', async () => {
    const delivery = { id: 4, template: 'fulfillment', recipient: 'private@example.invalid', status: 'failed', attempts: 1 }
    apiClient.get.mockResolvedValueOnce({ data: { deliveries: [delivery] } }).mockRejectedValue({ response: { status: 403, data: { error: 'Forbidden' } } })
    render(<MemoryRouter initialEntries={['/support']}><SupportPage /></MemoryRouter>)
    await screen.findByText('private@example.invalid')
    fireEvent.change(screen.getByLabelText('Order, ticket, attendee, or event lookup'), { target: { value: 'Denied' } })
    fireEvent.click(screen.getByRole('button', { name: 'Search' }))
    await screen.findByText(/Support access could not be verified/)
    expect(screen.queryByText('private@example.invalid')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Replay safely' })).not.toBeInTheDocument()
    expect(screen.queryByText(/No matching records/)).not.toBeInTheDocument()
  })
  it('support replacement clears the previous account query and ignores its response', async () => {
    clearAuth = setAuthTokenGetter(() => Promise.resolve('a'), { userId: 'a', sessionId: 'a', ready: true })
    const old = deferred()
    apiClient.get.mockImplementation(url => url.endsWith('/search') ? old.promise : Promise.resolve({ data: { deliveries: [] } }))
    render(<MemoryRouter initialEntries={['/support']}><SupportPage /></MemoryRouter>)
    fireEvent.change(screen.getByLabelText('Order, ticket, attendee, or event lookup'), { target: { value: 'Private A' } })
    fireEvent.click(screen.getByRole('button', { name: 'Search' }))
    await act(async () => { clearAuth = setAuthTokenGetter(() => Promise.resolve('b'), { userId: 'b', sessionId: 'b', ready: true }) })
    expect(screen.getByLabelText('Order, ticket, attendee, or event lookup')).toHaveValue('')
    await act(async () => old.resolve({ data: { orders: [], tickets: [], events: [{ id: 5, title: 'Private A result', status: 'draft' }] } }))
    expect(screen.queryByText('Private A result')).not.toBeInTheDocument()
  })
})
