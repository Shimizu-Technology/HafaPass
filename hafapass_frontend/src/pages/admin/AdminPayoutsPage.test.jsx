import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import AdminPayoutsPage from './AdminPayoutsPage'

vi.mock('../../api/client', async importOriginal => ({ ...await importOriginal(), default: { get: vi.fn(), patch: vi.fn(), post: vi.fn(), delete: vi.fn() } }))
vi.mock('./AdminLayout', () => ({ default: ({ children }) => <div>{children}</div> }))

const payout = {
  id: 12, status: 'processing', amount_cents: 4200, currency: 'usd', provider: 'manual', provider_payout_id: 'manual_po_1',
  created_at: '2026-10-01T00:00:00Z', organization: { id: 1, name: 'GuamTime Events' }, event: { id: 4, title: 'Night Market', slug: 'night-market' },
  settlement: { id: 3, version: 2 }, allowed_outcomes: ['paid', 'failed', 'reversed'], conflict_audit_id: null, conflict: null, last_reconciliation: null,
}
const context = { event: { id: 4, title: 'Night Market' }, organization: { id: 1, name: 'GuamTime Events', currency: 'usd' } }
const meta = { page: 1, total_pages: 1, total_count: 1 }

function respond({ payouts = [payout], adjustments = [] } = {}) {
  apiClient.get.mockImplementation((path, config) => {
    if (path === '/admin/balance_adjustments') return Promise.resolve({ data: { balance_adjustments: adjustments, meta } })
    return Promise.resolve({ data: { payouts, meta, status_counts: { pending: 0, processing: payouts.length, paid: 0, failed: 0, reversed: 0 }, context: config.params.event_id ? context : null } })
  })
}
const renderAt = path => render(<MemoryRouter initialEntries={[path]}><AdminPayoutsPage /></MemoryRouter>)

describe('AdminPayoutsPage', () => {
  beforeEach(() => { vi.clearAllMocks(); respond() })

  it('lists payouts with their context and records a paid outcome with evidence', async () => {
    const user = userEvent.setup()
    apiClient.patch.mockResolvedValue({ data: {} })
    renderAt('/admin/payouts?event_id=4')
    expect(await screen.findByText(/Showing/)).toHaveTextContent('Night Market · GuamTime Events')
    await user.click(await screen.findByRole('button', { name: 'Record outcome for payout #12' }))
    const dialog = screen.getByRole('dialog', { name: 'Record outcome for payout #12' })
    // A placeholder reference is never offered as proof of payment.
    expect(within(dialog).getByLabelText(/Transfer ID/)).toHaveValue('')
    await user.click(within(dialog).getByRole('button', { name: 'Record as paid' }))
    expect(within(dialog).getByText('Enter the real bank or provider transfer ID.')).toBeInTheDocument()
    expect(apiClient.patch).not.toHaveBeenCalled()

    await user.type(within(dialog).getByLabelText(/Transfer ID/), 'BOG-TRX-991')
    await user.type(within(dialog).getByLabelText('Confirmation reference'), 'Statement 2026-10-02 line 4')
    await user.type(within(dialog).getByLabelText('How you confirmed it'), 'Matched amount on the bank statement')
    await user.click(within(dialog).getByRole('button', { name: 'Record as paid' }))

    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/payouts/12', {
      status: 'paid', provider_payout_id: 'BOG-TRX-991',
      evidence: expect.objectContaining({ reference: 'Statement 2026-10-02 line 4', reason: 'Matched amount on the bank statement', confirmed_at: expect.stringMatching(/Z$/) }),
    }, expect.anything()))
    expect(await screen.findByRole('status')).toHaveTextContent('Payout #12 recorded as paid.')
  })

  it('requires acknowledging a provider conflict before recording an outcome', async () => {
    const user = userEvent.setup()
    respond({ payouts: [{ ...payout, failure_code: 'provider_result_conflict', conflict_audit_id: 77,
      conflict: { audit_id: 77, occurred_at: '2026-10-02T00:00:00Z', recorded_before: { status: 'failed' }, provider_result: { status: 'paid', provider_payout_id: 'po_late' } } }] })
    apiClient.patch.mockResolvedValue({ data: {} })
    renderAt('/admin/payouts')
    await user.click(await screen.findByRole('button', { name: 'Record outcome for payout #12' }))
    const dialog = screen.getByRole('dialog')
    expect(dialog).toHaveTextContent('Provider now reports: Paid (po_late)')
    await user.click(within(dialog).getByRole('radio', { name: /Failed/ }))
    await user.type(within(dialog).getByLabelText('Confirmation reference'), 'ref')
    await user.type(within(dialog).getByLabelText('How you confirmed it'), 'reason')
    await user.click(within(dialog).getByRole('button', { name: 'Record as failed' }))
    expect(within(dialog).getByText('Confirm you reviewed the provider conflict.')).toBeInTheDocument()
    await user.click(within(dialog).getByRole('checkbox', { name: 'I reviewed conflict audit #77' }))
    await user.click(within(dialog).getByRole('button', { name: 'Record as failed' }))
    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/payouts/12', expect.objectContaining({
      status: 'failed', evidence: expect.objectContaining({ conflict_audit_id: 77 }),
    }), expect.anything()))
  })

  it('shows a server rejection inside the dialog without closing it', async () => {
    const user = userEvent.setup()
    apiClient.patch.mockRejectedValue({ response: { status: 422, data: { error: 'Confirmation time must be after the payout request and not in the future' } } })
    renderAt('/admin/payouts')
    await user.click(await screen.findByRole('button', { name: 'Record outcome for payout #12' }))
    const dialog = screen.getByRole('dialog')
    await user.click(within(dialog).getByRole('radio', { name: /Failed/ }))
    await user.type(within(dialog).getByLabelText('Confirmation reference'), 'ref')
    await user.type(within(dialog).getByLabelText('How you confirmed it'), 'reason')
    await user.click(within(dialog).getByRole('button', { name: 'Record as failed' }))
    expect(await within(dialog).findByRole('alert')).toHaveTextContent('Confirmation time must be after the payout request')
  })

  it('shows the approved check payee and blocks Paid when the payee changed after approval', async () => {
    const user = userEvent.setup()
    respond({ payouts: [{ ...payout, provider: 'check',
      payee: { payee_name: 'Ambros Inc.', delivery_method: 'pickup', pickup_note: 'Front desk' },
      payee_changed: true, current_payee: { payee_name: 'Someone Else', delivery_method: 'mail', mailing_address: 'PO Box 9' } }] })
    renderAt('/admin/payouts')
    await user.click(await screen.findByRole('button', { name: 'Record outcome for payout #12' }))
    const dialog = within(screen.getByRole('dialog'))
    expect(dialog.getByText(/Ambros Inc\. · Pickup — Front desk/)).toBeInTheDocument()
    expect(dialog.getAllByText('Payee details changed after approval — review before writing the check.').length).toBeGreaterThan(0)
    expect(dialog.getByText(/Someone Else/)).toBeInTheDocument()
    expect(dialog.getByText(/recorded as paid on the date written on the check, not when it clears/)).toBeInTheDocument()
    expect(dialog.getByLabelText(/Check number/)).toBeInTheDocument()
    await user.type(dialog.getByLabelText(/Check number/), '1042')
    await user.type(dialog.getByLabelText(/Reference/), 'register 7')
    await user.type(dialog.getByLabelText('How you confirmed it'), 'written')
    await user.click(dialog.getByRole('button', { name: 'Record as paid' }))
    expect(apiClient.patch).not.toHaveBeenCalled()
  })

  it('shows an empty state for a filtered list', async () => {
    respond({ payouts: [] })
    renderAt('/admin/payouts?status=failed')
    expect(await screen.findByText('No payouts match these filters.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Failed/ })).toHaveAttribute('aria-pressed', 'true')
  })

  it('posts a signed balance adjustment only after a review step', async () => {
    const user = userEvent.setup()
    apiClient.post.mockResolvedValue({ data: {} })
    renderAt('/admin/payouts?event_id=4&view=adjustments')
    expect(await screen.findByText('No balance adjustments.')).toBeInTheDocument()
    await user.click(await screen.findByRole('button', { name: 'New adjustment' }))
    const dialog = screen.getByRole('dialog', { name: 'New balance adjustment' })
    await user.click(within(dialog).getByRole('radio', { name: /Hold in reserve/ }))
    await user.type(within(dialog).getByLabelText('Amount ($)'), '50')
    await user.type(within(dialog).getByLabelText('Reason'), 'Chargeback risk')
    await user.click(within(dialog).getByRole('button', { name: 'Review adjustment' }))

    expect(screen.getByRole('dialog', { name: 'Post this adjustment?' })).toHaveTextContent('−$50.00')
    expect(apiClient.post).not.toHaveBeenCalled()
    await user.click(screen.getByRole('button', { name: 'Post adjustment' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/balance_adjustments', {
      organization_id: 1, event_id: 4, kind: 'reserve_hold', amount_cents: -5000, reason: 'Chargeback risk',
    }, expect.anything()))
  })

  it('only offers new adjustments from an organization or event context', async () => {
    renderAt('/admin/payouts?view=adjustments')
    expect(await screen.findByText(/open payouts from an event/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'New adjustment' })).not.toBeInTheDocument()
  })

  it('reverses a posted adjustment with a reason', async () => {
    const user = userEvent.setup()
    respond({ adjustments: [{ id: 9, kind: 'manual_credit', amount_cents: 500, currency: 'usd', status: 'posted', reason: 'Goodwill', created_at: '2026-10-01T00:00:00Z',
      organization: { id: 1, name: 'GuamTime Events' }, event: null, created_by: 'admin@example.com', reversal_of_id: null }] })
    apiClient.delete.mockResolvedValue({ data: {} })
    renderAt('/admin/payouts?view=adjustments')
    await user.click(await screen.findByRole('button', { name: 'Reverse adjustment #9' }))
    const dialog = screen.getByRole('dialog', { name: 'Reverse adjustment #9?' })
    expect(dialog).toHaveTextContent('-$5.00')
    await user.click(within(dialog).getByRole('button', { name: 'Post reversal' }))
    expect(within(dialog).getByRole('alert')).toHaveTextContent('Explain why')
    await user.type(within(dialog).getByLabelText('Reason'), 'Entered twice')
    await user.click(within(dialog).getByRole('button', { name: 'Post reversal' }))
    await waitFor(() => expect(apiClient.delete).toHaveBeenCalledWith('/admin/balance_adjustments/9', expect.objectContaining({ data: { reason: 'Entered twice' } })))
  })
})
