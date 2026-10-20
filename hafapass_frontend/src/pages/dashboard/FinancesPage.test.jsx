import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../../api/client'
import { saveBlob } from '../../utils/download'
import FinancesPage from './FinancesPage'
import DashboardSummary from './DashboardSummary'

vi.mock('../../api/client', async original => ({ ...(await original()), default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('../../hooks/usePlatformFeeTerms', () => ({ default: () => ({ status: 'ready', retry: () => {}, terms: { percent: 5, flatCents: 100, bearer: 'platform', payoutScheduleText: 'within 3 business days after your event' } }) }))
vi.mock('../../utils/download', () => ({ saveBlob: vi.fn() }))

const summary = {
  organization: { id: 1, name: 'GuamTime Events', timezone: 'Pacific/Guam' },
  currency: 'usd',
  totals: {
    gross_cents: 20000, discount_cents: 0, refund_cents: 0, platform_fee_cents: 1400, processing_fee_cents: 551,
    platform_processing_fee_cents: 185, organizer_proceeds_cents: 20000, door_cash_retained_cents: 0,
    payable_cents: 19449, paid_cents: 10000, in_flight_cents: 0, owed_cents: 9449, negative_balance_cents: 0,
    available_to_payout_cents: 4632, requestable_cents: 4632,
  },
  events: [
    { id: 4, title: 'Closing Night', status: 'completed', starts_at: '2026-10-10T10:00:00Z', timezone: 'Pacific/Guam', organizer_proceeds_cents: 15000, paid_cents: 10000, owed_cents: 4632, requestable_cents: 4632, negative_balance_cents: 0, settlement: { id: 9, version: 1, current: true }, settlement_state: 'finalized', payout_state: 'ready' },
    { id: 7, title: 'Next Show', status: 'published', starts_at: '2026-11-10T10:00:00Z', timezone: 'Pacific/Guam', organizer_proceeds_cents: 5000, paid_cents: 0, owed_cents: 4817, negative_balance_cents: 0, settlement: null, settlement_state: 'not_finalized', payout_state: 'awaiting_statement' },
  ],
  payouts: [{ id: 31, event_title: 'Closing Night', settlement_version: 1, amount_cents: 10000, status: 'paid', provider_payout_id: 'po_123', paid_at: '2026-10-12T02:00:00Z', created_at: '2026-10-11T02:00:00Z' }],
  payouts_count: 1,
  processing_fee_bearers: { platform: 1, organizer: 1, legacy: 2 },
}

let clearAuth
function mount() {
  return render(<MemoryRouter initialEntries={['/dashboard/finances']}><Routes><Route path="/dashboard/finances" element={<FinancesPage />} /></Routes></MemoryRouter>)
}

beforeEach(() => {
  vi.clearAllMocks(); apiClient.get.mockReset(); window.localStorage.clear()
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '')
  window.localStorage.setItem('hafapass_scanner_user_id', 'actor-a'); window.localStorage.setItem('hafapass_organization_id', '1')
  clearAuth = setAuthTokenGetter(() => Promise.resolve('synthetic-token'), { userId: 'actor-a', sessionId: 'session-a', ready: true })
  apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/organizer/finances' ? summary : new Blob(['csv']) }))
})
afterEach(() => { clearAuth?.(); vi.unstubAllEnvs(); vi.restoreAllMocks() })

describe('FinancesPage', () => {
  it('shows what is owed, how it adds up and payout timing for the selected organization', async () => {
    mount()
    expect(await screen.findByText('$94.49', { selector: 'p' })).toBeInTheDocument()
    expect(screen.getByText('$46.32 can be requested now from finalized statements.')).toBeInTheDocument()
    expect(screen.getByText('Payout timing: within 3 business days after your event.')).toBeInTheDocument()
    expect(screen.getByText('Sales, fees and payouts across every GuamTime Events event.')).toBeInTheDocument()
    const breakdown = screen.getByRole('region', { name: 'How the total adds up' })
    expect(within(breakdown).getByText('Card processing you paid').closest('div')).toHaveTextContent('−$5.51')
    expect(within(breakdown).getByText('HåfaPass covered another $1.85')).toBeInTheDocument()
    expect(apiClient.get).toHaveBeenCalledWith('/organizer/finances', expect.objectContaining({ organizationId: '1', authContext: expect.objectContaining({ userId: 'actor-a' }) }))
  })

  it('explains who paid card processing, including orders under earlier terms', async () => {
    mount()
    expect(await screen.findByText('2 older orders were placed under earlier terms, when card processing was deducted from organizer proceeds.')).toBeInTheDocument()
    expect(screen.getByText('1 order had card processing on tickets covered by HåfaPass.')).toBeInTheDocument()
  })

  it('links each event to its settlement and labels statement and payout status in words', async () => {
    mount()
    const links = await screen.findAllByRole('link', { name: /Closing Night/ })
    expect(links[0]).toHaveAttribute('href', '/dashboard/events/4/analytics#settlement')
    expect(screen.getAllByText('Finalized v1').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Ready to request').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Not finalized').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Waiting for statement').length).toBeGreaterThan(0)
    const history = screen.getByRole('region', { name: 'Payout history' })
    expect(within(history).getByText('po_123')).toBeInTheDocument()
    expect(within(history).getByText('$100.00')).toBeInTheDocument()
  })

  it('downloads exports through the API with the organization context', async () => {
    mount()
    await userEvent.click(await screen.findByRole('button', { name: 'Orders CSV' }))
    expect(apiClient.get).toHaveBeenCalledWith('/organizer/finances/orders_export', expect.objectContaining({ responseType: 'blob', organizationId: '1' }))
    expect(saveBlob).toHaveBeenCalledWith(expect.any(Blob), expect.stringMatching(/^hafapass-orders-\d{4}-\d{2}-\d{2}\.csv$/))
    await userEvent.click(screen.getByRole('button', { name: 'Payouts CSV' }))
    expect(apiClient.get).toHaveBeenCalledWith('/organizer/finances/payouts_export', expect.objectContaining({ responseType: 'blob' }))
  })

  it('reports a failed export without losing the page', async () => {
    mount()
    await screen.findByRole('button', { name: 'Orders CSV' })
    apiClient.get.mockRejectedValueOnce({ response: { status: 500 } })
    await userEvent.click(screen.getByRole('button', { name: 'Orders CSV' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('That export could not be downloaded')
    expect(screen.getByRole('region', { name: 'By event' })).toBeInTheDocument()
  })

  it('shows an empty state before any sales', async () => {
    apiClient.get.mockResolvedValue({ data: { ...summary, events: [], payouts: [], payouts_count: 0, totals: { ...summary.totals, owed_cents: 0, available_to_payout_cents: 0, requestable_cents: 0 } } })
    mount()
    expect(await screen.findByText('No sales yet. Totals appear here once an event sells its first ticket.')).toBeInTheDocument()
    expect(screen.getByText('No payouts yet.')).toBeInTheDocument()
    expect(screen.getByText(/Nothing can be requested right now/)).toBeInTheDocument()
  })

  it('explains a role without finance access instead of offering a retry', async () => {
    apiClient.get.mockRejectedValue({ response: { status: 403 } })
    mount()
    expect(await screen.findByRole('alert')).toHaveTextContent('does not include finances')
    expect(screen.queryByRole('button', { name: 'Try again' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Orders CSV' })).not.toBeInTheDocument()
  })

  it('retries after a failed load', async () => {
    apiClient.get.mockRejectedValueOnce({ response: { status: 500 } })
    mount()
    await userEvent.click(await screen.findByRole('button', { name: 'Try again' }))
    expect(await screen.findByText('$94.49', { selector: 'p' })).toBeInTheDocument()
  })

  it('explains money on hold and events that need a new statement version', async () => {
    apiClient.get.mockResolvedValue({ data: { ...summary, totals: { ...summary.totals, requestable_cents: 0 }, events: [{ ...summary.events[0], payout_state: 'needs_new_version', requestable_cents: 0 }, { ...summary.events[1], requestable_cents: 2000, payout_state: 'ready' }] } })
    mount()
    expect(await screen.findByText('$20.00 from finalized statements is on hold until open refunds, disputes or payment checks are settled.')).toBeInTheDocument()
    expect(screen.getByText(/Nothing can be requested right now/)).toBeInTheDocument()
    expect(screen.getAllByText('Finalize new version').length).toBeGreaterThan(1)
  })

  it('warns about a negative balance carried forward', async () => {
    apiClient.get.mockResolvedValue({ data: { ...summary, totals: { ...summary.totals, negative_balance_cents: 1250 } } })
    mount()
    expect(await screen.findByText(/A negative balance of \$12\.50 carries forward/)).toBeInTheDocument()
  })
})

describe('DashboardSummary finances link', () => {
  const base = { upcoming_events_count: 1, tickets_sold: 3, next_event: null }
  const wrap = data => render(<MemoryRouter><DashboardSummary state={{ status: 'ready', data }} /></MemoryRouter>)

  it('links to finances when revenue is visible', () => {
    wrap({ ...base, revenue_cents: 5000 })
    expect(screen.getByRole('link', { name: 'Finances, payouts and exports' })).toHaveAttribute('href', '/dashboard/finances')
  })

  it('hides the link without finance access', () => {
    wrap(base)
    expect(screen.queryByRole('link', { name: 'Finances, payouts and exports' })).not.toBeInTheDocument()
  })
})
