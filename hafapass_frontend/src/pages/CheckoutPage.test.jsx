import { lazy, Suspense } from 'react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation, useOutlet } from 'react-router-dom'
import { motion, AnimatePresence } from 'framer-motion'
import CheckoutPage from './CheckoutPage'
import apiClient from '../api/client'
import { getActiveCheckout, getOrderAccess, getCheckoutAttempt } from '../utils/orderAccess'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('../components/SEO', () => ({ default: () => null }))
vi.mock('../components/StripeProvider', () => ({ default: ({ children }) => children }))
vi.mock('../components/PaymentForm', () => ({ default: () => <p>Payment form</p> }))
vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: key => key }) }))
vi.mock('../utils/marketplaceAttribution', () => ({ anonymousId: () => 'test-anonymous', currentAttribution: () => ({}), trackFunnel: vi.fn() }))

function RetainedRoute() {
  const location = useLocation()
  const outlet = useOutlet()
  return <AnimatePresence mode="popLayout"><motion.div key={location.pathname} exit={{ opacity: 0 }} transition={{ duration: 1 }}>{outlet}</motion.div></AnimatePresence>
}

describe('checkout navigation', () => {
  beforeEach(() => { vi.clearAllMocks(); apiClient.post.mockReset(); apiClient.get.mockReset(); window.sessionStorage.clear() })

  it('keeps a completed free order on its lazy confirmation route and stores recovery access', async () => {
    const event = { id: 37, slug: 'free-event', title: 'Free Event', timezone: 'Pacific/Guam', ticket_types: [{ id: 7, name: 'Free admission', price_cents: 0 }] }
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'simulate', buyer_terms_version: 'buyer-v1', service_fee_flat_cents: 0 } })
    apiClient.post.mockResolvedValue({ data: { id: 922, status: 'completed', guest_access_token: 'guest-token' } })
    let openConfirmation
    const Confirmation = lazy(() => new Promise(resolve => { openConfirmation = () => resolve({ default: () => <h1>Confirmed order 922</h1> }) }))
    render(<MemoryRouter initialEntries={[{ pathname: '/checkout/free-event', state: { event, lineItems: [{ ticket_type_id: 7, quantity: 1 }] } }]}>
      <Suspense fallback={<p>Loading confirmation</p>}><Routes><Route element={<RetainedRoute />}>
        <Route path="/checkout/:slug" element={<CheckoutPage />} />
        <Route path="/orders/:id/confirmation" element={<Confirmation />} />
        <Route path="/events/:slug" element={<h1>Unexpected event redirect</h1>} />
      </Route></Routes></Suspense>
    </MemoryRouter>)
    const user = userEvent.setup()
    await user.type(await screen.findByLabelText('checkout.fullName'), 'Guest Buyer')
    await user.type(screen.getByLabelText('checkout.emailAddress'), 'guest@example.invalid')
    await user.click(screen.getByRole('checkbox'))
    await user.click(screen.getByRole('button', { name: /checkout.placeOrder/ }))
    await waitFor(() => expect(openConfirmation).toBeTypeOf('function'))
    expect(getOrderAccess(922)).toBe('guest-token')
    expect(getActiveCheckout('free-event')).toBe('922')
    openConfirmation()
    expect(await screen.findByRole('heading', { name: 'Confirmed order 922' })).toBeInTheDocument()
    expect(screen.queryByText('Unexpected event redirect')).not.toBeInTheDocument()
    expect(apiClient.post.mock.calls[0][1]).toMatchObject({ event_id: 37, buyer_name: 'Guest Buyer', buyer_email: 'guest@example.invalid', terms_accepted: true, terms_version: 'buyer-v1', line_items: [{ ticket_type_id: 7, quantity: 1 }] })
  })
  it('restores an unpaid checkout after reload using its original intent and guest access', async () => {
    window.sessionStorage.setItem('hafapass:active-checkout:paid-event', '923')
    window.sessionStorage.setItem('hafapass:order-access:923', 'saved-buyer-token')
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'test' } })
    apiClient.post.mockResolvedValue({ data: {
      id: 923, status: 'pending', client_secret: 'original-secret', stripe_publishable_key: 'pk_test',
      total_cents: 1080, expires_at: new Date(Date.now() + 300000).toISOString(),
      event: { slug: 'paid-event', title: 'Paid event', timezone: 'Pacific/Guam' },
      order_items: [{ id: 1, name: 'Admission', quantity: 1, unit_price_cents: 1000, subtotal_cents: 1000 }],
    } })
    render(<MemoryRouter initialEntries={['/checkout/paid-event']}><Routes>
      <Route path='/checkout/:slug' element={<CheckoutPage />} />
      <Route path='/events/:slug' element={<p>Incorrect redirect</p>} />
    </Routes></MemoryRouter>)
    expect(await screen.findByText('Payment form')).toBeInTheDocument()
    expect(screen.queryByText('Incorrect redirect')).not.toBeInTheDocument()
    expect(apiClient.post).toHaveBeenCalledWith('/orders/923/payment_resume', {}, { headers: { 'X-Guest-Order-Token': 'saved-buyer-token' } })
    expect(apiClient.post).toHaveBeenCalledTimes(1)
  })

  it('recovers a lost order response with the persisted request before resuming', async () => {
    const payload = { event_id: 1, buyer_email: 'buyer@example.invalid', checkout_key: 'a'.repeat(64) }
    window.sessionStorage.setItem('hafapass:checkout-attempt:paid-event', JSON.stringify({ payload, expiresAt: Date.now() + 300000 }))
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'test' } })
    apiClient.post.mockImplementation(url => Promise.resolve({ data: url === '/orders'
      ? { id: 924, guest_access_token: 'recovered-access' }
      : { id: 924, status: 'completed' } }))
    render(<MemoryRouter initialEntries={['/checkout/paid-event']}><Routes>
      <Route path='/checkout/:slug' element={<CheckoutPage />} />
      <Route path='/orders/:id/confirmation' element={<h1>Recovered confirmation</h1>} />
      <Route path='/events/:slug' element={<p>Incorrect redirect</p>} />
    </Routes></MemoryRouter>)
    expect(await screen.findByText('Recovered confirmation')).toBeInTheDocument()
    expect(apiClient.post).toHaveBeenNthCalledWith(1, '/orders', payload)
    expect(apiClient.post).toHaveBeenNthCalledWith(2, '/orders/924/payment_resume', {}, { headers: { 'X-Guest-Order-Token': 'recovered-access' } })
  })

  it('clears a saved invalid attempt after definitive no-order rejection and offers a new checkout', async () => {
    const payload = { event_id: 1, terms_version: 'outdated', checkout_key: 'a'.repeat(64) }
    window.sessionStorage.setItem('hafapass:checkout-attempt:paid-event', JSON.stringify({ payload, expiresAt: Date.now() + 300000 }))
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'test' } })
    apiClient.post.mockRejectedValue({ response: { status: 422, data: { error: 'Accept current terms', checkout_recovery_required: false } } })
    render(<MemoryRouter initialEntries={['/checkout/paid-event']}><Routes>
      <Route path='/checkout/:slug' element={<CheckoutPage />} />
      <Route path='/events/:slug' element={<p>Select tickets again</p>} />
    </Routes></MemoryRouter>)
    await userEvent.setup().click(await screen.findByRole('button', { name: 'Start a new checkout' }))
    expect(await screen.findByText('Select tickets again')).toBeInTheDocument()
    expect(getCheckoutAttempt('paid-event')).toBeNull()
    expect(apiClient.post).toHaveBeenCalledTimes(1)
  })

  it.each([408, 429, 503, 422])('retains saved recovery on ambiguous status %s without offering another checkout', async status => {
    const payload = { event_id: 1, checkout_key: 'a'.repeat(64) }
    window.sessionStorage.setItem('hafapass:checkout-attempt:paid-event', JSON.stringify({ payload, expiresAt: Date.now() + 300000 }))
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'test' } })
    apiClient.post.mockRejectedValue({ response: { status, data: { error: 'Checkout unconfirmed' } } })
    render(<MemoryRouter initialEntries={['/checkout/paid-event']}><Routes><Route path='/checkout/:slug' element={<CheckoutPage />} /></Routes></MemoryRouter>)
    expect(await screen.findByRole('button', { name: 'Retry saved checkout' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Start a new checkout' })).not.toBeInTheDocument()
    expect(getCheckoutAttempt('paid-event').payload).toEqual(payload)
  })

  it('submits corrected buyer details with a fresh identity after a definitive no-order validation error', async () => {
    const event = { id: 37, slug: 'free-event', title: 'Free Event', timezone: 'Pacific/Guam', ticket_types: [{ id: 7, name: 'Free admission', price_cents: 0 }] }
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'simulate', buyer_terms_version: 'buyer-v1', service_fee_flat_cents: 0 } })
    apiClient.post.mockRejectedValueOnce({ response: { status: 422, data: { error: 'Correct buyer details', checkout_recovery_required: false } } })
    render(<MemoryRouter initialEntries={[{ pathname: '/checkout/free-event', state: { event, lineItems: [{ ticket_type_id: 7, quantity: 1 }] } }]}><Routes>
      <Route path='/checkout/:slug' element={<CheckoutPage />} />
      <Route path='/orders/:id/confirmation' element={<h1>Corrected checkout confirmed</h1>} />
    </Routes></MemoryRouter>)
    const user = userEvent.setup()
    await user.type(await screen.findByLabelText('checkout.fullName'), 'Guest Buyer')
    const email = screen.getByLabelText('checkout.emailAddress')
    await user.type(email, 'original@example.invalid')
    await user.click(screen.getByRole('checkbox'))
    await user.click(screen.getByRole('button', { name: /checkout.placeOrder/ }))
    await screen.findByRole('button', { name: 'Start a new checkout' })
    expect(getCheckoutAttempt('free-event')).toBeNull()
    const originalKey = apiClient.post.mock.calls[0][1].checkout_key
    await user.clear(email)
    await user.type(email, 'corrected@example.invalid')
    apiClient.post.mockResolvedValueOnce({ data: { id: 926, status: 'completed', guest_access_token: 'corrected-access' } })
    await user.click(screen.getByRole('button', { name: /checkout.placeOrder/ }))
    expect(await screen.findByText('Corrected checkout confirmed')).toBeInTheDocument()
    expect(apiClient.post.mock.calls[1][1].buyer_email).toBe('corrected@example.invalid')
    expect(apiClient.post.mock.calls[1][1].checkout_key).not.toBe(originalKey)
  })

  it('preserves buyer edits after a lost response and explicitly recovers the original order', async () => {
    const event = { id: 37, slug: 'free-event', title: 'Free Event', timezone: 'Pacific/Guam', ticket_types: [{ id: 7, name: 'Free admission', price_cents: 0 }] }
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'simulate', buyer_terms_version: 'buyer-v1', service_fee_flat_cents: 0 } })
    apiClient.post.mockRejectedValueOnce(new Error('Response lost'))
    render(<MemoryRouter initialEntries={[{ pathname: '/checkout/free-event', state: { event, lineItems: [{ ticket_type_id: 7, quantity: 1 }] } }]}><Routes>
      <Route path='/checkout/:slug' element={<CheckoutPage />} />
      <Route path='/orders/:id/confirmation' element={<h1>Original order recovered</h1>} />
    </Routes></MemoryRouter>)
    const user = userEvent.setup()
    await user.type(await screen.findByLabelText('checkout.fullName'), 'Guest Buyer')
    const email = screen.getByLabelText('checkout.emailAddress')
    await user.type(email, 'original@example.invalid')
    await user.click(screen.getByRole('checkbox'))
    await user.click(screen.getByRole('button', { name: /checkout.placeOrder/ }))
    await screen.findByRole('button', { name: 'Recover earlier checkout' })
    const original = apiClient.post.mock.calls[0][1]
    await user.clear(email)
    await user.type(email, 'edited@example.invalid')
    await user.click(screen.getByRole('button', { name: /checkout.placeOrder/ }))
    expect(await screen.findByText(/earlier checkout is still unconfirmed/)).toBeInTheDocument()
    expect(email).toHaveValue('edited@example.invalid')
    expect(apiClient.post).toHaveBeenCalledTimes(1)
    expect(getCheckoutAttempt('free-event').payload).toEqual(original)
    apiClient.post.mockResolvedValueOnce({ data: { id: 925, guest_access_token: 'original-access' } })
    apiClient.post.mockResolvedValueOnce({ data: { id: 925, status: 'completed' } })
    await user.click(screen.getByRole('button', { name: 'Recover earlier checkout' }))
    expect(await screen.findByText('Original order recovered')).toBeInTheDocument()
    expect(apiClient.post).toHaveBeenNthCalledWith(2, '/orders', original)
    expect(apiClient.post).toHaveBeenCalledTimes(3)
  })
})
