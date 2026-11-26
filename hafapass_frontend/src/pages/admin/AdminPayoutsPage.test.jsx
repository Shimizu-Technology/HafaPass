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
  tax_information_snapshot: { legal_name: 'Approved Payee', masked_tin: '***-**-5678' },
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

  it('shows a manual transfer request as not sent yet, and warns not to send it once its approval is out of date', async () => {
    const message = 'The approved statement changed after this payout was approved. Do not send this transfer.'
    respond({ payouts: [
      { ...payout, dispatch: { actionable: true, placeholder: true, reasons: [], messages: [] } },
      { ...payout, id: 13, provider_payout_id: 'manual_po_13', dispatch: { actionable: false, placeholder: true, reasons: ['statement_changed'], messages: [message] } },
    ] })
    renderAt('/admin/payouts')
    expect(await screen.findAllByText('Bank transfer not recorded yet')).toHaveLength(2)
    expect(screen.getByText('Request manual_po_1')).toBeInTheDocument()
    expect(screen.getByText(/Approval is current\. Send the transfer to the approved payee/)).toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveTextContent(message)
    expect(screen.queryByText('manual_po_13')).not.toBeInTheDocument()
  })

  it.each([
    ['check', 'Recorded as paid with the date on the check. This does not confirm the check has cleared.'],
    ['manual', 'Recorded as paid after bank or provider payment confirmation.'],
  ])('describes recorded payment accurately for %s', async (provider, explanation) => {
    respond({ payouts: [{ ...payout, provider }] })
    renderAt('/admin/payouts')
    await userEvent.click(await screen.findByRole('button', { name: 'Record outcome for payout #12' }))
    expect(within(screen.getByRole('dialog')).getByText(explanation)).toBeInTheDocument()
  })

  it.each([{}, { legal_name: 'Approved Payee' }])('records withholding-only evidence without inventing a check, with tax snapshot %j', async taxSnapshot => {
    const user = userEvent.setup()
    apiClient.patch.mockResolvedValue({ data: {} })
    respond({ payouts: [{ ...payout, provider: 'check', disbursement_cents: 0,
      withheld_cents: 1008, carried_withholding_cents: 3192, confirmed_check_amount_cents: 0,
      provider_payout_id: 'withholding_only_12', tax_information_snapshot: taxSnapshot }] })
    renderAt('/admin/payouts')
    await user.click(await screen.findByRole('button', { name: 'Record outcome for payout #12' }))
    const dialog = within(screen.getByRole('dialog'))
    expect(dialog.getByText(/This is a withholding-only payout/)).toHaveTextContent('No check is issued and no money is sent to the payee.')
    expect(dialog.getByText('Recorded as settled through withholding only. No check is issued and no money is sent to the payee.')).toBeInTheDocument()
    expect(dialog.queryByLabelText('Date on the check')).not.toBeInTheDocument()
    expect(dialog.queryByText(/date written on the check|check has cleared|Recorded check amount/)).not.toBeInTheDocument()
    expect(dialog.queryByLabelText('Payee actually paid')).not.toBeInTheDocument()
    expect(dialog.getByLabelText(/Withholding-only reference/)).toHaveValue('withholding_only_12')
    expect(dialog.getByLabelText(/Withholding-only reference/)).toBeDisabled()
    expect(dialog.getByLabelText('Withholding confirmed at')).toBeInTheDocument()
    await user.click(dialog.getByRole('button', { name: 'Record as paid' }))
    expect(dialog.getByText('Enter the withholding record reference.')).toBeInTheDocument()
    expect(dialog.getByText('Enter 0.00 to confirm no money was sent to the payee.')).toBeInTheDocument()
    await user.type(dialog.getByLabelText('Withholding record reference'), 'Withholding ledger line 12')
    await user.type(dialog.getByLabelText('How you confirmed it'), 'Full amount allocated to withholding and prior shortfall; no check issued')
    await user.type(dialog.getByLabelText('Actual amount sent to payee (USD)'), '1.00')
    await user.click(dialog.getByRole('button', { name: 'Record as paid' }))
    expect(dialog.getByText('Enter 0.00 to confirm no money was sent to the payee.')).toBeInTheDocument()
    expect(dialog.queryByLabelText('Check amount adjustment reason')).not.toBeInTheDocument()
    expect(apiClient.patch).not.toHaveBeenCalled()
    await user.clear(dialog.getByLabelText('Actual amount sent to payee (USD)'))
    await user.type(dialog.getByLabelText('Actual amount sent to payee (USD)'), '0.00')
    await user.click(dialog.getByRole('button', { name: 'Record as paid' }))
    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/payouts/12', {
      status: 'paid', provider_payout_id: 'withholding_only_12',
      evidence: { reference: 'Withholding ledger line 12', reason: 'Full amount allocated to withholding and prior shortfall; no check issued',
        confirmed_at: expect.stringMatching(/Z$/), actual_check_amount_cents: 0 },
    }, expect.anything()))
  })

  it('blocks release while buyer refunds remain unresolved and points to recording an already sent transfer', async () => {
    const user = userEvent.setup()
    respond({ payouts: [{ ...payout, status: 'held', held_from_status: 'processing',
      hold_available_cents: 5000, cancellation_refunds_unresolved: true }] })
    apiClient.post.mockResolvedValue({ data: { status: 'processing' } })
    renderAt('/admin/payouts')
    await user.click(await screen.findByRole('button', { name: 'Release hold for payout #12' }))
    const dialog = within(screen.getByRole('dialog', { name: 'Release hold on payout #12' }))
    expect(dialog.getByText(/Resolve all buyer refund liabilities/)).toBeInTheDocument()
    expect(dialog.getByRole('button', { name: 'Release hold' })).toBeDisabled()
    expect(apiClient.post).not.toHaveBeenCalled()
    expect(dialog.getByRole('button', { name: 'Release hold' })).toBeDisabled()
  })

  it('releases a held payout when buyer liability is zero', async () => {
    const user = userEvent.setup()
    respond({ payouts: [{ ...payout, status: 'held', held_from_status: 'pending',
      hold_available_cents: 5000, cancellation_refunds_unresolved: false, outstanding_buyer_balance_cents: 0 }] })
    apiClient.post.mockResolvedValue({ data: { status: 'pending' } })
    renderAt('/admin/payouts')
    await user.click(await screen.findByRole('button', { name: 'Release hold for payout #12' }))
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Release hold' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/payouts/12/release_hold', {}, expect.anything()))
  })

  it('shows a stale held payout amount and disables release until it is reissued', async () => {
    respond({ payouts: [{ ...payout, status: 'held', held_from_status: 'pending', hold_available_cents: 0 }] })
    renderAt('/admin/payouts')
    expect(await screen.findByText('Amount exceeds current net payable; record a failed outcome and reissue.')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Release hold for payout #12' }))
    expect(within(screen.getByRole('dialog')).getByRole('button', { name: 'Release hold' })).toBeDisabled()
  })

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

  it('keeps cancelled-event buyer liability visible and requires already-sent evidence', async () => {
    const user = userEvent.setup()
    respond({ payouts: [{ ...payout, status: 'held', event_cancelled: true, outstanding_buyer_balance_cents: 5250 }] })
    apiClient.patch.mockResolvedValue({ data: {} })
    renderAt('/admin/payouts')
    expect(await screen.findByText('$52.50 still owed to buyers')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Record outcome for payout #12' }))
    const dialog = within(screen.getByRole('dialog'))
    expect(dialog.getByText(/\$52\.50 remains owed to buyers/)).toBeInTheDocument()
    await user.type(dialog.getByLabelText(/Transfer ID/), 'BANK-42')
    await user.type(dialog.getByLabelText('Confirmation reference'), 'Statement 42')
    await user.type(dialog.getByLabelText('How you confirmed it'), 'Bank statement')
    await user.click(dialog.getByRole('button', { name: 'Record as paid' }))
    expect(apiClient.patch).not.toHaveBeenCalled()
    await user.click(dialog.getByRole('checkbox', { name: 'This payout was already sent before the cancellation' }))
    await user.type(dialog.getByLabelText('Reason for recording an already sent payout'), 'Sent before cancellation notice')
    await user.click(dialog.getByRole('button', { name: 'Record as paid' }))
    expect(apiClient.patch).toHaveBeenCalledWith('/admin/payouts/12', expect.objectContaining({
      evidence: expect.objectContaining({ sent_before_cancellation_confirmed: true, cancellation_payout_reason: 'Sent before cancellation notice' }),
    }), expect.anything())
  })

  it('labels a paid payout with outstanding buyer liability for organizer recovery', async () => {
    respond({ payouts: [{ ...payout, status: 'paid', outstanding_buyer_balance_cents: 5250 }] })
    renderAt('/admin/payouts')
    expect(await screen.findByText('Organizer was already paid; recover from organizer')).toBeInTheDocument()
  })

  it('requires prior-send confirmation while buyer refunds are pending even when the unreserved balance is zero', async () => {
    const user = userEvent.setup()
    respond({ payouts: [{ ...payout, status: 'held', event_cancelled: true, outstanding_buyer_balance_cents: 0, cancellation_refunds_unresolved: true }] })
    apiClient.patch.mockResolvedValue({ data: {} })
    renderAt('/admin/payouts')
    await user.click(await screen.findByRole('button', { name: 'Record outcome for payout #12' }))
    const dialog = within(screen.getByRole('dialog'))
    expect(dialog.getByText('Buyer refunds are still pending for this cancelled event.')).toBeInTheDocument()
    await user.type(dialog.getByLabelText(/Transfer ID/), 'BANK-43')
    await user.type(dialog.getByLabelText('Confirmation reference'), 'Statement 43')
    await user.type(dialog.getByLabelText('How you confirmed it'), 'Bank statement')
    await user.click(dialog.getByRole('button', { name: 'Record as paid' }))
    expect(apiClient.patch).not.toHaveBeenCalled()
    await user.click(dialog.getByRole('checkbox', { name: 'This payout was already sent before the cancellation' }))
    await user.type(dialog.getByLabelText('Reason for recording an already sent payout'), 'Sent before cancellation notice')
    await user.click(dialog.getByRole('button', { name: 'Record as paid' }))
    expect(apiClient.patch).toHaveBeenCalledWith('/admin/payouts/12', expect.objectContaining({
      evidence: expect.objectContaining({ sent_before_cancellation_confirmed: true,
        cancellation_payout_reason: 'Sent before cancellation notice' }),
    }), expect.anything())
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

  // CodeRabbit 4707205487: the list says what a reversal needs; on an event
  // with a never-fulfilled capture the dialog asks for the bank's exact return.
  const classifiedPaid = {
    ...payout, status: 'paid', provider_payout_id: 'BOG-TRX-991', paid_at: '2026-10-02T00:00:00Z', allowed_outcomes: ['reversed'],
    reversal: { available: true, return_evidence_required: true, amount_cents: 4200, earliest_returned_at: '2026-10-02T00:00:00.000000Z',
      keeps_transfer_id: true, transfer_id: 'BOG-TRX-991', transfer_sent_at_allowed: false, transfer_sent_at_from: null },
  }

  it('records a reversal on a classified event only with the full exact return, keeping the transfer ID', async () => {
    const user = userEvent.setup()
    respond({ payouts: [classifiedPaid] })
    apiClient.patch.mockResolvedValue({ data: {} })
    renderAt('/admin/payouts')
    await user.click(await screen.findByRole('button', { name: 'Record outcome for payout #12' }))
    const dialog = screen.getByRole('dialog')
    expect(within(dialog).getByRole('radio', { name: /Reversed/ })).toBeChecked()
    const evidence = within(dialog).getByRole('group', { name: 'Bank return evidence (required)' })
    expect(evidence).toHaveTextContent('exact return of the $42.00 that left')
    expect(within(dialog).getByLabelText(/Transfer ID/)).toBeDisabled()
    expect(within(dialog).getByLabelText(/Transfer ID/)).toHaveValue('BOG-TRX-991')
    await user.type(within(dialog).getByLabelText('Confirmation reference'), 'Statement 2026-10-09 line 2')
    await user.type(within(dialog).getByLabelText('How you confirmed it'), 'Bank returned the transfer in full')
    await user.click(within(dialog).getByRole('button', { name: 'Record as reversed' }))
    expect(within(evidence).getByText('Enter the return reference the bank gave for this transfer.')).toBeInTheDocument()
    expect(within(evidence).getByText('Enter the amount the bank returned, in dollars and cents.')).toBeInTheDocument()
    expect(within(evidence).getByLabelText('Bank return reference')).toHaveAttribute('aria-invalid', 'true')

    await user.type(within(evidence).getByLabelText('Bank return reference'), 'RET-0042')
    await user.type(within(evidence).getByLabelText('Amount the bank returned (USD)'), '41.99')
    await user.click(within(dialog).getByRole('button', { name: 'Record as reversed' }))
    expect(within(evidence).getByText(/must have returned the full \$42\.00 that left/)).toBeInTheDocument()
    expect(apiClient.patch).not.toHaveBeenCalled()

    await user.clear(within(evidence).getByLabelText('Amount the bank returned (USD)'))
    await user.type(within(evidence).getByLabelText('Amount the bank returned (USD)'), '42.00')
    await user.click(within(dialog).getByRole('button', { name: 'Record as reversed' }))
    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/payouts/12', {
      status: 'reversed',
      evidence: expect.objectContaining({ return_reference: 'RET-0042', returned_amount_cents: 4200, returned_at: expect.stringMatching(/Z$/) }),
    }, expect.anything()))
    expect(apiClient.patch.mock.calls[0][1].evidence).not.toHaveProperty('transfer_sent_at')
  })

  it('asks for the real transfer ID when the payout holds only the request placeholder', async () => {
    const user = userEvent.setup()
    respond({ payouts: [{ ...payout, reversal: { ...classifiedPaid.reversal, keeps_transfer_id: false, transfer_id: null } }] })
    apiClient.patch.mockResolvedValue({ data: {} })
    renderAt('/admin/payouts')
    await user.click(await screen.findByRole('button', { name: 'Record outcome for payout #12' }))
    const dialog = screen.getByRole('dialog')
    await user.click(within(dialog).getByRole('radio', { name: /Reversed/ }))
    expect(within(dialog).getByLabelText(/Transfer ID \(required\)/)).toBeEnabled()
    await user.type(within(dialog).getByLabelText('Confirmation reference'), 'ref')
    await user.type(within(dialog).getByLabelText('How you confirmed it'), 'reason')
    await user.type(within(dialog).getByLabelText('Bank return reference'), 'RET-0043')
    await user.type(within(dialog).getByLabelText('Amount the bank returned (USD)'), '42')
    await user.click(within(dialog).getByRole('button', { name: 'Record as reversed' }))
    expect(within(dialog).getByText('Enter the real bank or provider ID of the transfer that came back.')).toBeInTheDocument()
    await user.type(within(dialog).getByLabelText(/Transfer ID/), 'BOG-TRX-992')
    await user.click(within(dialog).getByRole('button', { name: 'Record as reversed' }))
    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/payouts/12', expect.objectContaining({
      status: 'reversed', provider_payout_id: 'BOG-TRX-992',
      evidence: expect.objectContaining({ return_reference: 'RET-0043', returned_amount_cents: 4200 }),
    }), expect.anything()))
  })

  it('keeps the ordinary reversal on other events without return fields', async () => {
    const user = userEvent.setup()
    respond({ payouts: [{ ...classifiedPaid, reversal: { available: true, return_evidence_required: false } }] })
    apiClient.patch.mockResolvedValue({ data: {} })
    renderAt('/admin/payouts')
    await user.click(await screen.findByRole('button', { name: 'Record outcome for payout #12' }))
    const dialog = screen.getByRole('dialog')
    expect(within(dialog).queryByRole('group', { name: 'Bank return evidence (required)' })).not.toBeInTheDocument()
    await user.type(within(dialog).getByLabelText('Confirmation reference'), 'ref')
    await user.type(within(dialog).getByLabelText('How you confirmed it'), 'Bank returned it')
    await user.click(within(dialog).getByRole('button', { name: 'Record as reversed' }))
    await waitFor(() => expect(apiClient.patch).toHaveBeenCalled())
    expect(apiClient.patch.mock.calls[0][1].evidence).not.toHaveProperty('return_reference')
  })

  // CodeRabbit 4707205465: an accepted transfer never shows a send
  // instruction, and no impossible outcome is offered.
  it('tells finance not to send an accepted transfer and offers no outcome it would refuse', async () => {
    const reason = 'Record this payout as an accepted transfer first, then record its return.'
    respond({ payouts: [
      { ...payout, status: 'held', provider_payout_id: 'BOG-ACC-1', provider_accepted: true, provider_acceptance_evidence_only: false,
        allowed_outcomes: [], dispatch: null, reversal: { available: false, return_evidence_required: true, unavailable_reason: reason } },
      { ...payout, id: 13, provider_accepted: true, provider_acceptance_evidence_only: true, allowed_outcomes: [], reversal: null,
        dispatch: { actionable: false, placeholder: true, reasons: ['accepted'], messages: ['The provider accepted this transfer, so the money already left. Do not send it again.'] } },
    ] })
    renderAt('/admin/payouts')
    expect(await screen.findByText('The provider accepted this transfer, so the money left. Do not send it again.')).toBeInTheDocument()
    expect(screen.getByText(reason)).toBeInTheDocument()
    expect(screen.getByText(/so the money already left\. Do not send it again\./)).toBeInTheDocument()
    expect(screen.queryByText(/Approval is current/)).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Record outcome/ })).not.toBeInTheDocument()
    expect(screen.getAllByText('No outcome here')).toHaveLength(2)
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

  it('shows the approved check payee and records Paid for changed details only with an explicit confirmation', async () => {
    const user = userEvent.setup()
    apiClient.patch.mockResolvedValue({ data: {} })
    respond({ payouts: [{ ...payout, provider: 'check',
      payee: { payee_name: 'Ambros Inc.', delivery_method: 'pickup', pickup_note: 'Front desk' },
      payee_changed: true, current_payee: { payee_name: 'Someone Else', delivery_method: 'mail', mailing_address: 'PO Box 9' } }] })
    renderAt('/admin/payouts')
    await user.click(await screen.findByRole('button', { name: 'Record outcome for payout #12' }))
    const dialog = within(screen.getByRole('dialog'))
    expect(dialog.getByText(/Ambros Inc\. · Pickup — Front desk/)).toBeInTheDocument()
    expect(dialog.getByText(/Someone Else/)).toBeInTheDocument()
    expect(dialog.queryByText(/Approve the new details in Users/)).not.toBeInTheDocument()
    expect(dialog.getByText(/recorded as paid on the date written on the check, not when it clears/)).toBeInTheDocument()
    await user.type(dialog.getByLabelText(/Check number/), '1042')
    await user.type(dialog.getByLabelText(/Reference/), 'register 7')
    await user.type(dialog.getByLabelText(/Actual amount written on the check/), '42.00')
    await user.type(dialog.getByLabelText('How you confirmed it'), 'written')
    await user.click(dialog.getByRole('button', { name: 'Record as paid' }))
    expect(apiClient.patch).not.toHaveBeenCalled()
    expect(dialog.getByText('Confirm you wrote this check to the approved payee shown above.')).toBeInTheDocument()

    await user.click(dialog.getByRole('checkbox', { name: 'I wrote this check to the approved payee shown above' }))
    await user.click(dialog.getByRole('button', { name: 'Record as paid' }))
    expect(apiClient.patch).toHaveBeenCalledWith('/admin/payouts/12', expect.objectContaining({
      evidence: expect.objectContaining({ approved_payee_confirmed: true, actual_check_amount_cents: 4200 }),
    }), expect.anything())
  })

  it('requires the actual written amount and offers a reasoned adjustment for a mismatch', async () => {
    const user = userEvent.setup()
    apiClient.post.mockResolvedValue({ data: { check_amount_cents: 4199 } })
    apiClient.patch.mockResolvedValue({ data: {} })
    respond({ payouts: [{ ...payout, provider: 'check', disbursement_cents: 4200,
      confirmed_check_amount_cents: 4200, payee: { payee_name: 'Ambros Inc.', delivery_method: 'pickup' } }] })
    renderAt('/admin/payouts')
    await user.click(await screen.findByRole('button', { name: 'Record outcome for payout #12' }))
    const dialog = within(screen.getByRole('dialog'))
    await user.type(dialog.getByLabelText(/Check number/), '1042')
    await user.type(dialog.getByLabelText(/Reference/), 'register 7')
    await user.type(dialog.getByLabelText('How you confirmed it'), 'Check register review')
    await user.click(dialog.getByRole('button', { name: 'Record as paid' }))
    expect(dialog.getByText('Enter the actual check amount in dollars and cents.')).toBeInTheDocument()
    await user.type(dialog.getByLabelText(/Actual amount written on the check/), '41.99')
    await user.type(dialog.getByLabelText('Check amount adjustment reason'), 'Check register differs by one cent')
    await user.click(dialog.getByRole('button', { name: 'Record audited adjustment' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/payouts/12/check_amount_adjustment',
      { actual_check_amount_cents: 4199, reason: 'Check register differs by one cent' }, expect.anything()))
    await user.click(dialog.getByRole('button', { name: 'Record as paid' }))
    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/payouts/12', expect.objectContaining({
      evidence: expect.objectContaining({ actual_check_amount_cents: 4199 }),
    }), expect.anything()))
  })

  it('requires confirmation for a changed W-9 approval before recording paid', async () => {
    const user = userEvent.setup()
    apiClient.patch.mockResolvedValue({ data: {} })
    respond({ payouts: [{ ...payout, tax_approval_changed: true,
      tax_information_snapshot: { legal_name: 'Original Payee', masked_tin: '***-**-5678' } }] })
    renderAt('/admin/payouts')
    await user.click(await screen.findByRole('button', { name: 'Record outcome for payout #12' }))
    const dialog = within(screen.getByRole('dialog'))
    expect(dialog.getByText(/Original Payee/)).toBeInTheDocument()
    await user.type(dialog.getByLabelText(/Transfer ID/), 'BOG-TRX-991')
    await user.type(dialog.getByLabelText('Confirmation reference'), 'Statement line 4')
    await user.type(dialog.getByLabelText('How you confirmed it'), 'Matched the transfer')
    await user.click(dialog.getByRole('button', { name: 'Record as paid' }))
    expect(apiClient.patch).not.toHaveBeenCalled()
    await user.click(dialog.getByRole('checkbox', { name: 'This payout was already sent to the approved payee shown above' }))
    await user.click(dialog.getByRole('button', { name: 'Record as paid' }))
    expect(apiClient.patch).toHaveBeenCalledWith('/admin/payouts/12', expect.objectContaining({
      evidence: expect.objectContaining({ approved_tax_payee_confirmed: true }),
    }), expect.anything())
  })

  it('records who was actually paid for a legacy payout without an approved W-9 snapshot', async () => {
    const user = userEvent.setup()
    apiClient.patch.mockResolvedValue({ data: {} })
    respond({ payouts: [{ ...payout, tax_approval_changed: true, tax_information_snapshot: {} }] })
    renderAt('/admin/payouts')
    await user.click(await screen.findByRole('button', { name: 'Record outcome for payout #12' }))
    const dialog = within(screen.getByRole('dialog'))
    expect(dialog.queryByRole('checkbox', { name: /approved payee shown above/ })).not.toBeInTheDocument()
    await user.type(dialog.getByLabelText(/Transfer ID/), 'BOG-TRX-991')
    await user.type(dialog.getByLabelText('Confirmation reference'), 'Statement line 4')
    await user.type(dialog.getByLabelText('How you confirmed it'), 'Matched the transfer')
    await user.click(dialog.getByRole('button', { name: 'Record as paid' }))
    expect(apiClient.patch).not.toHaveBeenCalled()
    expect(dialog.getByText('Enter the payee who was actually paid.')).toBeInTheDocument()
    await user.type(dialog.getByLabelText('Payee actually paid'), 'Actual Guam Payee')
    await user.type(dialog.getByLabelText('Evidence note or reference'), 'Check 1042')
    await user.click(dialog.getByRole('checkbox', { name: /created before W-9 collection/ }))
    await user.click(dialog.getByRole('button', { name: 'Record as paid' }))
    expect(apiClient.patch).toHaveBeenCalledWith('/admin/payouts/12', expect.objectContaining({
      evidence: expect.objectContaining({ legacy_payee_name: 'Actual Guam Payee', legacy_evidence_note: 'Check 1042', legacy_payee_confirmed: true }),
    }), expect.anything())
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
