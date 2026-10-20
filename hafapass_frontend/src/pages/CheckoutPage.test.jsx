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
import * as orderAccess from '../utils/orderAccess'

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
  afterEach(() => { vi.unstubAllEnvs(); vi.restoreAllMocks() })

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

  it('shows a retryable error instead of a guessed fee, then the all-in fee from the server', async () => {
    const event = { id: 38, slug: 'paid-event', title: 'Paid Event', timezone: 'Pacific/Guam', buyer_fee_percent: 100, ticket_types: [{ id: 8, name: 'Admission', price_cents: 2500 }] }
    const configs = [
      { payment_mode: 'simulate', buyer_terms_version: 'buyer-v1' },
      { payment_mode: 'simulate', buyer_terms_version: 'buyer-v1', service_fee_percent: '5.0', service_fee_flat_cents: 100, processing_fee_bearer: 'platform' },
    ]
    apiClient.get.mockImplementation(url => url === '/config' ? Promise.resolve({ data: configs.shift() }) : new Promise(() => {}))
    render(<MemoryRouter initialEntries={[{ pathname: '/checkout/paid-event', state: { event, lineItems: [{ ticket_type_id: 8, quantity: 2 }] } }]}>
      <Routes><Route path="/checkout/:slug" element={<CheckoutPage />} /></Routes>
    </MemoryRouter>)

    expect(await screen.findByText('checkout.feesUnavailable')).toBeInTheDocument()
    expect(screen.queryByText('checkout.total')).not.toBeInTheDocument()
    await userEvent.setup().click(screen.getByRole('button', { name: 'checkout.retryFees' }))

    expect(await screen.findByText('checkout.serviceFeeIncludesProcessing')).toBeInTheDocument()
    // 5% of $50.00 + 2 × $1.00 = $4.50, so the buyer total is $54.50.
    expect(screen.getByText('$4.50')).toBeInTheDocument()
    expect(screen.getByText('$54.50')).toBeInTheDocument()
  })

  it('charges the flat fee only on paid tickets in a mixed order', async () => {
    const event = { id: 40, slug: 'paid-event', title: 'Paid Event', timezone: 'Pacific/Guam', buyer_fee_percent: 100, ticket_types: [{ id: 8, name: 'Admission', price_cents: 2500 }, { id: 9, name: 'Child', price_cents: 0 }] }
    apiClient.get.mockImplementation(url => url === '/config'
      ? Promise.resolve({ data: { payment_mode: 'simulate', buyer_terms_version: 'buyer-v1', service_fee_percent: '5.0', service_fee_flat_cents: 100, processing_fee_bearer: 'platform' } })
      : new Promise(() => {}))
    render(<MemoryRouter initialEntries={[{ pathname: '/checkout/paid-event', state: { event, lineItems: [{ ticket_type_id: 8, quantity: 2 }, { ticket_type_id: 9, quantity: 2 }] } }]}>
      <Routes><Route path="/checkout/:slug" element={<CheckoutPage />} /></Routes>
    </MemoryRouter>)

    // 5% of $50.00 + 2 paid tickets × $1.00 = $4.50, not $6.50.
    expect(await screen.findByText('$4.50')).toBeInTheDocument()
    expect(screen.getByText('$54.50')).toBeInTheDocument()
  })

  it('does not claim the fee includes card processing when the organizer bears it', async () => {
    const event = { id: 39, slug: 'paid-event', title: 'Paid Event', timezone: 'Pacific/Guam', buyer_fee_percent: 100, ticket_types: [{ id: 8, name: 'Admission', price_cents: 2500 }] }
    apiClient.get.mockImplementation(url => url === '/config'
      ? Promise.resolve({ data: { payment_mode: 'simulate', buyer_terms_version: 'buyer-v1', service_fee_percent: '5.0', service_fee_flat_cents: 100, processing_fee_bearer: 'organizer' } })
      : new Promise(() => {}))
    render(<MemoryRouter initialEntries={[{ pathname: '/checkout/paid-event', state: { event, lineItems: [{ ticket_type_id: 8, quantity: 1 }] } }]}>
      <Routes><Route path="/checkout/:slug" element={<CheckoutPage />} /></Routes>
    </MemoryRouter>)

    expect(await screen.findByText('$2.25')).toBeInTheDocument()
    expect(screen.queryByText('checkout.serviceFeeIncludesProcessing')).not.toBeInTheDocument()
  })

  it('keeps a completed free order on its lazy confirmation route and stores recovery access', async () => {
    const event = { id: 37, slug: 'free-event', title: 'Free Event', timezone: 'Pacific/Guam', ticket_types: [{ id: 7, name: 'Free admission', price_cents: 0 }] }
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'simulate', buyer_terms_version: 'buyer-v1', service_fee_percent: '3.0', service_fee_flat_cents: 0 } })
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

  it.each(['saved', 'resume'])('returns a %s payment recovery to fresh event selection after confirmed cancellation', async source => {
    if (source === 'saved') window.sessionStorage.setItem('hafapass:active-checkout:paid-event', '923')
    window.sessionStorage.setItem('hafapass:order-access:923', 'saved-buyer-token')
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'test' } })
    apiClient.post.mockResolvedValueOnce({ data: {
      id: 923, status: 'pending', client_secret: 'original-secret', stripe_publishable_key: 'pk_test',
      total_cents: 1000, event: { slug: 'paid-event', title: 'Paid event' },
      order_items: [{ id: 1, name: 'Admission', quantity: 1, unit_price_cents: 1000, subtotal_cents: 1000 }],
    } })
    let confirmCancellation
    apiClient.post.mockImplementationOnce(() => new Promise(resolve => { confirmCancellation = resolve }))
    render(<MemoryRouter initialEntries={[source === 'resume' ? '/checkout/paid-event?resume=923' : '/checkout/paid-event']}><Routes>
      <Route path='/checkout/:slug' element={<CheckoutPage />} />
      <Route path='/events/:slug' element={<h1>Choose available tickets again</h1>} />
    </Routes></MemoryRouter>)
    await screen.findByText('Payment form')
    const user = userEvent.setup()
    const edit = screen.getByRole('button', { name: 'checkout.editInfo' })
    await user.click(edit)
    expect(edit).toBeDisabled()
    await user.click(edit)
    expect(apiClient.post).toHaveBeenCalledTimes(2)
    expect(getActiveCheckout('paid-event')).toBe('923')
    await act(async () => confirmCancellation({ data: { status: 'cancelled' } }))
    expect(await screen.findByRole('heading', { name: 'Choose available tickets again' })).toBeInTheDocument()
    expect(getActiveCheckout('paid-event')).toBeNull()
    expect(getCheckoutAttempt('paid-event')).toBeNull()
    expect(getOrderAccess(923)).toBe('saved-buyer-token')
    expect(apiClient.post).toHaveBeenNthCalledWith(2, '/orders/923/cancel', {}, { headers: { 'X-Guest-Order-Token': 'saved-buyer-token' } })
    expect(apiClient.post).toHaveBeenCalledTimes(2)
  })

  it.each(['false', 'throws', 'read throws', 'partial clear'])('withdraws cancelled payment when saved-checkout cleanup %s', async outcome => {
    window.sessionStorage.setItem('hafapass:order-access:923', 'saved-buyer-token')
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'test' } })
    apiClient.post.mockResolvedValueOnce({ data: {
      id: 923, status: 'pending', client_secret: 'original-secret', stripe_publishable_key: 'pk_test',
      total_cents: 1000, event: { slug: 'paid-event', title: 'Paid event' },
      order_items: [{ id: 1, name: 'Admission', quantity: 1, unit_price_cents: 1000, subtotal_cents: 1000 }],
    } })
    apiClient.post.mockImplementationOnce(async () => {
      if (outcome === 'read throws') {
        const get = Storage.prototype.getItem
        vi.spyOn(Storage.prototype, 'getItem').mockImplementation(function (key) {
          if (key === 'hafapass:active-checkout:paid-event') throw new Error('Synthetic read failure')
          return get.call(this, key)
        })
      }
      if (outcome === 'partial clear') {
        const remove = Storage.prototype.removeItem
        vi.spyOn(Storage.prototype, 'removeItem').mockImplementation(function (key) {
          if (key === 'hafapass:active-checkout-buyer:paid-event') throw new Error('Synthetic partial removal')
          return remove.call(this, key)
        })
      }
      return { data: { status: 'cancelled' } }
    })
    render(<MemoryRouter initialEntries={['/checkout/paid-event?resume=923']}><Routes>
      <Route path='/checkout/:slug' element={<CheckoutPage />} />
    </Routes></MemoryRouter>)
    await screen.findByText('Payment form')
    if (['false', 'throws'].includes(outcome)) {
      const clear = vi.spyOn(orderAccess, 'clearActiveCheckout')
      if (outcome === 'false') clear.mockReturnValueOnce(false)
      else clear.mockImplementationOnce(() => { throw new Error('Synthetic storage failure') })
    }
    await userEvent.setup().click(screen.getByRole('button', { name: 'checkout.editInfo' }))
    expect(await screen.findByText(/Your order was cancelled, but this page could not reset/)).toBeInTheDocument()
    expect(screen.queryByText('Payment form')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Reload checkout' })).toBeInTheDocument()
    vi.restoreAllMocks()
    expect(getActiveCheckout('paid-event')).toBe(outcome === 'partial clear' ? null : '923')
    expect(getOrderAccess(923)).toBe('saved-buyer-token')
    expect(apiClient.post).toHaveBeenCalledTimes(2)
  })

  it.each(['rejected', 'lost response', 'unconfirmed success'])('retains the original recovered payment after %s cancellation', async outcome => {
    window.sessionStorage.setItem('hafapass:order-access:923', 'saved-buyer-token')
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'test' } })
    const order = { id: 923, status: 'pending', client_secret: 'original-secret', stripe_publishable_key: 'pk_test',
      total_cents: 1000, event: { slug: 'paid-event', title: 'Paid event' },
      order_items: [{ id: 1, name: 'Admission', quantity: 1, unit_price_cents: 1000, subtotal_cents: 1000 }] }
    apiClient.post.mockResolvedValueOnce({ data: order })
    if (outcome === 'rejected') apiClient.post.mockRejectedValueOnce({ response: { status: 422, data: { error: 'Payment is processing; cancellation unavailable' } } })
    else if (outcome === 'lost response') apiClient.post.mockRejectedValueOnce(new Error('Response lost'))
    else apiClient.post.mockResolvedValueOnce({ data: { status: 'pending' } })
    const tree = <MemoryRouter initialEntries={['/checkout/paid-event?resume=923']}><Routes>
      <Route path='/checkout/:slug' element={<CheckoutPage />} />
      <Route path='/events/:slug' element={<h1>Unsafe new selection</h1>} />
    </Routes></MemoryRouter>
    const view = render(tree)
    await screen.findByText('Payment form')
    await userEvent.setup().click(screen.getByRole('button', { name: 'checkout.editInfo' }))
    expect(await screen.findByRole('alert')).toHaveTextContent(outcome === 'rejected'
      ? 'Payment is processing; cancellation unavailable' : 'We could not confirm cancellation')
    expect(screen.getByText('Payment form')).toBeInTheDocument()
    expect(screen.queryByText('Unsafe new selection')).not.toBeInTheDocument()
    expect(getActiveCheckout('paid-event')).toBe('923')
    expect(getOrderAccess(923)).toBe('saved-buyer-token')
    expect(getCheckoutAttempt('paid-event')).toBeNull()
    expect(apiClient.post).toHaveBeenCalledTimes(2)
    // A page reload still recovers the same reservation with the same capability.
    view.unmount()
    apiClient.post.mockResolvedValueOnce({ data: order })
    render(tree)
    expect(await screen.findByText('Payment form')).toBeInTheDocument()
    expect(apiClient.post).toHaveBeenNthCalledWith(3, '/orders/923/payment_resume', {}, { headers: { 'X-Guest-Order-Token': 'saved-buyer-token' } })
    expect(apiClient.post).toHaveBeenCalledTimes(3)
  })

  it('keeps the original selection and buyer form when cancelling a payment created in the current visit', async () => {
    const event = { id: 37, slug: 'paid-event', title: 'Paid event', ticket_types: [{ id: 7, name: 'Admission', price_cents: 1000 }] }
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'test', buyer_terms_version: 'buyer-v1', service_fee_percent: '3.0', service_fee_flat_cents: 0 } })
    apiClient.post.mockResolvedValueOnce({ data: { id: 923, client_secret: 'new-secret', stripe_publishable_key: 'pk_test', guest_access_token: 'new-buyer-token' } })
    apiClient.post.mockResolvedValueOnce({ data: { status: 'cancelled' } })
    render(<MemoryRouter initialEntries={[{ pathname: '/checkout/paid-event', state: { event, lineItems: [{ ticket_type_id: 7, quantity: 1 }] } }]}><Routes>
      <Route path='/checkout/:slug' element={<CheckoutPage />} />
      <Route path='/events/:slug' element={<h1>Selection unnecessarily lost</h1>} />
    </Routes></MemoryRouter>)
    const user = userEvent.setup()
    await user.type(await screen.findByLabelText('checkout.fullName'), 'Guest Buyer')
    await user.type(screen.getByLabelText('checkout.emailAddress'), 'guest@example.invalid')
    await user.click(screen.getByRole('checkbox'))
    await user.click(screen.getByRole('button', { name: /checkout.continueToPayment/ }))
    await screen.findByText('Payment form')
    await user.click(screen.getByRole('button', { name: 'checkout.editInfo' }))
    expect(await screen.findByLabelText('checkout.fullName')).toHaveValue('Guest Buyer')
    expect(screen.getByLabelText('checkout.emailAddress')).toHaveValue('guest@example.invalid')
    expect(screen.getByText('Admission')).toBeInTheDocument()
    expect(screen.queryByText('Selection unnecessarily lost')).not.toBeInTheDocument()
    expect(getActiveCheckout('paid-event')).toBeNull()
    expect(apiClient.post).toHaveBeenCalledTimes(2)
    expect(apiClient.post).toHaveBeenNthCalledWith(2, '/orders/923/cancel', {}, { headers: { 'X-Guest-Order-Token': 'new-buyer-token' } })
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
      ? Promise.resolve({ data: { payment_mode: 'simulate', buyer_terms_version: 'buyer-v1', service_fee_percent: '3.0', service_fee_flat_cents: 0 } })
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
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'simulate', buyer_terms_version: 'buyer-v1', service_fee_percent: '3.0', service_fee_flat_cents: 0 } })
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
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'simulate', buyer_terms_version: 'buyer-v1', service_fee_percent: '3.0', service_fee_flat_cents: 0 } })
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

  it('shows the server buyer when a paid recovery follows local edits after a lost response', async () => {
    const event = { id: 37, slug: 'paid-event', title: 'Paid Event', timezone: 'Pacific/Guam', ticket_types: [{ id: 7, name: 'Admission', price_cents: 1000 }] }
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'test', buyer_terms_version: 'buyer-v1', service_fee_percent: '3.0', service_fee_flat_cents: 0 } })
    apiClient.post.mockRejectedValueOnce(new Error('Response lost'))
    render(<MemoryRouter initialEntries={[{ pathname: '/checkout/paid-event', state: { event, lineItems: [{ ticket_type_id: 7, quantity: 1 }] } }]}><Routes>
      <Route path='/checkout/:slug' element={<CheckoutPage />} />
    </Routes></MemoryRouter>)
    const user = userEvent.setup()
    await user.type(await screen.findByLabelText('checkout.fullName'), 'Original Buyer')
    await user.type(screen.getByLabelText('checkout.emailAddress'), 'original@example.invalid')
    await user.click(screen.getByRole('checkbox'))
    await user.click(screen.getByRole('button', { name: /checkout.continueToPayment/ }))
    await screen.findByRole('button', { name: 'Recover earlier checkout' })
    const original = apiClient.post.mock.calls[0][1]
    await user.clear(screen.getByLabelText('checkout.fullName'))
    await user.type(screen.getByLabelText('checkout.fullName'), 'Edited Buyer')
    await user.clear(screen.getByLabelText('checkout.emailAddress'))
    await user.type(screen.getByLabelText('checkout.emailAddress'), 'edited@example.invalid')
    apiClient.post.mockResolvedValueOnce({ data: { id: 925, guest_access_token: 'original-access' } })
    apiClient.post.mockResolvedValueOnce({ data: { id: 925, event, buyer_name: 'Original Buyer', buyer_email: 'original@example.invalid', client_secret: 'test-original-secret', stripe_publishable_key: 'pk_test_fixture', expires_at: new Date(Date.now() + 300000).toISOString(), total_cents: 1080, order_items: [{ ticket_type_id: 7, name: 'Admission', quantity: 1, unit_price_cents: 1000 }] } })
    await user.click(screen.getByRole('button', { name: 'Recover earlier checkout' }))
    expect(await screen.findByText('Payment form')).toBeInTheDocument()
    expect(screen.getByText('Original Buyer')).toBeInTheDocument()
    expect(screen.getByText(/original@example.invalid/)).toBeInTheDocument()
    expect(screen.queryByText('Edited Buyer')).not.toBeInTheDocument()
    expect(screen.queryByText(/edited@example.invalid/)).not.toBeInTheDocument()
    expect(apiClient.post).toHaveBeenNthCalledWith(2, '/orders', original)
    expect(apiClient.post).toHaveBeenCalledTimes(3)
  })

  it('preserves buyer edits after a lost response and explicitly recovers the original order', async () => {
    const event = { id: 37, slug: 'free-event', title: 'Free Event', timezone: 'Pacific/Guam', ticket_types: [{ id: 7, name: 'Free admission', price_cents: 0 }] }
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'simulate', buyer_terms_version: 'buyer-v1', service_fee_percent: '3.0', service_fee_flat_cents: 0 } })
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


describe('registration error recovery', () => {
  beforeEach(() => {
    vi.clearAllMocks(); apiClient.get.mockReset(); apiClient.post.mockReset(); window.sessionStorage.clear(); window.localStorage.clear()
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '')
    vi.stubGlobal('requestAnimationFrame', callback => callback())
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'simulate', buyer_terms_version: 'qa-v1', service_fee_percent: '3.0', service_fee_flat_cents: 0 } })
    apiClient.post.mockRejectedValue({ response: { status: 503, data: { checkout_recovery_required: true, error: 'Synthetic outcome unknown' } } })
  })
  afterEach(() => { vi.unstubAllGlobals(); vi.unstubAllEnvs() })
  const event = { id: 37, slug: 'registration', title: 'Registration', ticket_types: [{ id: 7, name: 'Entry', price_cents: 0 }],
    registration_questions: [{ id: 17, prompt: 'Meal preference', required: true, kind: 'short_text' },
      { id: 18, prompt: 'Will you attend dinner?', required: true, kind: 'checkbox' }],
    waivers: [{ id: 19, title: 'Synthetic participation rules', body: 'Test fixture only.', required: true, version: 'qa-v1' }] }
  function mount() { render(<MemoryRouter initialEntries={[{ pathname: '/checkout/registration', state: { event, lineItems: [{ ticket_type_id: 7, quantity: 1 }] } }]}><Routes><Route path='/checkout/:slug' element={<CheckoutPage />} /></Routes></MemoryRouter>) }
  it('focuses the missing dynamic answer and links its error, then moves to the missing waiver without losing answers', async () => {
    mount(); const user = userEvent.setup()
    await user.type(await screen.findByLabelText('checkout.fullName'), 'Synthetic Buyer')
    await user.type(screen.getByLabelText('checkout.emailAddress'), 'buyer@example.invalid')
    await user.click(document.getElementById('termsAccepted'))
    await user.click(screen.getByRole('button', { name: /checkout.placeOrder/ }))
    const meal = screen.getByLabelText('Meal preference *')
    expect(meal).toHaveFocus()
    expect(meal).toHaveAttribute('aria-invalid', 'true')
    expect(meal).toHaveAttribute('aria-describedby', 'question-17-error')
    expect(screen.getByRole('link', { name: 'Meal preference: This answer is required' })).toHaveAttribute('href', '#question-17')
    expect(apiClient.post).not.toHaveBeenCalled()
    await user.type(meal, 'Vegetarian')
    await user.selectOptions(screen.getByLabelText('Will you attend dinner? *'), 'false')
    await user.click(screen.getByRole('button', { name: /checkout.placeOrder/ }))
    expect(document.getElementById('waiver-19')).toHaveFocus()
    expect(document.getElementById('waiver-19')).toHaveAttribute('aria-describedby', 'waiver-19-error')
    expect(meal).toHaveValue('Vegetarian')
    await user.click(document.getElementById('waiver-19'))
    await user.click(screen.getByRole('button', { name: /checkout.placeOrder/ }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/orders', expect.objectContaining({ registration_answers: { 17: 'Vegetarian', 18: false }, waiver_acceptances: [{ event_waiver_id: 19, version: 'qa-v1' }] })))
  })
})
