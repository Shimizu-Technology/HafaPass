import { lazy, Suspense } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useAuth } from '@clerk/clerk-react'
import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation, useOutlet } from 'react-router-dom'
import { motion, AnimatePresence } from 'framer-motion'
import CheckoutPage from './CheckoutPage'
import apiClient from '../api/client'
import { getActiveCheckout, getOrderAccess, getCheckoutAttempt } from '../utils/orderAccess'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('@clerk/clerk-react', () => ({ useAuth: vi.fn() }))
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
  beforeEach(() => { vi.clearAllMocks(); apiClient.post.mockReset(); apiClient.get.mockReset(); window.sessionStorage.clear(); window.localStorage.clear() })
  afterEach(() => vi.unstubAllEnvs())

  it('waits for authoritative Clerk hydration and device binding before recovering an unbound legacy attempt', async () => {
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_fixture')
    useAuth.mockReturnValue({ isLoaded: false, userId: undefined })
    window.localStorage.setItem('hafapass_scanner_user_id', 'previous-buyer')
    const payload = { event_id: 37, checkout_key: 'a'.repeat(64) }
    window.sessionStorage.setItem('hafapass:checkout-attempt:free-event', JSON.stringify({ payload, expiresAt: Date.now() + 300000 }))
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'test' } })
    apiClient.post.mockImplementation(url => Promise.resolve({ data: url === '/orders'
      ? { id: 929, guest_access_token: 'authorized-buyer-token' }
      : { id: 929, status: 'completed' } }))
    const tree = <MemoryRouter initialEntries={['/checkout/free-event']}><Routes>
      <Route path='/checkout/:slug' element={<CheckoutPage />} />
      <Route path='/orders/:id/confirmation' element={<p>Same buyer legacy recovery</p>} />
    </Routes></MemoryRouter>
    const view = render(tree)
    expect(screen.getByRole('status')).toHaveTextContent('Preparing your account')
    expect(apiClient.post).not.toHaveBeenCalled()
    useAuth.mockReturnValue({ isLoaded: true, userId: 'buyer-a' })
    view.rerender(<MemoryRouter initialEntries={['/checkout/free-event']}><Routes>
      <Route path='/checkout/:slug' element={<CheckoutPage />} />
      <Route path='/orders/:id/confirmation' element={<p>Same buyer legacy recovery</p>} />
    </Routes></MemoryRouter>)
    expect(apiClient.post).not.toHaveBeenCalled()
    window.localStorage.setItem('hafapass_scanner_user_id', 'buyer-a')
    view.rerender(<MemoryRouter initialEntries={['/checkout/free-event']}><Routes>
      <Route path='/checkout/:slug' element={<CheckoutPage />} />
      <Route path='/orders/:id/confirmation' element={<p>Same buyer legacy recovery</p>} />
    </Routes></MemoryRouter>)
    expect(await screen.findByText('Same buyer legacy recovery')).toBeInTheDocument()
    expect(apiClient.post).toHaveBeenNthCalledWith(1, '/orders', payload)
    expect(apiClient.post).toHaveBeenCalledTimes(2)
    expect(getOrderAccess(929)).toBe('authorized-buyer-token')
    expect(getCheckoutAttempt('free-event')).toBeNull()
  })

  it('requires server authenticated ownership for automatic legacy active-order recovery', async () => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'buyer-a')
    window.sessionStorage.setItem('hafapass:active-checkout:paid-event', '930')
    window.sessionStorage.setItem('hafapass:order-access:930', 'legacy-cached-token')
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'test' } })
    apiClient.post.mockRejectedValue({ response: { status: 403, data: { error: 'Current buyer does not own this order' } } })
    render(<MemoryRouter initialEntries={['/checkout/paid-event']}><Routes><Route path='/checkout/:slug' element={<CheckoutPage />} /></Routes></MemoryRouter>)
    expect(await screen.findByText('Current buyer does not own this order')).toBeInTheDocument()
    expect(apiClient.post).toHaveBeenCalledWith('/orders/930/payment_resume', {}, { headers: {} })
    expect(window.sessionStorage.getItem('hafapass:active-checkout:paid-event')).toBe('930')
    expect(window.sessionStorage.getItem('hafapass:order-access:930')).toBe('legacy-cached-token')
    expect(screen.queryByText('Payment form')).not.toBeInTheDocument()
  })

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

  it('restores the server promo code for a discounted unpaid checkout without a local promo draft', async () => {
    window.sessionStorage.setItem('hafapass:active-checkout:paid-event', '923')
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'test' } })
    apiClient.post.mockResolvedValue({ data: {
      id: 923, status: 'pending', client_secret: 'original-secret', stripe_publishable_key: 'pk_test',
      total_cents: 900, discount_cents: 100, promo_code: { code: 'ISLAND' },
      event: { slug: 'paid-event', title: 'Paid Event', timezone: 'Pacific/Guam' },
      order_items: [{ id: 1, name: 'Admission', quantity: 1, unit_price_cents: 1000, subtotal_cents: 1000 }],
    } })
    render(<MemoryRouter initialEntries={['/checkout/paid-event']}><Routes><Route path='/checkout/:slug' element={<CheckoutPage />} /></Routes></MemoryRouter>)
    expect(await screen.findByText('Payment form')).toBeInTheDocument()
    expect(screen.getByText('ISLAND')).toBeInTheDocument()
    expect(screen.getByText('-$1.00')).toBeInTheDocument()
    expect(apiClient.post).toHaveBeenCalledTimes(1)
  })

  it('retries missing event details without reloading or losing the current ticket selection', async () => {
    apiClient.get.mockImplementation(url => url === '/config'
      ? Promise.resolve({ data: { payment_mode: 'simulate', buyer_terms_version: 'buyer-v1', service_fee_flat_cents: 0 } })
      : Promise.reject(new Error('Event details unavailable')))
    render(<MemoryRouter initialEntries={[{ pathname: '/checkout/free-event', state: { lineItems: [{ ticket_type_id: 7, quantity: 2 }] } }]}><Routes>
      <Route path='/checkout/:slug' element={<CheckoutPage />} />
      <Route path='/events/:slug' element={<p>Lost ticket selection</p>} />
    </Routes></MemoryRouter>)
    await screen.findByText('Unable to load event details.')
    const event = { id: 37, slug: 'free-event', title: 'Free Event', timezone: 'Pacific/Guam', ticket_types: [{ id: 7, name: 'Free admission', price_cents: 0 }] }
    apiClient.get.mockResolvedValue({ data: event })
    await userEvent.setup().click(screen.getByRole('button', { name: 'Retry saved checkout' }))
    expect(await screen.findByLabelText('checkout.fullName')).toBeInTheDocument()
    expect(screen.getByText('× 2')).toBeInTheDocument()
    expect(screen.queryByText('Lost ticket selection')).not.toBeInTheDocument()
    expect(apiClient.post).not.toHaveBeenCalled()
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

  it('does not let a stale start-new action erase an attempt created after the rejection', async () => {
    const payload = { event_id: 37, checkout_key: 'a'.repeat(64) }
    window.sessionStorage.setItem('hafapass:checkout-attempt:free-event', JSON.stringify({ payload, expiresAt: Date.now() + 300000 }))
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'test' } })
    apiClient.post.mockRejectedValue({ response: { status: 422, data: { checkout_recovery_required: false } } })
    render(<MemoryRouter initialEntries={['/checkout/free-event']}><Routes>
      <Route path='/checkout/:slug' element={<CheckoutPage />} />
      <Route path='/events/:slug' element={<p>Unexpected new checkout</p>} />
    </Routes></MemoryRouter>)
    const action = await screen.findByRole('button', { name: 'Start a new checkout' })
    const newer = { buyerId: null, payload: { event_id: 37, checkout_key: 'b'.repeat(64) }, expiresAt: Date.now() + 300000 }
    window.sessionStorage.setItem('hafapass:checkout-attempt:free-event', JSON.stringify(newer))
    await userEvent.setup().click(action)
    expect(getCheckoutAttempt('free-event')).toEqual(newer)
    expect(screen.queryByText('Unexpected new checkout')).not.toBeInTheDocument()
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

  it.each(['reject', 'resolve'])('does not let an unmounted initial submission %s replace a newer uncertain attempt', async outcome => {
    const event = { id: 37, slug: 'free-event', title: 'Free Event', timezone: 'Pacific/Guam', ticket_types: [{ id: 7, name: 'Free admission', price_cents: 0 }] }
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'simulate', buyer_terms_version: 'buyer-v1', service_fee_flat_cents: 0 } })
    let finish
    apiClient.post.mockImplementationOnce(() => new Promise((resolve, reject) => { finish = outcome === 'resolve' ? resolve : reject }))
    const view = render(<MemoryRouter initialEntries={[{ pathname: '/checkout/free-event', state: { event, lineItems: [{ ticket_type_id: 7, quantity: 1 }] } }]}><Routes>
      <Route path='/checkout/:slug' element={<CheckoutPage />} />
      <Route path='/orders/:id/confirmation' element={<p>Old order exposed</p>} />
    </Routes></MemoryRouter>)
    const user = userEvent.setup()
    await user.type(await screen.findByLabelText('checkout.fullName'), 'Guest Buyer')
    await user.type(screen.getByLabelText('checkout.emailAddress'), 'guest@example.invalid')
    await user.click(screen.getByRole('checkbox'))
    await user.click(screen.getByRole('button', { name: /checkout.placeOrder/ }))
    await waitFor(() => expect(finish).toBeTypeOf('function'))
    view.unmount()
    const newer = { payload: { event_id: 37, checkout_key: 'b'.repeat(64) }, expiresAt: Date.now() + 300000 }
    window.sessionStorage.setItem('hafapass:checkout-attempt:free-event', JSON.stringify(newer))
    await act(async () => finish(outcome === 'resolve'
      ? { data: { id: 927, status: 'completed', guest_access_token: 'old-token' } }
      : { response: { status: 422, data: { checkout_recovery_required: false } } }))
    expect(getCheckoutAttempt('free-event')).toEqual(newer)
    expect(getActiveCheckout('free-event')).toBeNull()
    expect(getOrderAccess(927)).toBeNull()
  })

  it.each(['reject', 'resolve'])('does not let a cancelled recovery %s alter a newer attempt or follow its order', async outcome => {
    const initial = { payload: { event_id: 37, checkout_key: 'a'.repeat(64) }, expiresAt: Date.now() + 300000 }
    window.sessionStorage.setItem('hafapass:checkout-attempt:free-event', JSON.stringify(initial))
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'simulate' } })
    let finish
    apiClient.post.mockImplementationOnce(() => new Promise((resolve, reject) => { finish = outcome === 'resolve' ? resolve : reject }))
    const view = render(<MemoryRouter initialEntries={['/checkout/free-event']}><Routes><Route path='/checkout/:slug' element={<CheckoutPage />} /></Routes></MemoryRouter>)
    await waitFor(() => expect(finish).toBeTypeOf('function'))
    view.unmount()
    const newer = { payload: { event_id: 37, checkout_key: 'b'.repeat(64) }, expiresAt: Date.now() + 300000 }
    window.sessionStorage.setItem('hafapass:checkout-attempt:free-event', JSON.stringify(newer))
    await act(async () => finish(outcome === 'resolve'
      ? { data: { id: 927, status: 'completed', guest_access_token: 'old-token' } }
      : { response: { status: 422, data: { checkout_recovery_required: false } } }))
    expect(getCheckoutAttempt('free-event')).toEqual(newer)
    expect(getActiveCheckout('free-event')).toBeNull()
    expect(getOrderAccess(927)).toBeNull()
    expect(apiClient.post).toHaveBeenCalledTimes(1)
  })

  it('does not expose a completed recovery response after the authenticated buyer changes', async () => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'buyer-a')
    const initial = { buyerId: 'buyer-a', payload: { event_id: 37, checkout_key: 'a'.repeat(64) }, expiresAt: Date.now() + 300000 }
    window.sessionStorage.setItem('hafapass:checkout-attempt:free-event', JSON.stringify(initial))
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'simulate' } })
    let finish
    apiClient.post.mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
    apiClient.post.mockResolvedValue({ data: { id: 928, status: 'completed' } })
    render(<MemoryRouter initialEntries={['/checkout/free-event']}><Routes>
      <Route path='/checkout/:slug' element={<CheckoutPage />} />
      <Route path='/orders/:id/confirmation' element={<p>Old account order exposed</p>} />
    </Routes></MemoryRouter>)
    await waitFor(() => expect(finish).toBeTypeOf('function'))
    window.localStorage.setItem('hafapass_scanner_user_id', 'buyer-b')
    await act(async () => finish({ data: { id: 928, status: 'completed', guest_access_token: 'buyer-a-token' } }))
    expect(screen.queryByText('Old account order exposed')).not.toBeInTheDocument()
    expect(getCheckoutAttempt('free-event')).toEqual(initial)
    expect(getOrderAccess(928)).toBeNull()
    expect(apiClient.post).toHaveBeenCalledTimes(1)
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
