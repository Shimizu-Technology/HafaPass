import { act, cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { getApiAuthContext, setAuthTokenGetter } from '../../api/client'
import AdminOperationsPage from './AdminOperationsPage'
import AdminDashboardPage from './AdminDashboardPage'
import SupportPage from '../support/SupportPage'
import AdminRoute from '../../components/AdminRoute'
import { publishAccountRole } from '../../utils/workspace'

vi.mock('../../api/client', async original => ({ ...await original(), default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('@clerk/clerk-react', () => ({ useAuth: () => ({ isLoaded: true, isSignedIn: true, userId: 'synthetic' }) }))
vi.mock('./AdminLayout', () => ({ default: ({ children }) => <div>{children}</div> }))
vi.mock('../../components/ui/ScrollReveal', () => ({ StaggerContainer: ({ children }) => <div>{children}</div>, StaggerItem: ({ children }) => <div>{children}</div> }))
const signals = { status: 'observable', failed_messages_last_hour: 0, stale_message_events: 4,
  failed_payment_webhooks: 0, open_reconciliation_exceptions: 0, unknown_card_present_results: 0 }
const records = { category: 'stale_message_events', signals, checked_at: '2026-10-26T00:00:00Z',
  meta: { page: 1, total_count: 4, total_pages: 1 }, items: Array.from({ length: 4 }, (_, index) => ({
    id: 100 + index, provider: 'resend', event_type: index < 2 ? 'email.sent' : 'email.delivered',
    review_state: 'no_linked_delivery', processing_error: false, received_at: '2026-10-25T00:00:00Z', occurred_at: '2026-10-25T00:00:00Z',
  })) }
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done }); return { promise, resolve } }
let clearAuth = () => {}
beforeEach(() => { vi.clearAllMocks(); setAuthTokenGetter(null)(); apiClient.get.mockResolvedValue({ data: records }) })
afterEach(() => { cleanup(); publishAccountRole(null, null); clearAuth(); clearAuth = () => {} })
const renderPage = (path = '/admin/operations') => render(<MemoryRouter initialEntries={[path]}><AdminOperationsPage /></MemoryRouter>)

describe('operational review', () => {
  it('clicks from dashboard count 4 to the four underlying receipts even when Support deliveries are empty', async () => {
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/admin/dashboard' ? {
      total_events: {}, total_users: {}, total_revenue_cents: 0, total_tickets_sold: 0, recent_events: [], recent_orders: [], operational_signals: signals,
    } : url === '/support/message_deliveries' ? { deliveries: [] } : records }))
    const view = render(<MemoryRouter initialEntries={['/admin']}><Routes>
      <Route path="/admin" element={<AdminDashboardPage />} />
      <Route path="/admin/operations" element={<AdminOperationsPage />} />
    </Routes></MemoryRouter>)
    expect(await screen.findByText('4 operational records need review.')).toBeVisible()
    await userEvent.click(screen.getByRole('link', { name: 'Review operational records' }))
    expect(await screen.findByRole('heading', { name: 'Unprocessed email receipts · over 5 minutes (4)' })).toBeVisible()
    expect(screen.getAllByText('No linked delivery')).toHaveLength(4)
    expect(screen.getAllByText('No processing error recorded.', { exact: false })).toHaveLength(4)
    expect(screen.getByText(/Sent or delivered receipts do not mean an email failed/)).toBeVisible()
    expect(screen.getByText('Record #103')).toBeVisible()
    expect(apiClient.post).not.toHaveBeenCalled()
    view.unmount()
    render(<MemoryRouter initialEntries={['/support']}><SupportPage /></MemoryRouter>)
    expect(await screen.findByText('No recent message deliveries.')).toBeVisible()
    expect(screen.queryByText('Record #103')).not.toBeInTheDocument()
  })

  it('shows loading, truthful category emptiness and refreshes counts and rows together', async () => {
    const pending = deferred()
    apiClient.get.mockReturnValueOnce(pending.promise)
    renderPage()
    expect(screen.getByText('Loading operational records…')).toBeVisible()
    expect(screen.queryByText(/No records in this category/)).not.toBeInTheDocument()
    await act(async () => pending.resolve({ data: records }))
    apiClient.get.mockResolvedValue({ data: { ...records, items: [], signals: { ...signals, stale_message_events: 0 }, meta: { ...records.meta, total_count: 0 } } })
    await userEvent.click(screen.getByRole('button', { name: 'Refresh operational records' }))
    expect(await screen.findByText('No records in this category. Other categories may still need review.')).toBeVisible()
    expect(screen.queryByText('Record #100')).not.toBeInTheDocument()
    expect(screen.getByText(/0 operational records need review/)).toBeVisible()
  })

  it('shows fetch failure and retry rather than an empty success; refresh failure hides stale rows', async () => {
    apiClient.get.mockRejectedValueOnce(new Error('outage'))
    renderPage()
    expect(await screen.findByRole('alert')).toHaveTextContent('Operational records could not be loaded.')
    expect(screen.queryByText(/No records in this category/)).not.toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Try again' }))
    await screen.findByText('Record #100')
    apiClient.get.mockRejectedValueOnce(new Error('outage'))
    await userEvent.click(screen.getByRole('button', { name: 'Refresh operational records' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Previously loaded counts may be out of date.')
    expect(screen.queryByText('Record #100')).not.toBeInTheDocument()
  })

  it('keeps categories and pagination in the URL and never presents old-category rows under new labels', async () => {
    const pending = deferred()
    apiClient.get.mockResolvedValueOnce({ data: records }).mockReturnValueOnce(pending.promise)
    renderPage()
    await screen.findByText('Record #100')
    await userEvent.click(screen.getByRole('button', { name: 'Failed payment updates: 0' }))
    expect(screen.queryByText('Record #100')).not.toBeInTheDocument()
    await act(async () => pending.resolve({ data: { ...records, category: 'failed_payment_webhooks', items: [], meta: { ...records.meta, total_count: 0 } } }))
    expect(await screen.findByRole('heading', { name: 'Failed payment updates (0)' })).toBeVisible()
    expect(apiClient.get.mock.calls.at(-1)[1].params).toEqual({ category: 'failed_payment_webhooks', page: 1 })
    expect(screen.getByText(/This page does not retry updates/)).toBeVisible()
  })

  it('paginates the selected category while preserving its full count', async () => {
    apiClient.get.mockResolvedValueOnce({ data: { ...records, signals: { ...signals, stale_message_events: 51 }, meta: { page: 1, total_count: 51, total_pages: 2 } } })
      .mockResolvedValueOnce({ data: { ...records, signals: { ...signals, stale_message_events: 51 }, items: [{ ...records.items[0], id: 151 }], meta: { page: 2, total_count: 51, total_pages: 2 } } })
    renderPage()
    expect(await screen.findByText('Page 1 of 2 · 51 results')).toBeVisible()
    await userEvent.click(screen.getByRole('button', { name: 'Next' }))
    expect(await screen.findByText('Record #151')).toBeVisible()
    expect(screen.queryByText('Record #100')).not.toBeInTheDocument()
    expect(screen.getByText('Page 2 of 2 · 51 results')).toBeVisible()
    expect(apiClient.get.mock.calls.at(-1)[1].params).toEqual({ category: 'stale_message_events', page: 2 })
  })

  it.each(['support', 'organizer', 'attendee'])('blocks the actual admin route for %s without fetching operational data', async role => {
    apiClient.get.mockResolvedValue({ data: { role } })
    render(<MemoryRouter initialEntries={['/admin/operations']}><Routes>
      <Route path="/admin/operations" element={<AdminRoute clerkConfigured><AdminOperationsPage /></AdminRoute>} />
      <Route path="/" element={<p>Home</p>} />
    </Routes></MemoryRouter>)
    expect(await screen.findByText('Home')).toBeVisible()
    expect(apiClient.get).toHaveBeenCalledTimes(1)
    expect(apiClient.get).toHaveBeenCalledWith('/me')
  })

  it('withdraws loaded records on admin denial and offers the existing authority recovery', async () => {
    renderPage()
    await screen.findByText('Record #100')
    apiClient.get.mockRejectedValueOnce({ response: { status: 403, data: { error: 'Admin access required' } } })
    await userEvent.click(screen.getByRole('button', { name: 'Refresh operational records' }))
    expect(await screen.findByText(/Administrator access needs to be verified/)).toBeVisible()
    expect(screen.queryByText('Record #100')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Refresh operational records' })).not.toBeInTheDocument()
  })

  it.each(['a', 'b'])('clears rows and fences pending responses when replacement user %s starts a new session', async nextUser => {
    clearAuth = setAuthTokenGetter(async () => 'synthetic-a', { userId: 'a', sessionId: 'a', ready: true })
    renderPage()
    await screen.findByText('Record #100')
    const stale = deferred(); const replacement = deferred()
    apiClient.get.mockReturnValueOnce(stale.promise).mockReturnValueOnce(replacement.promise)
    await userEvent.click(screen.getByRole('button', { name: 'Refresh operational records' }))
    const oldConfig = apiClient.get.mock.calls.at(-1)[1]
    await act(async () => { clearAuth = setAuthTokenGetter(async () => 'synthetic-b', { userId: nextUser, sessionId: 'b', ready: true }) })
    expect(screen.queryByText('Record #100')).not.toBeInTheDocument()
    await act(async () => stale.resolve({ data: records }))
    expect(screen.queryByText('Record #100')).not.toBeInTheDocument()
    expect(oldConfig.signal.aborted).toBe(true)
    await act(async () => replacement.resolve({ data: { ...records, items: [{ ...records.items[0], id: 200 }] } }))
    expect(await screen.findByText('Record #200')).toBeVisible()
    expect(apiClient.get.mock.calls.at(-1)[1].authContext).toBe(getApiAuthContext())
  })

  it('shows receipt error and linked states without exposing raw errors or offering actions', async () => {
    apiClient.get.mockResolvedValue({ data: { ...records, items: [
      { ...records.items[0], review_state: 'processing_error', processing_error: true, delivery_id: 12 },
      { ...records.items[1], review_state: 'awaiting_processing', delivery_id: 13 },
    ] } })
    renderPage()
    expect(await screen.findByText('Processing error recorded')).toBeVisible()
    expect(screen.getByText('Linked delivery · awaiting processing')).toBeVisible()
    expect(screen.queryByRole('button', { name: /retry|resend|replay|dismiss|repair/i })).not.toBeInTheDocument()
  })
})
