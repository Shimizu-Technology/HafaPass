import { Elements } from '@stripe/react-stripe-js'
import { loadStripe } from '@stripe/stripe-js'
import { useMemo } from 'react'
import plusJakartaSans from '@fontsource-variable/plus-jakarta-sans/files/plus-jakarta-sans-latin-wght-normal.woff2'

// Cache loaded Stripe instances by publishable key to avoid re-loading
const stripeCache = {}

function getStripe(publishableKey, stripeAccount) {
  if (!publishableKey) return null
  const cacheKey = `${publishableKey}:${stripeAccount || 'platform'}`
  if (!stripeCache[cacheKey]) {
    stripeCache[cacheKey] = loadStripe(publishableKey, stripeAccount ? { stripeAccount } : undefined)
  }
  return stripeCache[cacheKey]
}

/**
 * StripeProvider wraps children in Stripe Elements.
 * - publishableKey: from config API or order response (dynamic, not env var)
 * - clientSecret: from the PaymentIntent created by the backend
 */
export default function StripeProvider({ publishableKey, clientSecret, stripeAccount, children }) {
  const stripePromise = useMemo(() => getStripe(publishableKey, stripeAccount), [publishableKey, stripeAccount])

  if (!stripePromise || !clientSecret) {
    return children
  }

  const options = {
    clientSecret,
    // Elements render in Stripe's iframe, so the font needs an absolute URL
    // (served with a CORS header) to match the rest of checkout.
    fonts: [{ family: 'Plus Jakarta Sans', src: `url(${new URL(plusJakartaSans, window.location.origin).href})`, weight: '200 800' }],
    appearance: {
      theme: 'stripe',
      variables: {
        colorPrimary: '#0b6563',
        colorBackground: '#ffffff',
        colorText: '#0f172a',
        colorTextSecondary: '#475569',
        colorTextPlaceholder: '#64748b',
        colorDanger: '#b91c1c',
        fontFamily: '"Plus Jakarta Sans", system-ui, -apple-system, sans-serif',
        fontSizeBase: '16px',
        borderRadius: '12px',
        spacingUnit: '4px',
      },
    },
  }

  return (
    <Elements stripe={stripePromise} options={options}>
      {children}
    </Elements>
  )
}
