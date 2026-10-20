import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useAuth } from '@clerk/clerk-react'
import { act, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import OrderConfirmationPage from './OrderConfirmationPage'
import apiClient from '../api/client'
import { getActiveCheckout, saveActiveCheckout } from '../utils/orderAccess'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn(), delete: vi.fn() } }))
vi.mock('@clerk/clerk-react', () => ({ useAuth: vi.fn() }))
vi.mock('../components/SEO', () => ({ default: () => null }))
beforeEach(() => vi.stubEnv('VITE_SUPPORT_EMAIL', 'operator@example.test'))
afterEach(() => vi.unstubAllEnvs())

describe('guest order recovery actions', () => {
  beforeEach(() => { vi.clearAllMocks(); window.sessionStorage.clear(); window.localStorage.clear() })

  it('does not fetch cached private order access before Clerk hydration and device binding settle', async () => {
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_fixture')
    useAuth.mockReturnValue({ isLoaded: false, userId: undefined })
    window.localStorage.setItem('hafapass_scanner_user_id', 'previous-buyer')
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/config' ? { launch_capabilities: {} }
      : { id: 922, status: 'completed', order_items: [], tickets: [], event: { slug: 'free-event', title: 'Verified after binding' } } }))
    const tree = () => <MemoryRouter initialEntries={['/orders/922/confirmation']}><Routes><Route path='/orders/:id/confirmation' element={<OrderConfirmationPage />} /></Routes></MemoryRouter>
    const view = render(tree())
    expect(apiClient.get).not.toHaveBeenCalled()
    useAuth.mockReturnValue({ isLoaded: true, userId: null })
    view.rerender(tree())
    expect(apiClient.get).not.toHaveBeenCalled()
    window.localStorage.removeItem('hafapass_scanner_user_id')
    view.rerender(tree())
    expect(await screen.findByText('Verified after binding')).toBeInTheDocument()
    expect(apiClient.get).toHaveBeenCalledWith('/orders/922', { headers: {} })
  })

  it('does not clear a newer active checkout after an earlier order becomes terminal', async () => {
    let finish
    apiClient.get.mockImplementation(url => url === '/config' ? Promise.resolve({ data: { launch_capabilities: {} } }) : new Promise(resolve => { finish = resolve }))
    saveActiveCheckout('free-event', 922)
    render(<MemoryRouter initialEntries={['/orders/922/confirmation']}><Routes><Route path='/orders/:id/confirmation' element={<OrderConfirmationPage />} /></Routes></MemoryRouter>)
    await waitFor(() => expect(finish).toBeTypeOf('function'))
    saveActiveCheckout('free-event', 923)
    await act(async () => finish({ data: { id: 922, status: 'completed', order_items: [], tickets: [], event: { slug: 'free-event', title: 'Earlier Order Event' } } }))
    expect(await screen.findByText('Earlier Order Event')).toBeInTheDocument()
    expect(getActiveCheckout('free-event')).toBe('923')
  })

  it('discards a late order fetch after the authenticated buyer changes', async () => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'buyer-a')
    let finish
    apiClient.get.mockImplementation(url => url === '/config' ? Promise.resolve({ data: { launch_capabilities: {} } }) : new Promise(resolve => { finish = resolve }))
    saveActiveCheckout('free-event', 922)
    render(<MemoryRouter initialEntries={['/orders/922/confirmation']}><Routes><Route path='/orders/:id/confirmation' element={<OrderConfirmationPage />} /></Routes></MemoryRouter>)
    await waitFor(() => expect(finish).toBeTypeOf('function'))
    window.localStorage.setItem('hafapass_scanner_user_id', 'buyer-b')
    await act(async () => finish({ data: { id: 922, status: 'completed', buyer_email: 'private-buyer-a@example.invalid', order_items: [], tickets: [], event: { slug: 'free-event', title: 'Buyer A private event' } } }))
    expect(screen.queryByText('Buyer A private event')).not.toBeInTheDocument()
    window.localStorage.setItem('hafapass_scanner_user_id', 'buyer-a')
    expect(getActiveCheckout('free-event')).toBe('922')
  })

  it('uses the guest token imported from the recovery link on initial fetch and every later action', async () => {
    const order = {
      id: 922, reference: 'HP-922', status: 'completed', buyer_name: 'Guest', buyer_email: 'guest@example.invalid', total_cents: 0,
      order_items: [{ id: 2, item_name: 'Free admission', quantity: 1, subtotal_cents: 0 }],
      tickets: [{ id: 1, status: 'issued', admission_allowed: true, refundable_cents: 0, display_credential: 'signed-display', ticket_type: { id: 7, name: 'Free admission' } }],
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
    await screen.findByText('The refund outcome is not confirmed. Check this saved request before starting another refund.')
    const original = apiClient.post.mock.calls[0]
    first.unmount()
    apiClient.post.mockResolvedValueOnce({ data: {} })
    mount()
    await user.click(await screen.findByRole('button', { name: 'Check refund status' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledTimes(2))
    expect(apiClient.post.mock.calls[1]).toEqual(original)
    expect(original[2].headers).toMatchObject({ 'X-Guest-Order-Token': 'guest-token', 'Idempotency-Key': 'buyer-event-refund:923:4' })
  })

})

describe('buyer refund outcomes and terminal retries', () => {
  beforeEach(() => { vi.clearAllMocks(); window.sessionStorage.clear(); vi.spyOn(window, 'confirm').mockReturnValue(true) })
  const paidOrder = {
    id: 925, reference: 'HP-925', status: 'completed', buyer_email: 'guest@example.invalid', total_cents: 500, order_items: [],
    tickets: [{ id: 1, status: 'issued', refundable_cents: 500, display_credential: 'display', ticket_type: { id: 7, name: 'Admission' } }],
    event: { id: 37, slug: 'refund-event', title: 'Refund Event', status: 'cancelled', starts_at: '2026-10-20T08:00:00Z', timezone: 'Pacific/Guam', transfers_enabled: false },
  }
  const mockOrder = order => apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/config' ? { launch_capabilities: {} } : order }))
  const mount = () => render(<MemoryRouter initialEntries={['/orders/925/confirmation?guest_token=guest-token']}><Routes><Route path="/orders/:id/confirmation" element={<OrderConfirmationPage />} /></Routes></MemoryRouter>)

  it.each(['failed', 'cancelled'])('allows a new ticket refund attempt only after the provider confirms %s, and retains the next pending identity after reload', async status => {
    mockOrder(paidOrder)
    apiClient.post.mockResolvedValueOnce({ data: { refund_status: status, reconciliation_required: false } })
    const first = mount()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Refund', exact: true }))
    await screen.findByText(`Refund ${status}. No refund was confirmed. You can try again.`)
    const originalKey = apiClient.post.mock.calls[0][2].headers['Idempotency-Key']
    apiClient.post.mockResolvedValueOnce({ data: { refund_status: 'pending', reconciliation_required: true } })
    await user.click(screen.getByRole('button', { name: 'Try refund again' }))
    await screen.findByText(/Refund pending — waiting for the payment provider/)
    const nextKey = apiClient.post.mock.calls[1][2].headers['Idempotency-Key']
    expect(nextKey).not.toBe(originalKey)
    first.unmount()
    mount()
    apiClient.post.mockResolvedValueOnce({ data: { refund_status: 'pending', reconciliation_required: true } })
    await user.click(await screen.findByRole('button', { name: 'Check refund status' }))
    expect(apiClient.post.mock.calls[2][2].headers).toMatchObject({ 'Idempotency-Key': nextKey, 'X-Guest-Order-Token': 'guest-token' })
  })

  it('keeps a lost ticket refund response on the same operation after reload and exposes definitive failure before offering a new attempt', async () => {
    mockOrder(paidOrder)
    apiClient.post.mockRejectedValueOnce(new Error('response lost'))
    const first = mount()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Refund', exact: true }))
    await screen.findByText('The refund outcome is not confirmed. Check this saved request before starting another refund.')
    const key = apiClient.post.mock.calls[0][2].headers['Idempotency-Key']
    first.unmount()
    mount()
    apiClient.post.mockRejectedValueOnce({ response: { data: { error: 'Provider rejected refund', refund_status: 'failed', reconciliation_required: false } } })
    await user.click(await screen.findByRole('button', { name: 'Check refund status' }))
    await screen.findByText('Refund failed. No refund was confirmed. You can try again.')
    expect(apiClient.post.mock.calls[1][2].headers['Idempotency-Key']).toBe(key)
    expect(screen.getByRole('button', { name: 'Try refund again' })).toBeEnabled()
  })

  it('shows pending event refunds and rekeys only a confirmed terminal event refund failure', async () => {
    mockOrder({ ...paidOrder, latest_event_change: { id: 4, change_type: 'cancelled', response: 'refund_requested' } })
    apiClient.post.mockResolvedValueOnce({ data: { refund_status: 'pending', reconciliation_required: true } })
    mount()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Retry refund' }))
    await screen.findByText(/Refund pending — waiting for the payment provider/)
    const key = apiClient.post.mock.calls[0][2].headers['Idempotency-Key']
    apiClient.post.mockResolvedValueOnce({ data: { refund_status: 'failed', reconciliation_required: false } })
    await user.click(screen.getByRole('button', { name: 'Check refund status' }))
    await screen.findByText('Refund failed. No refund was confirmed. You can try again.')
    expect(apiClient.post.mock.calls[1][2].headers['Idempotency-Key']).toBe(key)
    apiClient.post.mockResolvedValueOnce({ data: { refund_status: 'succeeded', reconciliation_required: false } })
    await user.click(screen.getByRole('button', { name: 'Try refund again' }))
    await screen.findByText('Refund confirmed by the payment provider.')
    expect(apiClient.post.mock.calls[2][2].headers['Idempotency-Key']).not.toBe(key)
  })

  it.each(['ticket', 'event'])('can retrieve the saved %s refund result after ticket cancellation completes while the page is closed', async kind => {
    const withChange = kind === 'event' ? { ...paidOrder, latest_event_change: { id: 4, change_type: 'cancelled', response: 'refund_requested' } } : paidOrder
    mockOrder(withChange)
    apiClient.post.mockResolvedValueOnce({ data: { refund_status: 'pending', reconciliation_required: true } })
    const first = mount()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: kind === 'event' ? 'Retry refund' : 'Refund', exact: true }))
    await screen.findByText(/Refund pending — waiting for the payment provider/)
    const key = apiClient.post.mock.calls[0][2].headers['Idempotency-Key']
    first.unmount()
    mockOrder({ ...withChange, status: 'refunded', tickets: [{ ...paidOrder.tickets[0], status: 'cancelled', refundable_cents: 0 }] })
    apiClient.post.mockResolvedValueOnce({ data: { refund_status: 'succeeded', reconciliation_required: false } })
    mount()
    await user.click(await screen.findByRole('button', { name: 'Check refund status' }))
    await screen.findByText('Refund confirmed by the payment provider.')
    expect(apiClient.post.mock.calls[1][2].headers['Idempotency-Key']).toBe(key)
  })
  it.each(['ticket', 'event'])('retains a %s finance-review hold and status-check action after reload with cancelled tickets', async kind => {
    const withChange = kind === 'event' ? { ...paidOrder, latest_event_change: { id: 4, change_type: 'cancelled', response: 'refund_requested' } } : paidOrder
    mockOrder(withChange)
    apiClient.post.mockRejectedValueOnce({ response: { data: { refund_status: 'failed', finance_review_required: true, reconciliation_required: true } } })
    const first = mount()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: kind === 'event' ? 'Retry refund' : 'Refund', exact: true }))
    const notice = 'The payment records need a finance review. Contact support before requesting another refund. Check this saved request for updates.'
    await screen.findByText(notice)
    const key = apiClient.post.mock.calls[0][2].headers['Idempotency-Key']
    expect(screen.queryByRole('button', { name: 'Try refund again' })).not.toBeInTheDocument()
    expect(screen.queryByText(/Refund pending — waiting for the payment provider/)).not.toBeInTheDocument()
    first.unmount()
    mockOrder({ ...withChange, status: 'refunded', tickets: [{ ...paidOrder.tickets[0], status: 'cancelled', refundable_cents: 0 }] })
    mount()
    await screen.findByText(notice)
    expect(screen.getByRole('link', { name: 'Contact support', exact: true })).toHaveAttribute('href', 'mailto:operator@example.test?subject=Refund%20review%20for%20order%20HP-925')
    apiClient.post.mockResolvedValueOnce({ data: { refund_status: 'failed', finance_review_required: true, reconciliation_required: true } })
    await user.click(screen.getByRole('button', { name: 'Check refund status' }))
    await screen.findByText(notice)
    expect(apiClient.post.mock.calls[1][2].headers['Idempotency-Key']).toBe(key)
    expect(screen.queryByRole('button', { name: 'Try refund again' })).not.toBeInTheDocument()
  })
})

describe('truthful ticket email status', () => {
  beforeEach(() => { vi.clearAllMocks(); window.sessionStorage.clear() })

  const orderWithDelivery = confirmation_delivery => ({
    id: 924, reference: 'HP-924', status: 'completed', buyer_email: 'guest@example.invalid', total_cents: 0, order_items: [],
    tickets: [{ id: 1, status: 'issued', admission_allowed: true, refundable_cents: 0, display_credential: 'signed-display', ticket_type: { id: 7, name: 'Free admission' } }],
    event: { id: 37, slug: 'email-event', title: 'Email Event', status: 'published', starts_at: '2026-10-20T08:00:00Z', timezone: 'Pacific/Guam', transfers_enabled: false },
    confirmation_delivery,
  })
  const mount = () => render(<MemoryRouter initialEntries={['/orders/924/confirmation?guest_token=guest-token']}><Routes><Route path="/orders/:id/confirmation" element={<OrderConfirmationPage />} /></Routes></MemoryRouter>)
  const mockOrder = order => apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/config' ? { launch_capabilities: {} } : order }))

  it('identifies simulated delivery even when its recorded state is delivered', async () => {
    mockOrder(orderWithDelivery({ status: 'delivered', simulated: true, updated_at: '2026-10-09T05:00:00Z' }))
    mount()
    expect(await screen.findByText('Email is simulated in this test environment. Open or download your tickets on this page.')).toBeInTheDocument()
    expect(screen.queryByText('Your ticket email was delivered.')).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Open ticket: Free admission' })).toBeInTheDocument()
  })

  it.each([
    ['queued', 'Your ticket email is queued for delivery. You can open or download your tickets on this page.'],
    ['delayed', 'Your ticket email is delayed. Delivery has not been confirmed. You can open or download your tickets on this page.'],
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
    await screen.findByText('Your ticket email delivery needs attention. Open or download your tickets on this page, or contact support.')
    expect(screen.getByRole('link', { name: 'Open or download tickets' })).toHaveAttribute('href', '#order-tickets')
    expect(screen.getByRole('link', { name: 'Contact support' })).toHaveAttribute('href', 'mailto:operator@example.test?subject=Ticket%20email%20for%20order%20HP-924')
    expect(screen.queryByText('Your ticket email was delivered.')).not.toBeInTheDocument()
  })

  it('keeps completed orders neutral about email when delivery evidence is absent', async () => {
    mockOrder(orderWithDelivery(null))
    mount()
    expect(await screen.findByText('Your tickets are ready. You can request a confirmation email using Resend.')).toBeInTheDocument()
    expect(screen.queryByText('Your ticket email was delivered.')).not.toBeInTheDocument()
  })

  it('refreshes actual delivery evidence after resend while keeping guest access attached', async () => {
    mockOrder(orderWithDelivery({ status: 'failed', simulated: false }))
    apiClient.post.mockImplementation(() => {
      mockOrder(orderWithDelivery({ status: 'queued', simulated: false }))
      return Promise.resolve({ data: { status: 'queued' } })
    })
    mount()
    await screen.findByText('Your ticket email delivery needs attention. Open or download your tickets on this page, or contact support.')
    await userEvent.click(screen.getByRole('button', { name: 'Resend', exact: true }))
    expect(await screen.findByText('Your ticket email is queued for delivery. You can open or download your tickets on this page.')).toBeInTheDocument()
    expect(await screen.findByText('Your email request was saved. Check the delivery status below.')).toBeInTheDocument()
    expect(apiClient.post).toHaveBeenCalledWith('/orders/924/resend', {}, { headers: { 'X-Guest-Order-Token': 'guest-token' } })
    expect(screen.queryByText('Your ticket email was delivered.')).not.toBeInTheDocument()
  })
})


describe('pending payment status and private redirect data', () => {
  beforeEach(() => { vi.clearAllMocks(); window.sessionStorage.clear() })
  const pending = {
    id: 950, reference: 'HP-950', status: 'pending', payment_resumable: true,
    expires_at: new Date(Date.now() + 300000).toISOString(), total_cents: 1080,
    buyer_email: 'guest@example.invalid', order_items: [], tickets: [],
    event: { id: 1, slug: 'pending-event', title: 'Pending event', timezone: 'Pacific/Guam', status: 'published' },
  }
  function LocationProbe() { const location = useLocation(); return <p data-testid='query'>{location.search || 'clean-query'}</p> }
  it('shows awaiting payment, preserves the saved checkout and links back to the original order', async () => {
    window.sessionStorage.setItem('hafapass:active-checkout:pending-event', '950')
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/config' ? { launch_capabilities: {} } : pending }))
    render(<MemoryRouter initialEntries={['/orders/950/confirmation?payment_intent_client_secret=private&payment_intent=pi_950&redirect_status=succeeded']}>
      <LocationProbe /><Routes><Route path='/orders/:id/confirmation' element={<OrderConfirmationPage />} /></Routes>
    </MemoryRouter>)
    expect(await screen.findByRole('heading', { name: 'Your payment is not complete' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Resume payment' })).toHaveAttribute('href', '/checkout/pending-event?resume=950')
    expect(window.sessionStorage.getItem('hafapass:active-checkout:pending-event')).toBe('950')
    expect(screen.getByTestId('query')).toHaveTextContent('clean-query')
    expect(screen.queryByText('This page refreshes automatically. Do not submit another payment.')).not.toBeInTheDocument()
  })
})


describe('confirmation ticket hierarchy and outcome', () => {
  beforeEach(() => { vi.clearAllMocks(); window.sessionStorage.clear(); window.localStorage.clear(); vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '') })
  const order = { id: 924, reference: 'HP-924', status: 'completed', buyer_email: 'guest@example.invalid', total_cents: 0, order_items: [],
    tickets: [{ id: 1, status: 'issued', admission_allowed: true, refundable_cents: 0, display_credential: 'display', ticket_type: { id: 7, name: 'Entry' } }],
    event: { id: 37, slug: 'event', title: 'Event', status: 'published', starts_at: '2026-10-20T08:00:00Z', timezone: 'Pacific/Guam', transfers_enabled: false } }
  const mount = value => { apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/config' ? { launch_capabilities: {} } : value })); render(<MemoryRouter initialEntries={['/orders/924/confirmation?guest_token=guest-token']}><Routes><Route path='/orders/:id/confirmation' element={<OrderConfirmationPage />} /></Routes></MemoryRouter>) }
  it('leads with one clearly named ticket action before delivery and receipt', async () => {
    mount(order)
    const open = await screen.findByRole('link', { name: 'Open ticket: Entry' })
    expect(open).toHaveAttribute('href', '/tickets/display?order=924')
    expect(screen.queryByRole('link', { name: 'Download ticket' })).not.toBeInTheDocument()
    const tickets = document.getElementById('order-tickets')
    const email = screen.getByRole('heading', { name: 'Ticket email' })
    expect(tickets.compareDocumentPosition(email) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })
  it.each([['cancelled', 'Order cancelled'], ['expired', 'Reservation expired'], ['refunded', 'Your order was refunded']])('does not display a confirmed outcome for %s', async (status, title) => {
    mount({ ...order, status, tickets: [] })
    expect(await screen.findByRole('heading', { name: title })).toBeInTheDocument()
    expect(screen.queryByLabelText('Order confirmed')).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: /Open ticket:/ })).not.toBeInTheDocument()
  })
  it('shows status access without a misleading admission action when tickets are blocked', async () => {
    mount({ ...order, ticket_access_blocked: true })
    expect(await screen.findByRole('link', { name: 'View ticket' })).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: /Open ticket:/ })).not.toBeInTheDocument()
  })
  it('distinguishes a paused ticket from an admitted sibling in the same unblocked order', async () => {
    mount({ ...order, tickets: [order.tickets[0], { ...order.tickets[0], id: 2, display_credential: 'paused-display', admission_allowed: false, admission_block_reason: 'Ticket access is paused while its refund is pending', ticket_type: { id: 8, name: 'Refund-paused entry' } }] })
    expect(await screen.findByRole('link', { name: 'Open ticket: Entry' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'View ticket' })).toHaveAttribute('href', '/tickets/paused-display?order=924')
    expect(screen.getByText('Ticket access is paused while its refund is pending')).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Open ticket: Refund-paused entry' })).not.toBeInTheDocument()
  })

})

describe('pending ticket transfer on the order page', () => {
  beforeEach(() => { vi.clearAllMocks(); window.sessionStorage.clear(); window.localStorage.clear() })

  it('shows the pending transfer, hides Transfer, and cancels it with the guest token', async () => {
    const ticket = { id: 1, status: 'issued', admission_allowed: true, refundable_cents: 0, display_credential: 'signed-display', ticket_type: { id: 7, name: 'Free admission' } }
    const base = {
      id: 922, reference: 'HP-922', status: 'completed', buyer_name: 'Guest', buyer_email: 'guest@example.invalid', total_cents: 0,
      order_items: [], event: { id: 37, slug: 'free-event', title: 'Free Event', status: 'published', starts_at: '2030-10-20T08:00:00Z', timezone: 'Pacific/Guam', venue_name: 'Venue', transfers_enabled: true },
    }
    let current = { ...base, tickets: [{ ...ticket, pending_transfer: { id: 5, recipient_email: 'friend@example.com', expires_at: '2030-10-27T08:00:00Z' } }] }
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/config' ? { launch_capabilities: { ticket_transfers: true } } : current }))
    apiClient.delete.mockImplementation(() => { current = { ...base, tickets: [ticket] }; return Promise.resolve({ data: { status: 'cancelled' } }) })
    render(<MemoryRouter initialEntries={['/orders/922/confirmation?guest_token=guest-token']}><Routes>
      <Route path="/orders/:id/confirmation" element={<OrderConfirmationPage />} />
    </Routes></MemoryRouter>)

    expect((await screen.findByText(/Transfer pending/)).closest('p')).toHaveTextContent('sent to friend@example.com · expires Oct 27')
    expect(screen.queryByRole('button', { name: 'Transfer' })).not.toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Cancel transfer' }))
    await userEvent.click(screen.getByRole('button', { name: 'Keep transfer' }))
    expect(apiClient.delete).not.toHaveBeenCalled()
    await userEvent.click(screen.getByRole('button', { name: 'Cancel transfer' }))
    const dialog = screen.getByRole('dialog', { name: 'Cancel this transfer?' })
    await userEvent.click(within(dialog).getByRole('button', { name: 'Cancel transfer' }))

    expect(await screen.findByText('Transfer cancelled. Your ticket stays with you.')).toBeInTheDocument()
    expect(apiClient.delete).toHaveBeenCalledWith('/orders/922/tickets/1/transfer', { headers: expect.objectContaining({ 'X-Guest-Order-Token': 'guest-token' }) })
    expect(await screen.findByRole('button', { name: 'Transfer' })).toBeInTheDocument()
    expect(screen.queryByText(/Transfer pending/)).not.toBeInTheDocument()
  })
})
