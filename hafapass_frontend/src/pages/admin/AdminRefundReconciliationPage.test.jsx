import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import AdminRefundReconciliationPage from './AdminRefundReconciliationPage'

vi.mock('../../api/client', async importOriginal => ({ ...await importOriginal(), default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('./AdminLayout', () => ({ default: ({ children }) => <div>{children}</div> }))

const item = {
  id: 9, type: 'refund', order_id: 42, order_reference: 'HP-42', buyer_email: 'buyer@example.test',
  event_id: 4, event_title: 'Night Market', organization_name: 'GuamTime Events', amount_cents: 5250,
  reason: 'Provider has not confirmed the return', status: 'pending', age_seconds: 4 * 86400,
  next_action: 'Check Stripe status', manual_type: null,
}
const respond = items => apiClient.get.mockResolvedValue({ data: { items, meta: { page: 1, total_pages: 1, total_count: items.length } } })
const mount = () => render(<MemoryRouter initialEntries={['/admin/refund_reconciliation']}><AdminRefundReconciliationPage /></MemoryRouter>)

describe('AdminRefundReconciliationPage', () => {
  beforeEach(() => { vi.clearAllMocks(); respond([item]); apiClient.post.mockResolvedValue({ data: {} }) })

  it('shows liability context and filters status, age and event', async () => {
    const user = userEvent.setup()
    mount()
    expect(await screen.findByText('HP-42')).toBeInTheDocument()
    expect(screen.getByText('buyer@example.test')).toBeInTheDocument()
    expect(screen.getByText('Night Market')).toBeInTheDocument()
    expect(screen.getByText('GuamTime Events')).toBeInTheDocument()
    expect(screen.getByText('$52.50')).toBeInTheDocument()
    expect(screen.getByText('4 days')).toHaveClass('text-red-700')
    await user.selectOptions(screen.getByLabelText('Status'), 'failed')
    await user.selectOptions(screen.getByLabelText('Age'), '3')
    await user.type(screen.getByLabelText('Event number'), '4')
    await user.click(screen.getByRole('button', { name: 'Apply' }))
    await waitFor(() => expect(apiClient.get).toHaveBeenLastCalledWith('/admin/refund_reconciliation',
      expect.objectContaining({ params: { status: 'failed', age_days: '3', event_id: '4', page: 1 } })))
  })

  it('flags outstanding buyer liability when the organizer was already paid', async () => {
    respond([{ ...item, organizer_already_paid: true }])
    mount()
    expect(await screen.findByText('Organizer was already paid; recover from organizer')).toBeInTheDocument()
  })

  it('checks a pending refund through the resync action', async () => {
    const user = userEvent.setup()
    mount()
    await user.click(await screen.findByRole('button', { name: 'Check Stripe status' }))
    const dialog = within(screen.getByRole('dialog'))
    await user.click(dialog.getByRole('button', { name: 'Check Stripe status' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/refund_reconciliation/refund/9/resync', {}, expect.anything()))
    expect(await screen.findByRole('status')).toHaveTextContent('Stripe status checked')
  })

  it('retrieves external refund operations from the finance exception action', async () => {
    respond([{ ...item, type: 'exception', status: 'provider_review' }])
    const user = userEvent.setup()
    mount()
    expect(await screen.findByText('External refund needs verification')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Check Stripe status' }))
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Check Stripe status' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/refund_reconciliation/exception/9/resync', {}, expect.anything()))
    expect(await screen.findByRole('status')).toHaveTextContent('Stripe status checked')
  })

  it('requires manual return evidence and sends the reference, date and note', async () => {
    const user = userEvent.setup()
    respond([{ ...item, type: 'cancellation', id: 21, status: 'needs_manual', manual_type: 'cash' }])
    mount()
    await user.click(await screen.findByRole('button', { name: 'Record cash return' }))
    const dialog = within(screen.getByRole('dialog'))
    await user.click(dialog.getByRole('button', { name: 'Record cash return' }))
    expect(dialog.getByRole('alert')).toHaveTextContent('Enter a reference')
    expect(apiClient.post).not.toHaveBeenCalled()
    await user.type(dialog.getByLabelText('Cash return reference'), 'receipt-42')
    await user.type(dialog.getByLabelText('How the return was confirmed'), 'Receipt signed by buyer')
    await user.click(dialog.getByRole('button', { name: 'Record cash return' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/refund_reconciliation/cancellation/21/manual_return',
      expect.objectContaining({ reference: 'receipt-42', returned_at: expect.any(String), note: 'Receipt signed by buyer' }), expect.anything()))
  })

  it('keeps an unable refund visible and requires a reason', async () => {
    const user = userEvent.setup()
    mount()
    await user.click(await screen.findByRole('button', { name: 'Mark unable to refund' }))
    const dialog = within(screen.getByRole('dialog'))
    await user.click(dialog.getByRole('button', { name: 'Mark unable to refund' }))
    expect(dialog.getByRole('alert')).toHaveTextContent('Explain why')
    expect(apiClient.post).not.toHaveBeenCalled()
    await user.type(dialog.getByLabelText('Why the refund cannot be completed'), 'Buyer unreachable after two attempts')
    await user.click(dialog.getByRole('button', { name: 'Mark unable to refund' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/refund_reconciliation/refund/9/unable',
      { reason: 'Buyer unreachable after two attempts' }, expect.anything()))
    expect(await screen.findByRole('status')).toHaveTextContent('amount remains owed')
  })

  it('offers retry on failed refunds and keeps server errors in the dialog', async () => {
    const user = userEvent.setup()
    respond([{ ...item, status: 'failed' }])
    apiClient.post.mockRejectedValue({ response: { status: 422, data: { error: 'Original provider result is uncertain' } } })
    mount()
    await user.click(await screen.findByRole('button', { name: 'Retry refund' }))
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Retry refund' }))
    expect(await within(screen.getByRole('dialog')).findByRole('alert')).toHaveTextContent('Original provider result is uncertain')
    expect(apiClient.post).toHaveBeenCalledWith('/admin/refund_reconciliation/refund/9/retry', {}, expect.anything())
  })

  it('offers retry for a cancelled Stripe refund', async () => {
    const user = userEvent.setup()
    respond([{ ...item, status: 'cancelled', next_action: 'Review and retry the Stripe refund' }])
    mount()
    await user.click(await screen.findByRole('button', { name: 'Retry refund' }))
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Retry refund' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/refund_reconciliation/refund/9/retry', {}, expect.anything()))
  })

  it('shows an aggregate gap as provider verification, never as still owed or another refund', async () => {
    respond([{ ...item, type: 'exception', status: 'provider_review', amount_cents: 0, buyer_amount_cents: null,
      provider_amount_kind: 'aggregate', provider_reported_amount_cents: 3000,
      provider_verification_amount_cents: 2000, organizer_already_paid: true }])
    const user = userEvent.setup()
    mount()
    expect(await screen.findByText('Buyer balance needs verification')).toBeInTheDocument()
    expect(screen.getByText(/Stripe reports.*\$30.00.*returned in total/)).toBeInTheDocument()
    expect(screen.getByText(/\$20.00.*not yet matched to booked refunds/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Retry refund|Issue refund|Record.*return|Mark unable/ })).not.toBeInTheDocument()
    expect(screen.queryByText('Organizer was already paid; recover from organizer')).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Check Stripe status' }))
    const dialog = within(screen.getByRole('dialog'))
    expect(dialog.queryByText(/still owed/)).not.toBeInTheDocument()
    expect(dialog.getByText(/does not send another refund/)).toBeInTheDocument()
    await user.click(dialog.getByRole('button', { name: 'Check Stripe status' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/refund_reconciliation/exception/9/resync', {}, expect.anything()))
  })

  it.each([null, 0, 1200])('keeps operation amount %s distinct from buyer owed', async amount => {
    respond([{ ...item, type: 'exception', status: 'provider_review', amount_cents: 0, buyer_amount_cents: null,
      provider_amount_kind: 'operation', provider_reported_amount_cents: amount,
      provider_verification_amount_cents: amount }])
    mount()
    expect(await screen.findByText('Buyer balance needs verification')).toBeInTheDocument()
    expect(screen.queryByText(/still owed/)).not.toBeInTheDocument()
    if (amount === null) expect(screen.getByText('Provider operation amount is unknown.')).toBeInTheDocument()
    else expect(screen.getByText(/Provider operation amount:/)).toHaveTextContent(amount === 0 ? '$0.00' : '$12.00')
  })

  it('keeps related cancellation liability as a recorded amount and requires provider verification before retry', async () => {
    respond([{ ...item, type: 'cancellation', status: 'failed', buyer_amount_unverified: true,
      organizer_already_paid: true, amount_cents: 4250 }])
    mount()
    expect(await screen.findByText('Buyer balance needs verification')).toBeInTheDocument()
    expect(screen.getByText('Recorded liability: $42.50')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Retry refund|Issue refund|Mark unable/ })).not.toBeInTheDocument()
  })

})
