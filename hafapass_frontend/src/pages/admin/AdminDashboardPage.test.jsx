import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import AdminDashboardPage from './AdminDashboardPage'

vi.mock('../../api/client', async importOriginal => ({ ...await importOriginal(), default: { get: vi.fn(), post: vi.fn(), patch: vi.fn() } }))
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
  it('shows each production setup item as an alert with a confirmed one-click approval', async () => {
    const user = userEvent.setup()
    const setup = [
      { key: 'policy_register', label: 'Production policy register', message: 'Checkout is off until you approve the production policy register.', configured: true, help: null },
      { key: 'resend_production', label: 'Production email (Resend)', message: 'Ticket and order emails are off until you approve production email.', configured: false, help: 'Set RESEND_API_KEY on the server first.' },
    ]
    apiClient.get.mockResolvedValueOnce({ data: { ...dashboard, setup_required: setup } }).mockResolvedValue({ data: { ...dashboard, setup_required: [setup[1]] } })
    apiClient.post.mockResolvedValue({ data: { capability: 'policy_register', approved: true } })
    render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    const alerts = await screen.findAllByRole('alert')
    expect(alerts[0]).toHaveTextContent('Checkout is off until you approve the production policy register.')
    expect(alerts[1]).toHaveTextContent('Set RESEND_API_KEY on the server first.')
    expect(within(alerts[1]).getByRole('button', { name: /Approve now/ })).toBeDisabled()
    await user.click(within(alerts[0]).getByRole('button', { name: /Approve now/ }))
    const dialog = screen.getByRole('dialog', { name: 'Approve Production policy register?' })
    expect(dialog).toHaveTextContent('This records your approval in the audit log.')
    expect(apiClient.post).not.toHaveBeenCalled()
    await user.click(within(dialog).getByRole('button', { name: 'Approve' }))
    expect(apiClient.post).toHaveBeenCalledWith('/admin/platform_capabilities/policy_register/quick_approve', {}, expect.anything())
    await waitFor(() => expect(screen.queryByText('Checkout is off until you approve the production policy register.')).not.toBeInTheDocument())
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(apiClient.get).toHaveBeenCalledTimes(2)
  })

  it('requires the draft-policy acknowledgment before a quick approval and warns about expiring approvals in amber', async () => {
    const user = userEvent.setup()
    const setup = [
      { key: 'policy_register', label: 'Production policy register', message: 'Checkout is off until you approve the production policy register.', configured: true, help: null,
        requires_draft_acknowledgment: true, acknowledgment_text: 'I approve launching on draft policies and accept the business risk.', expires_at: null, expiring_soon: false },
      { key: 'resend_production', label: 'Production email (Resend)', message: 'The production email approval expires on Nov 10, 2026. Approve again to keep email on.', configured: true, help: null,
        requires_draft_acknowledgment: false, expires_at: '2026-11-10T00:00:00Z', expiring_soon: true },
    ]
    apiClient.get.mockResolvedValue({ data: { ...dashboard, setup_required: setup } })
    apiClient.post.mockResolvedValue({ data: { capability: 'policy_register', approved: true } })
    render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    const outage = await screen.findByRole('alert')
    expect(outage).toHaveClass('bg-red-50')
    const expiring = screen.getByText(/expires on Nov 10, 2026/).closest('[role="status"]')
    expect(expiring).toHaveClass('bg-amber-50')
    expect(within(expiring).getByRole('button', { name: /Approve again/ })).toBeEnabled()
    await user.click(within(outage).getByRole('button', { name: /Approve now/ }))
    const dialog = screen.getByRole('dialog', { name: 'Approve Production policy register?' })
    const confirm = within(dialog).getByRole('button', { name: 'Approve' })
    expect(confirm).toBeDisabled()
    await user.click(within(dialog).getByRole('checkbox', { name: 'I approve launching on draft policies and accept the business risk.' }))
    await user.click(confirm)
    expect(apiClient.post).toHaveBeenCalledWith('/admin/platform_capabilities/policy_register/quick_approve', { draft_policies_acknowledged: true }, expect.anything())
  })

  it('verifies a waiting organizer with an optional note, then refreshes', async () => {
    const user = userEvent.setup()
    const waiting = { profile_id: 4, business_name: 'Reef Nights', organization_id: 9, owner_email: 'owner@reef.test', requested_at: '2026-10-20T22:00:00Z', verification_status: 'pending', payout_ready: false, event_count: 2 }
    apiClient.get.mockResolvedValueOnce({ data: { ...dashboard, organizers_awaiting_verification: [waiting, { profile_id: 5, business_name: 'Quiet Org', requested_at: null, verification_status: 'unverified', payout_ready: true, event_count: 1 }], verified_organizers: [] } })
      .mockResolvedValue({ data: { ...dashboard, organizers_awaiting_verification: [], verified_organizers: [{ profile_id: 4, business_name: 'Reef Nights', verified_at: '2026-10-21T00:00:00Z', verified_by: 'admin@hafapass.test' }] } })
    apiClient.patch.mockResolvedValue({ data: { id: 4, verification_status: 'verified' } })
    render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    const section = await screen.findByRole('region', { name: 'Organizers waiting for verification' })
    expect(section).toHaveTextContent('Owner: owner@reef.test')
    expect(section).toHaveTextContent('Requested')
    expect(section).toHaveTextContent('Payout details on file: No · 2 events')
    expect(section).toHaveTextContent('Not requested yet')
    await user.click(within(section).getByRole('button', { name: 'Verify Reef Nights' }))
    const dialog = screen.getByRole('dialog', { name: 'Verify Reef Nights?' })
    expect(dialog).toHaveTextContent('Their published events can sell tickets right away.')
    expect(dialog).toHaveTextContent('Paid tickets won’t sell until they do')
    await user.type(within(dialog).getByRole('textbox', { name: /Note/ }), 'Checked with the owner.')
    await user.click(within(dialog).getByRole('button', { name: 'Verify' }))
    expect(apiClient.patch).toHaveBeenCalledWith('/admin/organizer_profiles/4', { verification_status: 'verified', verification_notes: 'Checked with the owner.' }, expect.anything())
    expect(await screen.findByText('Reef Nights is verified. Their published events can sell tickets.')).toBeInTheDocument()
    expect(await within(section).findByText('No organizers are waiting.')).toBeInTheDocument()
    expect(screen.getByRole('region', { name: 'Verified organizers' })).toHaveTextContent('Verified')
  })

  it('pauses all sales for a verified organizer after explaining what pausing does', async () => {
    const user = userEvent.setup()
    apiClient.get.mockResolvedValue({ data: { ...dashboard, organizers_awaiting_verification: [], verified_organizers: [{ profile_id: 4, business_name: 'Reef Nights', verified_at: '2026-10-21T00:00:00Z', verified_by: null }] } })
    apiClient.patch.mockRejectedValueOnce({ response: { status: 422, data: { error: 'Verification status is invalid.' } } }).mockResolvedValue({ data: { id: 4 } })
    render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    const section = await screen.findByRole('region', { name: 'Verified organizers' })
    await user.click(within(section).getByRole('button', { name: 'Pause all sales for Reef Nights' }))
    const dialog = screen.getByRole('dialog', { name: 'Pause all sales for Reef Nights?' })
    expect(dialog).toHaveTextContent('Their events stay visible but stop selling until you verify them again.')
    await user.click(within(dialog).getByRole('button', { name: 'Pause all sales' }))
    expect(await within(dialog).findByRole('alert')).toHaveTextContent('Verification status is invalid.')
    await user.type(within(dialog).getByRole('textbox', { name: /Note/ }), 'Refund complaints')
    await user.click(within(dialog).getByRole('button', { name: 'Pause all sales' }))
    expect(apiClient.patch).toHaveBeenLastCalledWith('/admin/organizer_profiles/4', { verification_status: 'suspended', verification_notes: 'Refund complaints' }, expect.anything())
    expect(await screen.findByText('All sales are paused for Reef Nights.')).toBeInTheDocument()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  it('lists organizers whose sales are paused and resumes them with an optional note', async () => {
    const user = userEvent.setup()
    apiClient.get.mockResolvedValue({ data: { ...dashboard, suspended_organizers: [{ profile_id: 6, business_name: 'Night Market', owner_email: 'owner@market.test', suspended_at: null, verification_notes: 'Refund complaints.' }] } })
    apiClient.patch.mockResolvedValue({ data: { id: 6, verification_status: 'verified' } })
    render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    const section = await screen.findByRole('region', { name: 'Sales paused' })
    expect(section).toHaveTextContent('Refund complaints.')
    await user.click(within(section).getByRole('button', { name: 'Resume sales for Night Market' }))
    const dialog = screen.getByRole('dialog', { name: 'Resume sales for Night Market?' })
    await user.click(within(dialog).getByRole('button', { name: 'Resume sales' }))
    expect(apiClient.patch).toHaveBeenCalledWith('/admin/organizer_profiles/6', { verification_status: 'verified' }, expect.anything())
    expect(await screen.findByText('Sales resumed for Night Market.')).toBeInTheDocument()
  })

  it('says when no organizers are waiting', async () => {
    render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    expect(await screen.findByText('No organizers are waiting.')).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })
})
