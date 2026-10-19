import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../../api/client'
import EventAnalyticsPage from './EventAnalyticsPage'

vi.mock('../../api/client', async original => ({ ...(await original()), default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('../../components/EventWorkspace', () => ({ default: ({ children }) => <div>{children}</div> }))
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no }); return { promise, resolve, reject } }
const rights = { view_finance: true, view_attendees: true, manage_finance: true, payout: true }
const event = { id: 37, organization_id: 1, title: 'Authorized event', status: 'completed', timezone: 'Pacific/Guam', permissions: rights }
const stats = { total_tickets_sold: 1, tickets_checked_in: 0, tickets_by_type: [], recent_orders: [{ id: 7, buyer_name: 'Private buyer', buyer_email: 'private@example.invalid', ticket_count: 1, total_cents: 500 }] }
const finance = { preview: {}, settlements: [{ id: 7, status: 'finalized', available_to_payout_cents: 500 }], connected_account: { payout_ready: true }, payouts: [] }
const denied = status => ({ response: { status } })
let clearAuth
function fixture(url) { return url.endsWith('/stats') ? stats : url.endsWith('/finance') ? finance : event }
function mount() { return render(<MemoryRouter initialEntries={['/dashboard/events/37/analytics']}><Routes><Route path="/dashboard/events/:id/analytics" element={<EventAnalyticsPage />} /></Routes></MemoryRouter>) }
const privateReads = () => apiClient.get.mock.calls.filter(([url]) => /\/(stats|finance|attendees)$/.test(url))
beforeEach(() => {
  vi.clearAllMocks(); apiClient.get.mockReset(); apiClient.post.mockReset(); window.localStorage.clear()
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '')
  window.localStorage.setItem('hafapass_scanner_user_id', 'actor-a'); window.localStorage.setItem('hafapass_organization_id', '1')
  clearAuth = setAuthTokenGetter(() => Promise.resolve('synthetic-token'), { userId: 'actor-a', sessionId: 'session-a', ready: true })
  apiClient.get.mockImplementation(url => Promise.resolve({ data: fixture(url) }))
})
afterEach(() => { clearAuth?.(); vi.unstubAllEnvs(); vi.restoreAllMocks() })

it('distinguishes requesting a payout from a confirmed transfer', async () => {
  const confirmation = vi.spyOn(window, 'confirm').mockReturnValue(true)
  apiClient.post.mockResolvedValueOnce({ data: { id: 9, status: 'processing' } })
  mount()
  await userEvent.click(await screen.findByRole('button', { name: 'Request payout $5.00' }))
  expect(confirmation).toHaveBeenCalledWith(expect.stringContaining('not confirmation that money has been sent'))
  expect(await screen.findByRole('status')).toHaveTextContent('Payout requested. Processing does not confirm that money has been sent.')
  expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/37/finance/payout', {
    settlement_id: 7, amount_cents: 500,
  }, expect.objectContaining({ headers: { 'Idempotency-Key': expect.any(String) } }))
})

describe('authoritative analytics access', () => {
  it('verifies event permissions before requesting private records', async () => {
    const verify = deferred()
    apiClient.get.mockImplementation(url => url === '/organizer/events/37' ? verify.promise : Promise.resolve({ data: fixture(url) }))
    mount()
    await waitFor(() => expect(apiClient.get).toHaveBeenCalled())
    expect(privateReads()).toHaveLength(0)
    await act(async () => verify.resolve({ data: event }))
    await screen.findAllByText('Private buyer')
    expect(privateReads().map(([url]) => url)).toEqual(['/organizer/events/37/stats', '/organizer/events/37/finance'])
    for (const [, config] of apiClient.get.mock.calls) expect(config).toMatchObject({ organizationId: '1', authContext: { userId: 'actor-a', sessionId: 'session-a' } })
  })
  it('explains scanner-only access without requesting finance or buyer records', async () => {
    apiClient.get.mockResolvedValue({ data: { ...event, permissions: { scan: true } } })
    mount()
    expect(await screen.findByRole('alert')).toHaveTextContent('Your event access does not include analytics and finances.')
    expect(privateReads()).toHaveLength(0)
    expect(screen.queryByRole('button', { name: /^Request payout / })).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Back to Dashboard' })).toBeInTheDocument()
  })
  it('rejects a mismatched event or organization before private data is requested', async () => {
    apiClient.get.mockResolvedValue({ data: { ...event, organization_id: 2 } })
    mount()
    expect(await screen.findByRole('alert')).toHaveTextContent('event context could not be verified')
    expect(privateReads()).toHaveLength(0)
  })
  it.each([401, 403])('withdraws cached finance and buyer data after a current mutation receives %s', async status => {
    apiClient.post.mockRejectedValueOnce(denied(status))
    mount(); await screen.findAllByText('Private buyer')
    await userEvent.click(screen.getByRole('button', { name: 'Finalize current version' }))
    const alert = await screen.findByRole('alert')
    expect(alert).toHaveTextContent(status === 401 ? 'Please sign in' : 'Your event access changed')
    expect(screen.queryByText('Private buyer')).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'View attendee list' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /^Request payout / })).not.toBeInTheDocument()
  })
  it('ignores old private read completion after denial and verifies current rights before retry', async () => {
    const oldFinance = deferred()
    apiClient.get.mockImplementation(url => url.endsWith('/stats') ? Promise.reject(denied(403)) : url.endsWith('/finance') ? oldFinance.promise : Promise.resolve({ data: event }))
    mount(); await screen.findByRole('alert')
    const oldConfig = apiClient.get.mock.calls.find(([url]) => url.endsWith('/finance'))[1]
    expect(oldConfig.signal.aborted).toBe(true)
    await act(async () => oldFinance.resolve({ data: finance }))
    expect(screen.queryByRole('button', { name: /^Request payout / })).not.toBeInTheDocument()
    const freshVerify = deferred()
    apiClient.get.mockImplementation(url => url === '/organizer/events/37' ? freshVerify.promise : Promise.resolve({ data: fixture(url) }))
    const readsBefore = privateReads().length
    await userEvent.click(screen.getByRole('button', { name: 'Retry analytics' }))
    expect(privateReads()).toHaveLength(readsBefore)
    await act(async () => freshVerify.resolve({ data: { ...event, permissions: { view_finance: true } } }))
    await screen.findAllByText('Private buyer')
    expect(screen.queryByRole('button', { name: /Finalize|^Request payout / })).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'View attendee list' })).not.toBeInTheDocument()
  })
})

it('offers one clearly labelled link to the attendee list', async () => {
  mount(); await screen.findAllByText('Private buyer')
  const links = screen.getAllByRole('link', { name: /attendee/i })
  expect(links).toHaveLength(1)
  expect(links[0]).toHaveAccessibleName('View attendee list')
  expect(links[0]).toHaveAttribute('href', '/dashboard/events/37/attendees')
  expect(screen.queryByRole('link', { name: /Full List/ })).not.toBeInTheDocument()
  expect(screen.queryByRole('button', { name: /View All/ })).not.toBeInTheDocument()
  expect(privateReads().some(([url]) => url.endsWith('/attendees'))).toBe(false)
})
