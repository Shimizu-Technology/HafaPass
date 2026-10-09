import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import apiClient from '../../api/client'
import RefundsPage from './RefundsPage'

vi.mock('../../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))
function mountRefunds() { return render(<MemoryRouter initialEntries={['/dashboard/events/37/refunds']}><Routes><Route path="/dashboard/events/:id/refunds" element={<RefundsPage />} /></Routes></MemoryRouter>) }

describe('refund outcome and recovery', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    window.localStorage.clear()
    window.sessionStorage.clear()
    apiClient.get.mockResolvedValue({ data: { recent_orders: [{ id: 922, buyer_name: 'Guest', buyer_email: 'guest@example.invalid', ticket_count: 1, total_cents: 500, refundable_cents: 500 }] } })
  })

  it('keeps pending refunds truthful and retries the same request across reload', async () => {
    apiClient.post.mockResolvedValueOnce({ data: { id: 81, status: 'pending' } })
    const first = mountRefunds()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Refund', exact: true }))
    await user.click(screen.getByRole('button', { name: 'Process Refund' }))
    await screen.findByText(/Refund pending — waiting/)
    const original = apiClient.post.mock.calls[0]
    expect(screen.getByLabelText('Type')).toBeDisabled()
    expect(screen.queryByText('Refund confirmed by the payment provider.')).not.toBeInTheDocument()
    first.unmount()
    apiClient.post.mockResolvedValueOnce({ data: { id: 81, status: 'succeeded' } })
    mountRefunds()
    await user.click(await screen.findByRole('button', { name: 'Retry saved refund' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledTimes(2))
    expect(apiClient.post.mock.calls[1]).toEqual(original)
    expect(await screen.findByText('Refund confirmed by the payment provider.')).toBeInTheDocument()
  })

  it('retains the operation identity after an uncertain error and does not call it refunded', async () => {
    apiClient.post.mockRejectedValueOnce({ response: { status: 422, data: { error: 'Provider outcome uncertain' } } })
    mountRefunds()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Refund', exact: true }))
    await user.click(screen.getByRole('button', { name: 'Process Refund' }))
    await screen.findByText(/Provider outcome uncertain/)
    const original = apiClient.post.mock.calls[0]
    apiClient.post.mockResolvedValueOnce({ data: { id: 81, status: 'failed' } })
    await user.click(screen.getByRole('button', { name: 'Retry saved refund' }))
    await screen.findByText('Refund failed. No refund has been confirmed.')
    expect(apiClient.post.mock.calls[1]).toEqual(original)
    expect(window.sessionStorage.getItem('hafapass:pending-refund:local-preview:37')).toBeNull()
  })
  it('labels a completed simulation without claiming actual provider money was returned', async () => {
    apiClient.post.mockResolvedValueOnce({ data: { status: 'succeeded', refund_simulated: true } })
    mountRefunds()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Refund', exact: true }))
    await user.click(screen.getByRole('button', { name: 'Process Refund' }))
    expect(await screen.findByText('Test refund complete. No real money was returned.')).toBeInTheDocument()
    expect(screen.queryByText('Refund confirmed by the payment provider.')).not.toBeInTheDocument()
  })

  it('releases the form only when the server explicitly confirms there is no uncertain provider operation', async () => {
    apiClient.post.mockRejectedValueOnce({ response: { status: 422, data: { error: 'Cash repayment requires a manager', reconciliation_required: false } } })
    mountRefunds()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Refund', exact: true }))
    await user.click(screen.getByRole('button', { name: 'Process Refund' }))
    expect(await screen.findByText(/Cash repayment requires a manager/)).toHaveTextContent('No new refund was confirmed')
    expect(window.sessionStorage.getItem('hafapass:pending-refund:local-preview:37')).toBeNull()
    expect(screen.queryByRole('button', { name: 'Retry saved refund' })).not.toBeInTheDocument()
  })
  it.each(['positive', 'error'])('persists finance-review identity for %s outcomes and does not free the form until review is explicitly cleared', async kind => {
    const data = { status: 'failed', refund_status: 'failed', finance_review_required: true, reconciliation_required: true }
    if (kind === 'positive') apiClient.post.mockResolvedValueOnce({ data })
    else apiClient.post.mockRejectedValueOnce({ response: { status: 422, data } })
    const first = mountRefunds()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Refund', exact: true }))
    await user.click(screen.getByRole('button', { name: 'Process Refund' }))
    const notice = 'The payment records need a finance review. Contact support before starting another refund. This saved request and its payment identity are retained.'
    await screen.findByText(notice)
    const original = apiClient.post.mock.calls[0]
    const key = 'hafapass:pending-refund:local-preview:37'
    expect(JSON.parse(window.sessionStorage.getItem(key))).toMatchObject({ financeReview: true })
    first.unmount()
    mountRefunds()
    await screen.findByText(notice)
    expect(screen.getByRole('link', { name: 'Contact support' })).toHaveAttribute('href', expect.stringContaining('mailto:contact@hafapass.com'))
    apiClient.post.mockResolvedValueOnce({ data: { status: 'failed' } })
    await user.click(screen.getByRole('button', { name: 'Check saved refund status' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledTimes(2))
    expect(apiClient.post.mock.calls[1]).toEqual(original)
    expect(screen.getByLabelText('Type')).toBeDisabled()
    expect(screen.queryByText('Refund failed. No refund has been confirmed.')).not.toBeInTheDocument()
    apiClient.post.mockResolvedValueOnce({ data: { status: 'pending', finance_review_required: false, reconciliation_required: true } })
    await user.click(screen.getByRole('button', { name: 'Check saved refund status' }))
    await screen.findByText(/Refund pending — waiting for the payment provider/)
    expect(screen.queryByText(notice)).not.toBeInTheDocument()
    expect(screen.getByLabelText('Type')).toBeDisabled()
    expect(apiClient.post.mock.calls[2]).toEqual(original)
    apiClient.post.mockResolvedValueOnce({ data: { status: 'failed', finance_review_required: false, reconciliation_required: false } })
    await user.click(screen.getByRole('button', { name: 'Retry saved refund' }))
    await screen.findByText('Refund failed. No refund has been confirmed.')
    expect(apiClient.post.mock.calls[3]).toEqual(original)
    expect(window.sessionStorage.getItem(key)).toBeNull()
    expect(screen.getByRole('button', { name: 'Refund', exact: true })).toBeEnabled()
  })
})
