import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import apiClient from '../../api/client'
import RefundsPage from './RefundsPage'

vi.mock('../../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn(), post: vi.fn() } }))
beforeEach(() => vi.stubEnv('VITE_SUPPORT_EMAIL', 'operator@example.test'))
afterEach(() => { vi.unstubAllEnvs(); vi.useRealTimers() })
function mountRefunds() { return render(<MemoryRouter initialEntries={['/dashboard/events/37/refunds']}><Routes><Route path="/dashboard/events/:id/refunds" element={<RefundsPage />} /></Routes></MemoryRouter>) }

// A retry keeps the operation fixed but receives its own cancellable transport.
const operation = ([url, payload, { signal: _signal, ...config }]) => [url, payload, config]

describe('refund outcome and recovery', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    window.localStorage.clear()
    window.sessionStorage.clear()
    apiClient.get.mockResolvedValue({ data: { id: 37, organization_id: 1, permissions: { refund: true, view_finance: true }, orders: [{ id: 922, buyer_name: 'Guest', buyer_email: 'guest@example.invalid', ticket_count: 1, total_cents: 500, refundable_cents: 500 }] } })
  })

  it('keeps pending refunds truthful and retries the same request across reload', async () => {
    apiClient.post.mockResolvedValueOnce({ data: { id: 81, status: 'pending' } })
    const first = mountRefunds()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Refund', exact: true }))
    await user.click(screen.getByRole('button', { name: /^Refund \$\d/ }))
    await screen.findByText(/Refund pending — waiting/)
    const original = apiClient.post.mock.calls[0]
    expect(screen.getByLabelText('Type')).toBeDisabled()
    expect(screen.queryByText('Refund confirmed by the payment provider.')).not.toBeInTheDocument()
    first.unmount()
    apiClient.post.mockResolvedValueOnce({ data: { id: 81, status: 'succeeded' } })
    mountRefunds()
    await user.click(await screen.findByRole('button', { name: 'Retry saved refund' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledTimes(2))
    expect(operation(apiClient.post.mock.calls[1])).toEqual(operation(original))
    expect(await screen.findByText('Refund confirmed by the payment provider.')).toBeInTheDocument()
  })

  it('retains the operation identity after an uncertain error and does not call it refunded', async () => {
    apiClient.post.mockRejectedValueOnce({ response: { status: 422, data: { error: 'Provider outcome uncertain' } } })
    mountRefunds()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Refund', exact: true }))
    await user.click(screen.getByRole('button', { name: /^Refund \$\d/ }))
    await screen.findByText(/Provider outcome uncertain/)
    const original = apiClient.post.mock.calls[0]
    apiClient.post.mockResolvedValueOnce({ data: { id: 81, status: 'failed' } })
    await user.click(screen.getByRole('button', { name: 'Retry saved refund' }))
    await screen.findByText('Refund failed. No refund has been confirmed.')
    expect(operation(apiClient.post.mock.calls[1])).toEqual(operation(original))
    expect(window.sessionStorage.getItem('hafapass:pending-refund:v2:local-preview:default:37')).toBeNull()
  })
  it('labels a completed simulation without claiming actual provider money was returned', async () => {
    apiClient.post.mockResolvedValueOnce({ data: { status: 'succeeded', refund_simulated: true } })
    mountRefunds()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Refund', exact: true }))
    await user.click(screen.getByRole('button', { name: /^Refund \$\d/ }))
    expect(await screen.findByText('Test refund complete. No real money was returned.')).toBeInTheDocument()
    expect(screen.queryByText('Refund confirmed by the payment provider.')).not.toBeInTheDocument()
  })

  it('releases the form only when the server explicitly confirms there is no uncertain provider operation', async () => {
    apiClient.post.mockRejectedValueOnce({ response: { status: 422, data: { error: 'Cash repayment requires a manager', reconciliation_required: false } } })
    mountRefunds()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Refund', exact: true }))
    await user.click(screen.getByRole('button', { name: /^Refund \$\d/ }))
    expect(await screen.findByText(/Cash repayment requires a manager/)).toHaveTextContent('No new refund was confirmed')
    expect(window.sessionStorage.getItem('hafapass:pending-refund:v2:local-preview:default:37')).toBeNull()
    expect(screen.queryByRole('button', { name: 'Retry saved refund' })).not.toBeInTheDocument()
  })
  it.each(['positive', 'error'])('persists finance-review identity for %s outcomes and does not free the form until review is explicitly cleared', async kind => {
    const data = { status: 'failed', refund_status: 'failed', finance_review_required: true, reconciliation_required: true }
    if (kind === 'positive') apiClient.post.mockResolvedValueOnce({ data })
    else apiClient.post.mockRejectedValueOnce({ response: { status: 422, data } })
    const first = mountRefunds()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Refund', exact: true }))
    await user.click(screen.getByRole('button', { name: /^Refund \$\d/ }))
    const notice = 'The payment records need a finance review. Contact support before starting another refund. This saved request and its payment identity are retained.'
    await screen.findByText(notice)
    const original = apiClient.post.mock.calls[0]
    const key = 'hafapass:pending-refund:v2:local-preview:default:37'
    expect(JSON.parse(window.sessionStorage.getItem(key))).toMatchObject({ financeReview: true })
    first.unmount()
    mountRefunds()
    await screen.findByText(notice)
    expect(screen.getByRole('link', { name: 'Contact support' })).toHaveAttribute('href', 'mailto:operator@example.test?subject=Refund%20review%20for%20order%20922')
    apiClient.post.mockResolvedValueOnce({ data: { status: 'failed' } })
    await user.click(screen.getByRole('button', { name: 'Check saved refund status' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledTimes(2))
    expect(operation(apiClient.post.mock.calls[1])).toEqual(operation(original))
    expect(screen.getByLabelText('Type')).toBeDisabled()
    expect(screen.queryByText('Refund failed. No refund has been confirmed.')).not.toBeInTheDocument()
    apiClient.post.mockResolvedValueOnce({ data: { status: 'pending', finance_review_required: false, reconciliation_required: true } })
    await user.click(screen.getByRole('button', { name: 'Check saved refund status' }))
    await screen.findByText(/Refund pending — waiting for the payment provider/)
    expect(screen.queryByText(notice)).not.toBeInTheDocument()
    expect(screen.getByLabelText('Type')).toBeDisabled()
    expect(operation(apiClient.post.mock.calls[2])).toEqual(operation(original))
    apiClient.post.mockResolvedValueOnce({ data: { status: 'failed', finance_review_required: false, reconciliation_required: false } })
    await user.click(screen.getByRole('button', { name: 'Retry saved refund' }))
    await screen.findByText('Refund failed. No refund has been confirmed.')
    expect(operation(apiClient.post.mock.calls[3])).toEqual(operation(original))
    expect(window.sessionStorage.getItem(key)).toBeNull()
    expect(screen.getByRole('button', { name: 'Refund', exact: true })).toBeEnabled()
  })
  it('records cash already returned only with required evidence and preserves the exact record on uncertain retries', async () => {
    apiClient.get.mockResolvedValue({ data: { id: 37, organization_id: 1, permissions: { refund: true, view_finance: true }, orders: [{ id: 922, buyer_name: 'Cash buyer', buyer_email: 'cash@example.invalid', ticket_count: 1, total_cents: 500, refundable_cents: 500, payment_method: 'door_cash', payment_provider: 'door_cash', created_at: '2026-01-01T00:00:00Z' }] } })
    apiClient.post.mockRejectedValueOnce(new Error('Response lost'))
    const first = mountRefunds()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Record cash already returned' }))
    expect(screen.getByText(/The organizer holds door cash/)).toHaveTextContent('HåfaPass does not send money')
    await user.click(screen.getByRole('button', { name: 'Record cash already returned' }))
    expect(apiClient.post).not.toHaveBeenCalled()
    expect(screen.getByLabelText('Cash return reference')).toHaveFocus()
    expect(screen.getByLabelText('Cash return reference')).toHaveAttribute('aria-invalid', 'true')
    await user.type(screen.getByLabelText('Cash return reference'), 'receipt-671')
    fireEvent.change(screen.getByLabelText('Cash returned at (your device time)'), { target: { value: '2026-01-02T12:30' } })
    await user.type(screen.getByLabelText('Reason (required)'), 'Cash returned at door')
    await user.click(screen.getByRole('button', { name: 'Record cash already returned' }))
    await screen.findByRole('button', { name: 'Retry saved cash return record' })
    const original = apiClient.post.mock.calls[0]
    expect(original[1]).toMatchObject({ reason: 'Cash returned at door', cash_return: { reference: 'receipt-671', returned_at: new Date('2026-01-02T12:30').toISOString() } })
    expect(screen.getByLabelText('Cash return reference')).toBeDisabled()
    first.unmount()
    apiClient.post.mockResolvedValueOnce({ data: { status: 'succeeded', provider: 'door_cash', manual_record: true } })
    mountRefunds()
    await user.click(await screen.findByRole('button', { name: 'Retry saved cash return record' }))
    await screen.findByText('Cash return recorded. The organizer returned physical cash; HåfaPass did not transfer money.')
    expect(operation(apiClient.post.mock.calls[1])).toEqual(operation(original))
  })

  it('records a same-minute cash return with seconds precision and retries its exact timestamp', async () => {
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(new Date('2026-10-18T12:03:55'))
    const created_at = new Date('2026-10-18T12:03:40').toISOString()
    apiClient.get.mockResolvedValue({ data: { id: 37, organization_id: 1, permissions: { refund: true, view_finance: true }, orders: [{ id: 922, buyer_name: 'Same minute buyer', total_cents: 500, refundable_cents: 500, payment_method: 'door_cash', payment_provider: 'door_cash', created_at }] } })
    apiClient.post.mockRejectedValueOnce(new Error('Response lost'))
    mountRefunds()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Record cash already returned' }))
    const returnedInput = screen.getByLabelText('Cash returned at (your device time)')
    expect(returnedInput).toHaveAttribute('step', '1')
    expect(returnedInput).toHaveAttribute('min', '2026-10-18T12:03:40')
    await user.type(screen.getByLabelText('Cash return reference'), 'same-minute-receipt')
    fireEvent.change(returnedInput, { target: { value: '2026-10-18T12:03:50' } })
    expect(returnedInput).toHaveValue('2026-10-18T12:03:50.000')
    await user.type(screen.getByLabelText('Reason (required)'), 'Cash returned ten seconds after purchase')
    await user.click(screen.getByRole('button', { name: 'Record cash already returned' }))
    await screen.findByRole('button', { name: 'Retry saved cash return record' })
    const original = apiClient.post.mock.calls[0]
    expect(original[1].cash_return.returned_at).toBe(new Date('2026-10-18T12:03:50').toISOString())
    vi.setSystemTime(new Date('2026-10-18T12:04:30'))
    apiClient.post.mockResolvedValueOnce({ data: { status: 'succeeded', provider: 'door_cash', manual_record: true } })
    await user.click(screen.getByRole('button', { name: 'Retry saved cash return record' }))
    await screen.findByText('Cash return recorded. The organizer returned physical cash; HåfaPass did not transfer money.')
    expect(operation(apiClient.post.mock.calls[1])).toEqual(operation(original))
  })

  it.each([['online', 'stripe'], ['door_cash', 'boh_clover'], ['online', 'door_cash']])('does not expose manual cash controls for %s / %s', async (payment_method, payment_provider) => {
    apiClient.get.mockResolvedValue({ data: { id: 37, organization_id: 1, permissions: { refund: true, view_finance: true }, orders: [{ id: 922, buyer_name: 'Buyer', total_cents: 500, refundable_cents: 500, payment_method, payment_provider }] } })
    mountRefunds()
    await userEvent.click(await screen.findByRole('button', { name: 'Refund', exact: true }))
    expect(screen.queryByLabelText('Cash return reference')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: /^Refund \$\d/ })).toBeInTheDocument()
  })

})

describe('refund labels', () => {
  beforeEach(() => {
    vi.clearAllMocks(); window.localStorage.clear(); window.sessionStorage.clear()
    apiClient.get.mockResolvedValue({ data: { id: 37, organization_id: 1, permissions: { refund: true, view_finance: true }, orders: [
      { id: 922, buyer_name: 'Single', buyer_email: 'one@example.invalid', ticket_count: 1, total_cents: 500, refundable_cents: 500 },
      { id: 923, buyer_name: 'Group', buyer_email: 'group@example.invalid', ticket_count: 3, total_cents: 10500, refundable_cents: 10500 },
    ] } })
  })

  it('pluralizes tickets, keeps the row trigger neutral and names the amount on the danger confirm', async () => {
    const user = userEvent.setup()
    mountRefunds()
    expect(await screen.findByText(/1 ticket ·/)).toBeInTheDocument()
    expect(screen.getByText(/3 tickets ·/)).toBeInTheDocument()
    expect(screen.queryByText(/ticket\(s\)/)).not.toBeInTheDocument()
    const triggers = screen.getAllByRole('button', { name: 'Refund', exact: true })
    for (const trigger of triggers) expect(trigger.className).not.toMatch(/red|danger/)
    await user.click(triggers[1])
    const confirm = screen.getByRole('button', { name: 'Refund $105.00' })
    expect(confirm.className).toMatch(/action-danger/)
    await user.selectOptions(screen.getByLabelText('Type'), 'partial')
    expect(screen.getByRole('button', { name: 'Process Refund' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Process Refund' })).toHaveAccessibleDescription('Enter the amount to refund.')
    const amount = screen.getByLabelText('Amount ($)')
    await user.type(amount, '0.004')
    const tiny = screen.getByRole('button', { name: 'Process Refund' })
    expect(tiny).toBeDisabled()
    expect(tiny).toHaveAccessibleDescription('Enter dollars and cents, like 12.50.')
    expect(amount).toHaveAttribute('aria-invalid', 'true')
    await user.click(tiny)
    await user.clear(amount); await user.type(amount, '0.01')
    expect(screen.getByRole('button', { name: 'Refund $0.01' })).toBeEnabled()
    await user.clear(amount); await user.type(amount, '105.01')
    const over = screen.getByRole('button', { name: 'Process Refund' })
    expect(over).toBeDisabled()
    expect(over).toHaveAccessibleDescription('Enter no more than $105.00.')
    await user.clear(amount); await user.type(amount, '20')
    expect(screen.getByRole('button', { name: 'Refund $20.00' })).toBeEnabled()
    expect(apiClient.post).not.toHaveBeenCalled()
    await user.clear(amount); await user.type(amount, '0.01')
    apiClient.post.mockResolvedValueOnce({ data: { id: 90, status: 'succeeded' } })
    await user.click(screen.getByRole('button', { name: 'Refund $0.01' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledTimes(1))
    expect(apiClient.post.mock.calls[0][0]).toBe('/organizer/events/37/orders/923/refund')
    expect(apiClient.post.mock.calls[0][1]).toMatchObject({ amount_cents: 1 })
  })
})
