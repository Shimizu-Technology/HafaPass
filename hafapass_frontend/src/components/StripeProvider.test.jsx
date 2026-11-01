import { render, screen } from '@testing-library/react'
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
