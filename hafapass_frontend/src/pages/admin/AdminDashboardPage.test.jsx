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

  it('shows pending edits and sends the reviewed version with approval', async () => {
    const user = userEvent.setup()
    apiClient.get.mockResolvedValue({ data: { ...dashboard, organizers_awaiting_verification: [{
      profile_id: 4, business_name: 'Island Events', verification_status: 'pending', requested_at: '2026-10-23T00:00:00Z',
      verification_request_version: 3, verification_change_diff: {
        verification_phone: { before: '+1-671-555-1234', after: '+1-671-555-5678' },
      },
    }] } })
    apiClient.patch.mockResolvedValue({ data: { verification_status: 'verified' } })
    render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    expect(await screen.findByText('Updated after submission — review again')).toBeInTheDocument()
    expect(screen.getByText(/verification phone:.*555-1234.*555-5678/)).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Verify Island Events' }))
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Verify' }))
    expect(apiClient.patch).toHaveBeenCalledWith('/admin/organizer_profiles/4', {
      verification_status: 'verified', verification_request_version: 3,
    }, expect.anything())
  })

  it('shows descriptions and notes with an expandable long description', async () => {
    apiClient.get.mockResolvedValue({ data: { ...dashboard, organizers_awaiting_verification: [{
      profile_id: 4, business_name: 'Island Events', verification_status: 'pending',
      requested_at: '2026-10-23T00:00:00Z', business_description: 'Guam events ' + 'A'.repeat(300),
      verification_request_note: 'Call after lunch', verification_link: 'https://instagram.com/islandevents',
    }] } })
    render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    expect(await screen.findByText('Business description')).toBeInTheDocument()
    expect(screen.getByText('Note: Call after lunch')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'instagram.com/islandevents' })).toHaveAttribute('href', 'https://instagram.com/islandevents')
    expect(screen.getByText('Requested Oct 23, 2026')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Show more' }))
    expect(screen.getByText(/A{300}/)).toBeInTheDocument()
  })

  it('keeps real requests above a collapsed not-requested section', async () => {
    apiClient.get.mockResolvedValue({ data: { ...dashboard, organizers_awaiting_verification: [
      { profile_id: 1, business_name: 'No request', verification_status: 'unverified' },
      { profile_id: 4, business_name: 'Rejected without a request', verification_status: 'rejected' },
      { profile_id: 2, business_name: 'Older request', verification_status: 'pending', requested_at: '2026-10-21T00:00:00Z' },
      { profile_id: 3, business_name: 'Newest request', verification_status: 'pending', requested_at: '2026-10-23T00:00:00Z' },
    ] } })
    render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    expect(await screen.findByRole('heading', { name: 'Requested (newest first) (2)' })).toBeInTheDocument()
    const names = screen.getAllByRole('button', { name: /^Verify / }).map(button => button.getAttribute('aria-label') || button.textContent)
    expect(names.slice(0, 2).join(' ')).toContain('Newest request')
    expect(screen.getByText('Not requested yet (2)').closest('details')).not.toHaveAttribute('open')
  })

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
    expect(screen.getByText('Buyer payments (less refunds)')).toBeInTheDocument()
    expect(screen.getByText('Organizer proceeds (excluding cash)')).toBeInTheDocument()
    expect(screen.getByText('Before processing costs, holds and payouts already made.')).toBeInTheDocument()
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

  it('approves the policy register without an extra acknowledgment and warns about expiring approvals in amber', async () => {
    const user = userEvent.setup()
    const setup = [
      { key: 'policy_register', label: 'Production policy register', message: 'Checkout is off until you approve the production policy register.', configured: true, help: null,
        expires_at: null, expiring_soon: false },
      { key: 'resend_production', label: 'Production email (Resend)', message: 'The production email approval expires on Nov 10, 2026. Approve again to keep email on.', configured: true, help: null,
        expires_at: '2026-11-10T00:00:00Z', expiring_soon: true },
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
    expect(confirm).toBeEnabled()
    expect(within(dialog).queryByRole('checkbox')).not.toBeInTheDocument()
    await user.click(confirm)
    expect(apiClient.post).toHaveBeenCalledWith('/admin/platform_capabilities/policy_register/quick_approve', {}, expect.anything())
  })

  it('verifies a waiting organizer with an optional note, then refreshes', async () => {
    const user = userEvent.setup()
    const waiting = { profile_id: 4, business_name: 'Reef Nights', organization_id: 9, owner_email: 'owner@reef.test', requested_at: '2026-10-20T22:00:00Z', verification_status: 'pending', payout_ready: false, event_count: 2 }
    apiClient.get.mockResolvedValueOnce({ data: { ...dashboard, organizers_awaiting_verification: [waiting, { profile_id: 5, business_name: 'Quiet Org', requested_at: null, verification_status: 'unverified', payout_ready: true, event_count: 1 }], verified_organizers: [] } })
      .mockResolvedValue({ data: { ...dashboard, organizers_awaiting_verification: [], verified_organizers: [{ profile_id: 4, business_name: 'Reef Nights', verified_at: '2026-10-21T00:00:00Z', verified_by: 'admin@hafapass.test' }] } })
    apiClient.patch.mockResolvedValue({ data: { id: 4, verification_status: 'verified' } })
    render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    const section = await screen.findByRole('region', { name: /Requested \(newest first\)/ })
    expect(section).toHaveTextContent('Owner: owner@reef.test')
    expect(section).toHaveTextContent('Requested')
    expect(section).toHaveTextContent('0 published awaiting · Payout details: Not ready')
    expect(section).toHaveTextContent('Not requested yet')
    await user.click(within(section).getByRole('button', { name: 'Verify Reef Nights' }))
    const dialog = screen.getByRole('dialog', { name: 'Verify Reef Nights?' })
    expect(dialog).toHaveTextContent('Eligible published events can become public. Ticket sales still depend on event setup, sales dates, availability and any holds.')
    expect(dialog).toHaveTextContent("Paid tickets can't sell until it is; free tickets can.")
    await user.type(within(dialog).getByRole('textbox', { name: /Note/ }), 'Checked with the owner.')
    await user.click(within(dialog).getByRole('button', { name: 'Verify' }))
    expect(apiClient.patch).toHaveBeenCalledWith('/admin/organizer_profiles/4', { verification_status: 'verified', verification_notes: 'Checked with the owner.' }, expect.anything())
    expect(await screen.findByText('Reef Nights is verified. Eligible published events can appear publicly.')).toBeInTheDocument()
    expect(await within(section).findByText('No requests yet.')).toBeInTheDocument()
    expect(screen.getByRole('region', { name: 'Verified organizers' })).toHaveTextContent('Verified')
  })

  it('requires a review note before rejecting an organizer', async () => {
    const user = userEvent.setup()
    apiClient.get.mockResolvedValue({ data: { ...dashboard, organizers_awaiting_verification: [{ profile_id: 4,
      business_name: 'Reef Nights', verification_status: 'pending', requested_at: '2026-10-23T00:00:00Z', verification_phone: '+1-671-555-1234',
      verification_link: 'https://instagram.com/reef', verification_request_note: 'First show in Tumon',
      published_awaiting_events_count: 2 }] } })
    apiClient.patch.mockResolvedValue({ data: { id: 4, verification_status: 'rejected' } })
    render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    const section = await screen.findByRole('region', { name: /Requested \(newest first\)/ })
    expect(section).toHaveTextContent('+1-671-555-1234')
    expect(section).toHaveTextContent('First show in Tumon')
    expect(section).toHaveTextContent('2 published awaiting')
    await user.click(within(section).getByRole('button', { name: 'Reject Reef Nights' }))
    const dialog = screen.getByRole('dialog', { name: "Reject Reef Nights's request?" })
    await user.click(within(dialog).getByRole('button', { name: 'Reject request' }))
    expect(within(dialog).getByRole('alert')).toHaveTextContent('Add a note')
    expect(apiClient.patch).not.toHaveBeenCalled()
    await user.type(within(dialog).getByRole('textbox', { name: /Note/ }), 'Link the event social page.')
    await user.click(within(dialog).getByRole('button', { name: 'Reject request' }))
    expect(apiClient.patch).toHaveBeenCalledWith('/admin/organizer_profiles/4',
      { verification_status: 'rejected', verification_notes: 'Link the event social page.' }, expect.anything())
  })

  it('pauses all sales for a verified organizer after explaining what pausing does', async () => {
    const user = userEvent.setup()
    apiClient.get.mockResolvedValue({ data: { ...dashboard, organizers_awaiting_verification: [], verified_organizers: [{ profile_id: 4, business_name: 'Reef Nights', verified_at: '2026-10-21T00:00:00Z', verified_by: null }] } })
    apiClient.patch.mockRejectedValueOnce({ response: { status: 422, data: { error: 'Verification status is invalid.' } } }).mockResolvedValue({ data: { id: 4 } })
    render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    const section = await screen.findByRole('region', { name: 'Verified organizers' })
    await user.click(within(section).getByRole('button', { name: 'Suspend Reef Nights' }))
    const dialog = screen.getByRole('dialog', { name: 'Suspend Reef Nights?' })
    expect(dialog).toHaveTextContent('Their events disappear from public pages and new sales stop. Tickets already sold stay valid.')
    await user.click(within(dialog).getByRole('button', { name: 'Suspend' }))
    expect(await within(dialog).findByRole('alert')).toHaveTextContent('Verification status is invalid.')
    await user.type(within(dialog).getByRole('textbox', { name: /Note/ }), 'Refund complaints')
    await user.click(within(dialog).getByRole('button', { name: 'Suspend' }))
    expect(apiClient.patch).toHaveBeenLastCalledWith('/admin/organizer_profiles/4', { verification_status: 'suspended', verification_notes: 'Refund complaints' }, expect.anything())
    expect(await screen.findByText("Reef Nights's events are hidden and sales are paused.")).toBeInTheDocument()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  it('lists organizers whose sales are paused and resumes them with an optional note', async () => {
    const user = userEvent.setup()
    apiClient.get.mockResolvedValue({ data: { ...dashboard, suspended_organizers: [{ profile_id: 6, business_name: 'Night Market', owner_email: 'owner@market.test', suspended_at: null, verification_notes: 'Refund complaints.' }] } })
    apiClient.patch.mockResolvedValue({ data: { id: 6, verification_status: 'verified' } })
    render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    const section = await screen.findByRole('region', { name: 'Suspended organizers' })
    expect(section).toHaveTextContent('Refund complaints.')
    await user.click(within(section).getByRole('button', { name: 'Restore Night Market' }))
    const dialog = screen.getByRole('dialog', { name: 'Restore Night Market?' })
    await user.click(within(dialog).getByRole('button', { name: 'Restore' }))
    expect(apiClient.patch).toHaveBeenCalledWith('/admin/organizer_profiles/6', { verification_status: 'verified' }, expect.anything())
    expect(await screen.findByText("Night Market is restored. Eligible published events can appear publicly.")).toBeInTheDocument()
  })

  it('says when no organizers are waiting', async () => {
    render(<MemoryRouter initialEntries={['/admin']}><AdminDashboardPage /></MemoryRouter>)
    expect(await screen.findByText('No requests yet.')).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })
})
