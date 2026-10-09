import { lazy, Suspense } from 'react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import CheckoutPage from './CheckoutPage'
import apiClient from '../api/client'
import { getActiveCheckout, getOrderAccess } from '../utils/orderAccess'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('../components/SEO', () => ({ default: () => null }))
vi.mock('../components/StripeProvider', () => ({ default: ({ children }) => children }))
vi.mock('../components/PaymentForm', () => ({ default: () => <p>Payment form</p> }))
vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: key => key }) }))
vi.mock('../utils/marketplaceAttribution', () => ({ anonymousId: () => 'test-anonymous', currentAttribution: () => ({}), trackFunnel: vi.fn() }))

describe('checkout navigation', () => {
  beforeEach(() => { vi.clearAllMocks(); window.sessionStorage.clear() })

  it('keeps a completed free order on its lazy confirmation route and stores recovery access', async () => {
    const event = { id: 37, slug: 'free-event', title: 'Free Event', timezone: 'Pacific/Guam', ticket_types: [{ id: 7, name: 'Free admission', price_cents: 0 }] }
    apiClient.get.mockResolvedValue({ data: { payment_mode: 'simulate', buyer_terms_version: 'buyer-v1', service_fee_flat_cents: 0 } })
    apiClient.post.mockResolvedValue({ data: { id: 922, status: 'completed', guest_access_token: 'guest-token' } })
    let openConfirmation
    const Confirmation = lazy(() => new Promise(resolve => { openConfirmation = () => resolve({ default: () => <h1>Confirmed order 922</h1> }) }))
    render(<MemoryRouter initialEntries={[{ pathname: '/checkout/free-event', state: { event, lineItems: [{ ticket_type_id: 7, quantity: 1 }] } }]}>
      <Suspense fallback={<p>Loading confirmation</p>}><Routes>
        <Route path="/checkout/:slug" element={<CheckoutPage />} />
        <Route path="/orders/:id/confirmation" element={<Confirmation />} />
        <Route path="/events/:slug" element={<h1>Unexpected event redirect</h1>} />
      </Routes></Suspense>
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
})
