import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import AdminReconciliationExceptionsPage from './AdminReconciliationExceptionsPage'

vi.mock('../../api/client', async importOriginal => ({ ...await importOriginal(), default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('./AdminLayout', () => ({ default: ({ children }) => <div>{children}</div> }))

const org = { id: 3, name: 'GuamTime Events' }
const lateCapture = {
  id: 11, code: 'late_payment_success_after_hold_expiry', status: 'open', created_at: '2026-11-01T00:00:00Z', resolved_at: null,
  expected_amount_cents: null, actual_amount_cents: null, webhook_event_id: null, late_capture_owed_cents: 5350,
  order: { id: 42, reference: 'HP-42', buyer_name: 'Ana Cruz', buyer_email: 'ana@example.com', status: 'cancelled', total_cents: 5350, currency: 'usd' },
  payment: { id: 7, provider: 'stripe', provider_environment: 'live', provider_payment_id: 'pi_late', amount_cents: 5350, currency: 'usd', status: 'succeeded' },
  event: { id: 4, title: 'Night Market', status: 'completed' }, organization: org, blocks_payouts: true, actions: ['refund_buyer'],
  resolve_blocked_reason: 'The buyer is still owed $53.50. Use Refund buyer; the exception resolves when the refund succeeds.', resolve_confirmation: null,
}
const fraud = { ...lateCapture, id: 12, code: 'early_fraud_warning', late_capture_owed_cents: undefined, actions: ['fraud_refund', 'resolve'], resolve_blocked_reason: null,
  resolve_confirmation: { flag: 'reviewed_no_action', label: 'I reviewed the order and decided not to refund it.', evidence_note_minimum: 20 } }
const orphan = { ...lateCapture, id: 13, code: 'payment_not_found', late_capture_owed_cents: undefined, order: null, payment: null, event: null, organization: null, blocks_payouts: false, actions: ['resolve'], resolve_blocked_reason: null, resolve_confirmation: null }
const listing = (rows = [lateCapture, fraud, orphan]) => ({ data: {
  reconciliation_exceptions: rows, meta: { page: 1, total_pages: 1, total_count: rows.length },
  status_counts: { open: 3, resolved: 5 },
  open_code_counts: { early_fraud_warning: 1, late_payment_success_after_hold_expiry: 1, payment_not_found: 1 },
  payout_blocks: { organizations: [{ organization: org, open_count: 2, events: [{ id: 4, title: 'Night Market', status: 'completed', open_count: 2 }] }], unlinked_open_count: 1 },
} })
const detail = issue => ({ data: { reconciliation_exception: { details: { warning_id: 'issfr_1' }, history: [], ...issue } } })
const mount = (path = '/admin/reconciliation_exceptions') => render(<MemoryRouter initialEntries={[path]}><AdminReconciliationExceptionsPage /></MemoryRouter>)

describe('AdminReconciliationExceptionsPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.get.mockImplementation(url => Promise.resolve(url.endsWith('/11') ? detail(lateCapture) : url.endsWith('/12') ? detail(fraud) : url.endsWith('/13') ? detail(orphan) : listing()))
  })

  it('shows which organizations have payouts on hold and what each exception holds up', async () => {
    mount()
    const blocks = await screen.findByRole('region', { name: 'Payouts on hold' })
    expect(blocks).toHaveTextContent('GuamTime Events: all payouts held by 2 open exceptions')
    expect(blocks).toHaveTextContent('Statements blocked: Night Market (2)')
    expect(blocks).toHaveTextContent('1 open exception is not linked to an order and does not hold payouts.')
    expect(screen.getAllByText('All payouts for GuamTime Events and the statement for Night Market')).toHaveLength(2)
    expect(screen.getByText('No payouts (not linked to an order)')).toBeInTheDocument()
    expect(screen.getByText('Paid after the hold expired')).toBeInTheDocument()
    expect(screen.getByText('$53.50 owed to the buyer')).toBeInTheDocument()
    expect(screen.getAllByRole('link', { name: 'Order #42' })[0]).toHaveAttribute('href', '/admin/orders?search=%2342')

    await userEvent.click(within(blocks).getByRole('button', { name: /Show these exceptions/ }))
    await waitFor(() => expect(apiClient.get).toHaveBeenLastCalledWith('/admin/reconciliation_exceptions',
      expect.objectContaining({ params: { organization_id: '3', status: 'open', page: 1 } })))
    expect(await screen.findByText('Organization: GuamTime Events')).toBeInTheDocument()
  })

  it('filters by status and code', async () => {
    mount()
    await screen.findByRole('region', { name: 'Payouts on hold' })
    await userEvent.click(screen.getByRole('button', { name: 'Resolved (5)' }))
    await waitFor(() => expect(apiClient.get).toHaveBeenLastCalledWith('/admin/reconciliation_exceptions', expect.objectContaining({ params: { status: 'resolved', page: 1 } })))
    await userEvent.selectOptions(screen.getByRole('combobox', { name: 'Code' }), 'early_fraud_warning')
    await waitFor(() => expect(apiClient.get).toHaveBeenLastCalledWith('/admin/reconciliation_exceptions',
      expect.objectContaining({ params: { status: 'resolved', code: 'early_fraud_warning', page: 1 } })))
  })

  it('refunds a late capture after confirmation', async () => {
    apiClient.post.mockResolvedValue({ data: { refund: { id: 1, status: 'succeeded' }, reconciliation_exception: { ...lateCapture, status: 'resolved', actions: [], late_capture_owed_cents: 0, details: {}, history: [] } } })
    mount()
    await userEvent.click(await screen.findByRole('button', { name: 'Review exception #11' }))
    const dialog = await screen.findByRole('dialog', { name: 'Exception #11' })
    expect(await within(dialog).findByText(/automatic refund normally finishes within minutes/)).toBeInTheDocument()
    expect(dialog).toHaveTextContent('Cannot resolve with a note yet. The buyer is still owed $53.50.')
    expect(within(dialog).queryByRole('textbox', { name: /note/ })).not.toBeInTheDocument()
    await userEvent.click(within(dialog).getByRole('button', { name: 'Refund buyer' }))
    expect(apiClient.post).not.toHaveBeenCalled()
    expect(dialog).toHaveTextContent("Refund $53.50 to the buyer's card?")
    await userEvent.click(within(dialog).getByRole('button', { name: 'Yes, refund buyer' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/reconciliation_exceptions/11/refund_buyer', {}, expect.anything()))
    expect(await screen.findByText('Exception #11: refund sent.')).toBeInTheDocument()
    expect(within(dialog).queryByRole('button', { name: 'Refund buyer' })).not.toBeInTheDocument()
  })

  it('links a fraud warning to the order fraud refund and requires a confirmation and evidence note to resolve', async () => {
    apiClient.post.mockResolvedValue({ data: { reconciliation_exception: { ...fraud, status: 'resolved', actions: [], resolve_confirmation: undefined, details: {}, history: [{ id: 1, action: 'reconciliation_exception.reviewed_no_action', occurred_at: '2026-11-02T00:00:00Z', source: 'admin', actor: { email: 'leon@example.com' }, note: 'Issuer confirmed the purchase is legitimate.' }] } } })
    mount()
    await userEvent.click(await screen.findByRole('button', { name: 'Review exception #12' }))
    const dialog = await screen.findByRole('dialog', { name: 'Exception #12' })
    expect(await within(dialog).findByRole('link', { name: 'Open the order to cancel tickets and refund as fraud' })).toHaveAttribute('href', '/admin/orders?search=%2342')
    expect(within(dialog).getByText('issfr_1')).toBeInTheDocument()
    const submit = within(dialog).getByRole('button', { name: 'Resolve without moving money' })
    await userEvent.click(submit)
    expect(within(dialog).getByRole('alert')).toHaveTextContent('Add a note')
    await userEvent.type(within(dialog).getByRole('textbox', { name: /Evidence note/ }), 'Looks fine.')
    await userEvent.click(submit)
    expect(within(dialog).getByRole('alert')).toHaveTextContent('Tick the confirmation')
    await userEvent.click(within(dialog).getByRole('checkbox', { name: 'I reviewed the order and decided not to refund it.' }))
    await userEvent.click(submit)
    expect(within(dialog).getByRole('alert')).toHaveTextContent('at least 20 characters')
    expect(apiClient.post).not.toHaveBeenCalled()
    await userEvent.clear(within(dialog).getByRole('textbox', { name: /Evidence note/ }))
    await userEvent.type(within(dialog).getByRole('textbox', { name: /Evidence note/ }), 'Issuer confirmed the purchase is legitimate.')
    await userEvent.click(submit)
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/reconciliation_exceptions/12/resolve',
      { note: 'Issuer confirmed the purchase is legitimate.', reviewed_no_action: true }, expect.anything()))
    expect(await screen.findByText('Exception #12 resolved.')).toBeInTheDocument()
    expect(within(dialog).getByText('Issuer confirmed the purchase is legitimate.')).toBeInTheDocument()
  })

  it('shows the server refusal without closing the dialog', async () => {
    apiClient.post.mockRejectedValue({ response: { status: 409, data: { error: 'This exception is already resolved.' } } })
    mount()
    await userEvent.click(await screen.findByRole('button', { name: 'Review exception #13' }))
    const dialog = await screen.findByRole('dialog', { name: 'Exception #13' })
    await userEvent.type(await within(dialog).findByRole('textbox', { name: /Resolution note/ }), 'Belongs to another integration.')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Resolve with note' }))
    expect(await within(dialog).findByRole('alert')).toHaveTextContent('This exception is already resolved.')
  })

  it('shows an empty state and a retry on load failure', async () => {
    apiClient.get.mockResolvedValueOnce(listing([]))
    const view = mount()
    expect(await screen.findByText('No open reconciliation exceptions.')).toBeInTheDocument()
    view.unmount()
    apiClient.get.mockRejectedValue({ response: { status: 500 } })
    mount()
    expect(await screen.findByRole('alert')).toHaveTextContent('could not be loaded')
  })
})
