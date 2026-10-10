import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, Link, useLocation } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import Layout from '../components/Layout'
import EventDetailPage from './EventDetailPage'
import CheckoutPage from './CheckoutPage'
import apiClient from '../api/client'
import { getActiveCheckout, getCheckoutAttempt } from '../utils/orderAccess'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn(), delete: vi.fn() } }))
vi.mock('@clerk/clerk-react', () => ({ useAuth: () => ({ isLoaded: true, userId: null }) }))
vi.mock('framer-motion', async original => ({ ...(await original()), useReducedMotion: () => true }))
vi.mock('../components/Navbar', () => ({ default: () => null }))
vi.mock('../components/Footer', () => ({ default: () => null }))
vi.mock('../components/EnvironmentBanner', () => ({ default: () => null }))
vi.mock('../components/SEO', () => ({ default: () => null }))
vi.mock('../components/ui/ScrollReveal', () => ({ FadeUp: ({ children }) => children }))
vi.mock('../components/StripeProvider', () => ({ default: ({ children }) => children }))
vi.mock('../components/PaymentForm', () => ({ default: () => <p>Payment form</p> }))
vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: key => key }) }))
vi.mock('../utils/marketplaceAttribution', () => ({ anonymousId: () => 'audit-fixture', currentAttribution: () => ({}), captureQueryAttribution: vi.fn(), trackFunnel: vi.fn() }))

const event = (id, slug, ticketId) => ({ id, slug, title: `Event ${slug}`, description: 'Synthetic route context',
  status: 'published', purchasable: true, timezone: 'Pacific/Guam', starts_at: '2027-12-20T07:00:00Z',
  venue_name: 'QA Venue', attendee_count: 0, attendees_preview: [],
  ticket_types: [{ id: ticketId, name: `${slug} admission`, price_cents: 0, on_sale: true, quantity_remaining: 10 }] })
const a = event(41, 'event-a', 111)
const b = event(42, 'event-b', 222)
const config = { payment_mode: 'simulate', buyer_terms_version: 'test-v1', service_fee_flat_cents: 0 }
function RouteProbe() {
  const location = useLocation()
  return <p data-testid="route">{location.pathname}</p>
}
function view(entry = '/events/event-a') {
  return <MemoryRouter initialEntries={[entry]}><Link to="/events/event-b">Open event B</Link>
    <Link to="/checkout/event-b" state={{ event: b, lineItems: [{ ticket_type_id: 222, quantity: 3 }] }}>Checkout B</Link><RouteProbe />
    <Routes><Route element={<Layout />}>
      <Route path="/events/:slug" element={<EventDetailPage />} />
      <Route path="/checkout/:slug" element={<CheckoutPage />} />
    </Route></Routes>
  </MemoryRouter>
}

describe('buyer event selection across the real reduced-motion layout', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '')
    window.sessionStorage.clear()
    window.localStorage.clear()
    vi.spyOn(window, 'scrollTo').mockImplementation(() => {})
    apiClient.post.mockRejectedValue({ response: { status: 503, data: { checkout_recovery_required: true, error: 'Audit stopped before allocation' } } })
  })
  afterEach(() => { vi.restoreAllMocks(); vi.unstubAllEnvs() })

  it('never submits A inventory from checkout B while the B response is delayed', async () => {
    let finishB
    apiClient.get.mockImplementation(url => url === '/config' ? Promise.resolve({ data: config })
      : url === '/events/event-a' ? Promise.resolve({ data: a })
        : new Promise(resolve => { finishB = () => resolve({ data: b }) }))
    render(view())
    const user = userEvent.setup()
    await screen.findByRole('heading', { name: a.title })
    await user.click(screen.getByRole('button', { name: 'Increase quantity' }))
    await user.click(screen.getByRole('link', { name: 'Open event B' }))
    await waitFor(() => expect(finishB).toBeDefined())
    const staleBuy = screen.queryByRole('button', { name: /eventDetail.buyTickets/ })
    if (staleBuy) await user.click(staleBuy)
    else {
      await act(async () => finishB())
      await screen.findByRole('heading', { name: b.title })
      await user.click(screen.getByRole('button', { name: 'Increase quantity' }))
      await user.click(screen.getByRole('button', { name: /eventDetail.buyTickets/ }))
    }
    expect(screen.getByTestId('route')).toHaveTextContent('/checkout/event-b')
    await user.type(await screen.findByLabelText('checkout.fullName'), 'Synthetic Buyer')
    await user.type(screen.getByLabelText('checkout.emailAddress'), 'buyer@example.invalid')
    await user.click(screen.getByRole('checkbox'))
    await user.click(screen.getByRole('button', { name: /checkout.placeOrder/ }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/orders', expect.anything()))
    await act(async () => finishB())
    expect(apiClient.post.mock.calls.find(([url]) => url === '/orders')[1]).toMatchObject({
      event_id: b.id, line_items: [{ ticket_type_id: 222, quantity: 1 }],
    })
  })

  it('keeps B and its current quantities when an earlier A response arrives last', async () => {
    let finishA
    apiClient.get.mockImplementation(url => url === '/events/event-a'
      ? new Promise(resolve => { finishA = () => resolve({ data: a }) }) : Promise.resolve({ data: b }))
    render(view())
    await waitFor(() => expect(finishA).toBeDefined())
    const user = userEvent.setup()
    await user.click(screen.getByRole('link', { name: 'Open event B' }))
    await screen.findByRole('heading', { name: b.title })
    await user.click(screen.getByRole('button', { name: 'Increase quantity' }))
    await act(async () => finishA())
    expect(screen.getByRole('heading', { name: b.title })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /eventDetail.buyTickets/ })).toBeInTheDocument()
  })

  it('refuses a mismatched navigation event snapshot before any new checkout post', async () => {
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/config' ? config : b }))
    render(view({ pathname: '/checkout/event-b', state: { event: a, lineItems: [{ ticket_type_id: 111, quantity: 1 }] } }))
    const user = userEvent.setup()
    const name = screen.queryByLabelText('checkout.fullName')
    if (name) {
      await user.type(name, 'Synthetic Buyer')
      await user.type(screen.getByLabelText('checkout.emailAddress'), 'buyer@example.invalid')
      await user.click(screen.getByRole('checkbox'))
      await user.click(await screen.findByRole('button', { name: /checkout.placeOrder/ }))
    }
    await waitFor(() => expect(screen.getByTestId('route')).toHaveTextContent('/events/event-b'))
    expect(apiClient.post).not.toHaveBeenCalled()
  })

  it('resets the old checkout form and inventory on a different checkout route', async () => {
    apiClient.get.mockResolvedValue({ data: config })
    render(view({ pathname: '/checkout/event-a', state: { event: a, lineItems: [{ ticket_type_id: 111, quantity: 2 }] } }))
    const user = userEvent.setup()
    await user.type(await screen.findByLabelText('checkout.fullName'), 'Old A Buyer')
    await user.type(screen.getByLabelText('checkout.emailAddress'), 'old-a@example.invalid')
    await user.click(screen.getByRole('link', { name: 'Checkout B' }))
    await waitFor(() => expect(screen.getByLabelText('checkout.fullName')).toHaveValue(''))
    expect(screen.getByLabelText('checkout.emailAddress')).toHaveValue('')
    await user.type(screen.getByLabelText('checkout.fullName'), 'Current B Buyer')
    await user.type(screen.getByLabelText('checkout.emailAddress'), 'current-b@example.invalid')
    await user.click(screen.getByRole('checkbox'))
    await user.click(screen.getByRole('button', { name: /checkout.placeOrder/ }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/orders', expect.anything()))
    expect(apiClient.post.mock.calls[0][1]).toMatchObject({ event_id: 42, buyer_name: 'Current B Buyer',
      line_items: [{ ticket_type_id: 222, quantity: 3 }] })
  })

  it('refuses foreign ticket inventory even when the navigation event slug matches', async () => {
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/config' ? config : b }))
    render(view({ pathname: '/checkout/event-b', state: { event: b, lineItems: [{ ticket_type_id: 111, quantity: 1 }] } }))
    await waitFor(() => expect(screen.getByTestId('route')).toHaveTextContent('/events/event-b'))
    expect(apiClient.post).not.toHaveBeenCalled()
  })

  it.each(['recover', 'unknown'])('preserves the original mismatched legacy attempt during %s recovery', async outcome => {
    const payload = { event_id: 41, checkout_key: 'c'.repeat(64), line_items: [{ ticket_type_id: 111, quantity: 1 }] }
    window.sessionStorage.setItem('hafapass:checkout-attempt:event-b', JSON.stringify({
      buyerId: null, payload, expiresAt: Date.now() + 300000,
    }))
    apiClient.get.mockResolvedValue({ data: config })
    apiClient.post.mockImplementation(url => outcome === 'unknown'
      ? Promise.reject({ response: { status: 503, data: { error: 'Original outcome unknown', checkout_recovery_required: true } } })
      : Promise.resolve({ data: url === '/orders' ? { id: 991, guest_access_token: 'original-capability' }
        : { id: 991, event: a, client_secret: 'original-secret', stripe_publishable_key: 'pk_test_original', total_cents: 0 } }))
    render(view({ pathname: '/checkout/event-b', state: { event: a, lineItems: [{ ticket_type_id: 111, quantity: 1 }] } }))
    if (outcome === 'recover') {
      await screen.findByText('Payment form')
      expect(getActiveCheckout('event-b')).toBe('991')
      expect(getCheckoutAttempt('event-b')).toBeNull()
      expect(apiClient.post).toHaveBeenNthCalledWith(1, '/orders', payload)
      expect(apiClient.post).toHaveBeenCalledTimes(2)
    } else {
      await screen.findByText('Original outcome unknown')
      expect(getCheckoutAttempt('event-b').payload).toEqual(payload)
      await userEvent.setup().click(screen.getByRole('button', { name: 'Retry saved checkout' }))
      await waitFor(() => expect(apiClient.post).toHaveBeenCalledTimes(2))
      expect(apiClient.post.mock.calls.every(([url, body]) => url === '/orders' && body.checkout_key === payload.checkout_key && body.event_id === 41)).toBe(true)
      expect(getCheckoutAttempt('event-b').payload).toEqual(payload)
      expect(screen.queryByRole('button', { name: 'Start a new checkout' })).not.toBeInTheDocument()
    }
    expect(screen.getByTestId('route')).toHaveTextContent('/checkout/event-b')
    expect(apiClient.get.mock.calls.some(([url]) => url.startsWith('/events/'))).toBe(false)
  })
})
