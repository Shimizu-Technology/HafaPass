import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../../api/client'
import { saveBlob } from '../../utils/download'
import EventSalesInsights from './EventSalesInsights'
import EventAnalyticsPage from './EventAnalyticsPage'

vi.mock('../../api/client', async original => ({ ...(await original()), default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('../../components/EventWorkspace', () => ({ default: ({ children }) => <div>{children}</div> }))
vi.mock('../../hooks/usePlatformFeeTerms', () => ({ default: () => ({ status: 'ready', retry: () => {}, terms: { percent: 5, flatCents: 100, bearer: 'platform', payoutScheduleText: null } }) }))
vi.mock('../../utils/download', () => ({ saveBlob: vi.fn() }))

const stats = {
  timezone: 'Pacific/Guam',
  tickets_by_type: [{ name: 'General', sold: 8, available: 92, revenue_cents: 20000 }, { name: 'VIP', sold: 2, available: 18, revenue_cents: 15000 }],
  sales_by_day: [
    { date: '2026-10-01', orders: 1, tickets: 2, amount_cents: 5000 },
    { date: '2026-10-02', orders: 0, tickets: 0, amount_cents: 0 },
    { date: '2026-10-03', orders: 3, tickets: 8, amount_cents: 30000 },
  ],
  sales_by_channel: [
    { channel: 'online', orders: 3, tickets: 8, amount_cents: 30000 },
    { channel: 'box_office', orders: 1, tickets: 2, amount_cents: 5000 },
    { channel: 'guest_list', orders: 0, tickets: 0, amount_cents: 0 },
  ],
  traffic: {
    visitors: 40, checkout_visitors: 6, purchasers: 3,
    sources: [{ source: 'instagram', medium: 'social', visitors: 30, orders: 2, amount_cents: 10000 }, { source: 'direct', medium: 'none', visitors: 10, orders: 1, amount_cents: 5000 }],
    conversion: { estimate: true, sufficient_data: true, minimum_visitors: 25, rate: 0.075 },
  },
  acquisition_sources: [{ source: 'instagram', medium: 'social', campaign: 'launch', orders: 2 }],
}

describe('EventSalesInsights', () => {
  it('charts daily sales in the event timezone with a table view', async () => {
    render(<EventSalesInsights stats={stats} />)
    expect(screen.getByText(/in the event's timezone \(Pacific\/Guam\)/)).toBeInTheDocument()
    expect(screen.getByRole('group', { name: /Tickets sold per day\. 3 days from Oct 1 to Oct 3\. Total 10\./ })).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Amount charged' }))
    expect(screen.getByRole('button', { name: 'Amount charged' })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByRole('group', { name: /Amount charged per day\..*Total \$350\.00/ })).toBeInTheDocument()
    await userEvent.click(screen.getByText('View as table'))
    const table = screen.getByRole('table')
    expect(within(table).getAllByRole('row')).toHaveLength(4)
    expect(within(table).getByText('$300.00')).toBeInTheDocument()
  })

  it('breaks sales down by ticket type and channel', () => {
    render(<EventSalesInsights stats={stats} />)
    expect(screen.getByRole('list', { name: 'Tickets sold by ticket type' })).toHaveTextContent('General8 · $200.00')
    const channels = screen.getByRole('list', { name: 'Tickets by sales channel' })
    expect(channels).toHaveTextContent('Online8 · $300.00 · 3 orders')
    expect(channels).toHaveTextContent('Box office2 · $50.00 · 1 order')
  })

  it('labels conversion as an estimate and withholds it when traffic is thin', () => {
    const { rerender } = render(<EventSalesInsights stats={stats} />)
    expect(screen.getByText('Conversion (estimate)').nextSibling).toHaveTextContent('7.5%')
    expect(screen.getByRole('list', { name: 'Visitors by source' })).toHaveTextContent('instagram / social30 · 2 orders')
    rerender(<EventSalesInsights stats={{ ...stats, traffic: { ...stats.traffic, visitors: 4, conversion: { estimate: true, sufficient_data: false, minimum_visitors: 25, rate: null } } }} />)
    expect(screen.getByText('Conversion (estimate)').nextSibling).toHaveTextContent('Needs 25+ visitors')
  })

  it('handles an event with no sales or traffic, and older stats responses', () => {
    render(<EventSalesInsights stats={{ tickets_by_type: [], recent_orders: [] }} />)
    expect(screen.getByText('No sales yet. Daily sales appear here after the first order.')).toBeInTheDocument()
    expect(screen.getAllByText('No tickets sold yet.')).toHaveLength(2)
    expect(screen.getByText(/No visits recorded yet/)).toBeInTheDocument()
  })
})

describe('event finance exports', () => {
  let clearAuth
  const event = { id: 37, organization_id: 1, slug: 'night-market', title: 'Night Market', status: 'completed', timezone: 'Pacific/Guam', permissions: { view_finance: true } }
  const finance = { preview: { currency: 'usd' }, settlements: [{ id: 12, version: 2, status: 'finalized', available_to_payout_cents: 0 }, { id: 11, version: 1, status: 'finalized', available_to_payout_cents: 0 }], payouts: [], connected_account: null }
  beforeEach(() => {
    vi.clearAllMocks(); apiClient.get.mockReset(); window.localStorage.clear()
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '')
    window.localStorage.setItem('hafapass_scanner_user_id', 'actor-a'); window.localStorage.setItem('hafapass_organization_id', '1')
    clearAuth = setAuthTokenGetter(() => Promise.resolve('synthetic-token'), { userId: 'actor-a', sessionId: 'session-a', ready: true })
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url.endsWith('/stats') ? { ...stats, total_tickets_sold: 10, tickets_checked_in: 0, recent_orders: [] } : url.endsWith('/finance') ? finance : url.includes('_export') ? new Blob(['csv']) : event }))
  })
  afterEach(() => { clearAuth?.(); vi.unstubAllEnvs(); vi.restoreAllMocks() })

  const mount = () => render(<MemoryRouter initialEntries={['/dashboard/events/37/analytics']}><Routes><Route path="/dashboard/events/:id/analytics" element={<EventAnalyticsPage />} /></Routes></MemoryRouter>)

  it('downloads the orders CSV and a chosen statement version', async () => {
    mount()
    await userEvent.click(await screen.findByRole('button', { name: 'Orders CSV' }))
    expect(apiClient.get).toHaveBeenCalledWith('/organizer/events/37/finance/orders_export', expect.objectContaining({ responseType: 'blob', organizationId: '1' }))
    expect(saveBlob).toHaveBeenLastCalledWith(expect.any(Blob), 'night-market-orders.csv')

    expect(screen.getByLabelText('Statement')).toHaveValue('12')
    await userEvent.selectOptions(screen.getByLabelText('Statement'), '11')
    await userEvent.click(screen.getByRole('button', { name: 'Statement CSV' }))
    expect(apiClient.get).toHaveBeenCalledWith('/organizer/events/37/finance/statement_export?settlement_id=11', expect.objectContaining({ responseType: 'blob' }))
    expect(saveBlob).toHaveBeenLastCalledWith(expect.any(Blob), 'night-market-statement-v1.csv')

    await userEvent.selectOptions(screen.getByLabelText('Statement'), 'current')
    await userEvent.click(screen.getByRole('button', { name: 'Statement CSV' }))
    expect(saveBlob).toHaveBeenLastCalledWith(expect.any(Blob), 'night-market-statement-current.csv')
    expect(screen.getByRole('link', { name: 'All events and payouts' })).toHaveAttribute('href', '/dashboard/finances')
  })
})
