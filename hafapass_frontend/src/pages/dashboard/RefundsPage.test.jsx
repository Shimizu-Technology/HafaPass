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
})
