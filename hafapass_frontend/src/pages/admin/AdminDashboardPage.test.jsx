import { render, screen, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import AdminDashboardPage from './AdminDashboardPage'

vi.mock('../../api/client', async importOriginal => ({ ...await importOriginal(), default: { get: vi.fn() } }))
vi.mock('../../components/ui/ScrollReveal', () => ({
  StaggerContainer: ({ children, className }) => <div className={className}>{children}</div>,
  StaggerItem: ({ children }) => <div>{children}</div>,
}))
vi.mock('./AdminLayout', () => ({ default: ({ children }) => <div>{children}</div> }))

const dashboard = {
  total_events: { draft: 1, published: 2 }, total_users: { attendee: 3 }, total_revenue_cents: 12500, total_tickets_sold: 9,
  financials: {}, operational_signals: {}, open_reconciliation_exceptions: 0,
  recent_events: [{ id: 1, slug: 'beach', title: 'Full Moon Beach Party', organizer_name: 'Island Nights', status: 'published' }],
  recent_orders: [{ id: 2, buyer_name: 'Ana Cruz', event_title: 'Full Moon Beach Party', total_cents: 2500, status: 'partially_refunded' }],
}

describe('AdminDashboardPage', () => {
  beforeEach(() => { vi.clearAllMocks(); apiClient.get.mockResolvedValue({ data: dashboard }) })

  it('uses a defined color token for every stat card icon', async () => {
    render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    const tickets = (await screen.findByText('Tickets Sold')).nextElementSibling
    expect(tickets).toHaveClass('bg-accent-500')
    expect(document.querySelector('[class*="coral"]')).toBeNull()
  })

  it('shows readable event and order statuses', async () => {
    render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    expect(await screen.findByText('Published')).toBeInTheDocument()
    expect(screen.getByText('Partially refunded')).toBeInTheDocument()
    expect(screen.queryByText('published')).not.toBeInTheDocument()
  })

  it('reports platform revenue net of the processing HåfaPass covers, not organizer processing', async () => {
    apiClient.get.mockResolvedValue({ data: { ...dashboard,
      financials: { fee_cents: 99999 }, open_disputes: 2, payouts_needing_reconciliation: 1,
      platform_revenue: { gross_platform_fee_cents: 1050, platform_processing_fee_cents: 185, organizer_processing_fee_cents: 368, net_platform_revenue_cents: 865 },
    } })
    render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    const section = await screen.findByRole('region', { name: 'HåfaPass platform revenue' })
    expect(within(section).getByText('Platform fees collected').nextElementSibling).toHaveTextContent('$10.50')
    expect(within(section).getByText('Card processing covered by HåfaPass').nextElementSibling).toHaveTextContent('−$1.85')
    expect(within(section).getByText('Net platform revenue').nextElementSibling).toHaveTextContent('$8.65')
    expect(within(section).getByText(/deducted from organizer proceeds/)).toHaveTextContent('$3.68')
    expect(screen.queryByText('$999.99')).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: '2 open disputes' })).toHaveAttribute('href', '/admin/disputes?status=open')
    expect(screen.getByRole('link', { name: '1 payout awaits a recorded outcome' })).toHaveAttribute('href', '/admin/payouts')
  })
})
