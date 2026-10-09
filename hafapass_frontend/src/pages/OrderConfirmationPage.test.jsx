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

describe('truthful ticket email status', () => {
  beforeEach(() => { vi.clearAllMocks(); window.sessionStorage.clear() })

  const orderWithDelivery = confirmation_delivery => ({
    id: 924, reference: 'HP-924', status: 'completed', buyer_email: 'guest@example.invalid', total_cents: 0, order_items: [],
    tickets: [{ id: 1, status: 'issued', refundable_cents: 0, display_credential: 'signed-display', ticket_type: { id: 7, name: 'Free admission' } }],
    event: { id: 37, slug: 'email-event', title: 'Email Event', status: 'published', starts_at: '2026-10-20T08:00:00Z', timezone: 'Pacific/Guam', transfers_enabled: false },
    confirmation_delivery,
  })
  const mount = () => render(<MemoryRouter initialEntries={['/orders/924/confirmation?guest_token=guest-token']}><Routes><Route path="/orders/:id/confirmation" element={<OrderConfirmationPage />} /></Routes></MemoryRouter>)
  const mockOrder = order => apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/config' ? { launch_capabilities: {} } : order }))

  it('identifies simulated delivery even when its recorded state is delivered', async () => {
    mockOrder(orderWithDelivery({ status: 'delivered', simulated: true, updated_at: '2026-10-09T05:00:00Z' }))
    mount()
    expect(await screen.findByText('Email is simulated in this test environment. Open or download your tickets below.')).toBeInTheDocument()
    expect(screen.queryByText('Your ticket email was delivered.')).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'View ticket' })).toBeInTheDocument()
  })

  it.each([
    ['queued', 'Your ticket email is queued for delivery. You can open or download your tickets below.'],
    ['delayed', 'Your ticket email is queued for delivery. You can open or download your tickets below.'],
    ['sent', 'Your ticket email was accepted for delivery. Delivery has not been confirmed.'],
    ['delivered', 'Your ticket email was delivered.'],
  ])('shows the provider’s %s state without claiming a later outcome', async (status, message) => {
    mockOrder(orderWithDelivery({ status, simulated: false }))
    mount()
    expect(await screen.findByText(message)).toBeInTheDocument()
    if (status !== 'delivered') expect(screen.queryByText('Your ticket email was delivered.')).not.toBeInTheDocument()
  })

  it.each(['failed', 'bounced', 'complained', 'suppressed'])('offers ticket access and support when delivery is %s', async status => {
    mockOrder(orderWithDelivery({ status, simulated: false }))
    mount()
    await screen.findByText('We couldn’t deliver your ticket email. Open or download your tickets below, or contact support.')
    expect(screen.getByRole('link', { name: 'Open or download tickets' })).toHaveAttribute('href', '#order-tickets')
    expect(screen.getByRole('link', { name: 'Contact support' })).toHaveAttribute('href', expect.stringContaining('mailto:contact@hafapass.com'))
    expect(screen.queryByText('Your ticket email was delivered.')).not.toBeInTheDocument()
  })

  it('keeps completed orders neutral about email when delivery evidence is absent', async () => {
    mockOrder(orderWithDelivery(null))
    mount()
    expect(await screen.findByText('Your tickets are ready below. You can request a confirmation email using Resend.')).toBeInTheDocument()
    expect(screen.queryByText('Your ticket email was delivered.')).not.toBeInTheDocument()
  })

  it('refreshes actual delivery evidence after resend while keeping guest access attached', async () => {
    mockOrder(orderWithDelivery({ status: 'failed', simulated: false }))
    apiClient.post.mockImplementation(() => {
      mockOrder(orderWithDelivery({ status: 'queued', simulated: false }))
      return Promise.resolve({ data: { status: 'queued' } })
    })
    mount()
    await screen.findByText('We couldn’t deliver your ticket email. Open or download your tickets below, or contact support.')
    await userEvent.click(screen.getByRole('button', { name: 'Resend', exact: true }))
    expect(await screen.findByText('Your ticket email is queued for delivery. You can open or download your tickets below.')).toBeInTheDocument()
    expect(await screen.findByText('Your email request was saved. Check the delivery status above.')).toBeInTheDocument()
    expect(apiClient.post).toHaveBeenCalledWith('/orders/924/resend', {}, { headers: { 'X-Guest-Order-Token': 'guest-token' } })
    expect(screen.queryByText('Your ticket email was delivered.')).not.toBeInTheDocument()
  })
})
