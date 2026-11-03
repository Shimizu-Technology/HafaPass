import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { loadStripe } from '@stripe/stripe-js'
import { expect, it, vi } from 'vitest'
import StripeProvider from './StripeProvider'

const elements = vi.hoisted(() => ({ options: null }))
vi.mock('@stripe/stripe-js', () => ({ loadStripe: vi.fn(() => Promise.resolve({})) }))
vi.mock('@stripe/react-stripe-js', () => ({
  Elements: ({ options, children }) => { elements.options = options; return children },
}))

it('styles card fields with the checkout font and brand tokens', () => {
  render(<StripeProvider publishableKey="pk_test_123" clientSecret="pi_123_secret_456"><p>Card form</p></StripeProvider>)
  expect(screen.getByText('Card form')).toBeInTheDocument()
  const [font] = elements.options.fonts
  expect(font).toMatchObject({ family: 'Plus Jakarta Sans', weight: '200 800' })
  // Stripe loads the font inside its own iframe, so a relative path would not resolve.
  expect(font.src).toMatch(new RegExp(`^url\\(${window.location.origin}/.+plus-jakarta-sans-latin-wght-normal.*\\.woff2\\)$`))
  expect(elements.options.appearance.variables).toMatchObject({
    colorPrimary: '#0b6563', colorText: '#0f172a', colorTextSecondary: '#475569',
    colorDanger: '#b91c1c', colorTextPlaceholder: '#64748b', fontSizeBase: '16px',
  })
  expect(elements.options.appearance.variables.fontFamily).toMatch(/^"Plus Jakarta Sans"/)
})

it('renders children without Elements until a payment exists', () => {
  elements.options = null
  render(<StripeProvider publishableKey="pk_test_123"><p>Order details</p></StripeProvider>)
  expect(screen.getByText('Order details')).toBeInTheDocument()
  expect(elements.options).toBeNull()
})

it('offers a retry when Stripe.js fails to load, then loads it again', async () => {
  loadStripe.mockRejectedValueOnce(new Error('Failed to load Stripe.js'))
  render(<StripeProvider publishableKey="pk_test_retry" clientSecret="pi_9_secret_9"><p>Card form</p></StripeProvider>)
  expect(await screen.findByRole('alert')).toHaveTextContent("The card form didn't load.")
  expect(screen.queryByText('Card form')).not.toBeInTheDocument()
  await userEvent.click(screen.getByRole('button', { name: 'Try again' }))
  expect(await screen.findByText('Card form')).toBeInTheDocument()
  expect(loadStripe).toHaveBeenCalledTimes(2)
})

it('styles card inputs like the app fields', () => {
  render(<StripeProvider publishableKey="pk_test_rules" clientSecret="pi_8_secret_8"><p>Card form</p></StripeProvider>)
  expect(elements.options.appearance.rules['.Input']).toMatchObject({ boxShadow: 'none' })
  expect(elements.options.appearance.rules['.Input:focus'].borderColor).toBe('#0d9e96')
})
