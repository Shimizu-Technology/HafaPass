import { Elements } from '@stripe/react-stripe-js'
import { loadStripe } from '@stripe/stripe-js'
import { useMemo } from 'react'

// Cache loaded Stripe instances by publishable key to avoid re-loading
const stripeCache = {}

function getStripe(publishableKey) {
  if (!publishableKey) return null
  if (!stripeCache[publishableKey]) {
    stripeCache[publishableKey] = loadStripe(publishableKey)
  }
  return stripeCache[publishableKey]
}

/**
 * StripeProvider wraps children in Stripe Elements.
 * - publishableKey: from config API or order response (dynamic, not env var)
 * - clientSecret: from the PaymentIntent created by the backend
 */
export default function StripeProvider({ publishableKey, clientSecret, children }) {
  const stripePromise = useMemo(() => getStripe(publishableKey), [publishableKey])

  if (!stripePromise || !clientSecret) {
    return children
  }

  const options = {
    clientSecret,
    appearance: {
      theme: 'stripe',
      variables: {
        colorPrimary: '#1e3a5f',
        colorBackground: '#ffffff',
        colorText: '#1f2937',
        colorDanger: '#dc2626',
        fontFamily: 'system-ui, -apple-system, sans-serif',
        borderRadius: '8px',
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
