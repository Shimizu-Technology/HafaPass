import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import OrderConfirmationPage from './OrderConfirmationPage'
import apiClient from '../api/client'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('../components/SEO', () => ({ default: () => null }))

describe('guest order recovery actions', () => {
  beforeEach(() => { vi.clearAllMocks(); window.sessionStorage.clear() })

  it('uses the guest token imported from the recovery link on initial fetch and every later action', async () => {
    const order = {
      id: 922, reference: 'HP-922', status: 'completed', buyer_name: 'Guest', buyer_email: 'guest@example.invalid', total_cents: 0,
      order_items: [{ id: 2, item_name: 'Free admission', quantity: 1, subtotal_cents: 0 }],
      tickets: [{ id: 1, status: 'issued', refundable_cents: 0, display_credential: 'signed-display', ticket_type: { id: 7, name: 'Free admission' } }],
      event: { id: 37, slug: 'free-event', title: 'Free Event', status: 'published', starts_at: '2026-10-20T08:00:00Z', timezone: 'Pacific/Guam', venue_name: 'Venue', transfers_enabled: false },
    }
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/config' ? { launch_capabilities: {} } : order }))
    apiClient.post.mockResolvedValue({ data: {} })
    render(<MemoryRouter initialEntries={['/orders/922/confirmation?guest_token=guest-token']}><Routes>
      <Route path="/orders/:id/confirmation" element={<OrderConfirmationPage />} />
    </Routes></MemoryRouter>)
    await screen.findByText('Free Event')
    await userEvent.click(screen.getByRole('button', { name: 'Resend', exact: true }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalled())
    expect(apiClient.post.mock.calls[0][2].headers['X-Guest-Order-Token']).toBe('guest-token')
    expect(apiClient.get.mock.calls.filter(([url]) => url === '/orders/922').every(([, options]) => options.headers['X-Guest-Order-Token'] === 'guest-token')).toBe(true)
    expect(screen.getByText('Free admission × 1')).toBeInTheDocument()
  })
  it('reuses the same guest refund operation after a lost response and page reload', async () => {
    const order = {
      id: 923, reference: 'HP-923', status: 'completed', buyer_email: 'guest@example.invalid', total_cents: 500, order_items: [],
      latest_event_change: { id: 4, change_type: 'cancelled', response: 'refund_requested' },
      tickets: [{ id: 1, status: 'issued', refundable_cents: 500, display_credential: 'signed-display', ticket_type: { id: 7, name: 'Admission' } }],
      event: { id: 37, slug: 'cancelled-event', title: 'Cancelled Event', status: 'cancelled', starts_at: '2026-10-20T08:00:00Z', timezone: 'Pacific/Guam', transfers_enabled: false },
    }
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/config' ? { launch_capabilities: {} } : order }))
    apiClient.post.mockRejectedValueOnce(new Error('response lost'))
    const mount = () => render(<MemoryRouter initialEntries={['/orders/923/confirmation?guest_token=guest-token']}><Routes><Route path="/orders/:id/confirmation" element={<OrderConfirmationPage />} /></Routes></MemoryRouter>)
    const first = mount()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Retry refund' }))
    await screen.findByText('We could not save that choice. Please try again.')
    const original = apiClient.post.mock.calls[0]
    first.unmount()
    apiClient.post.mockResolvedValueOnce({ data: {} })
    mount()
    await user.click(await screen.findByRole('button', { name: 'Retry refund' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledTimes(2))
    expect(apiClient.post.mock.calls[1]).toEqual(original)
    expect(original[2].headers).toMatchObject({ 'X-Guest-Order-Token': 'guest-token', 'Idempotency-Key': 'buyer-event-refund:923:4' })
  })

})
