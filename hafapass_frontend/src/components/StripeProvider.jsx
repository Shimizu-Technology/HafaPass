import { Elements } from '@stripe/react-stripe-js'
import { loadStripe } from '@stripe/stripe-js'
import { useMemo } from 'react'

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
    appearance: {
      theme: 'stripe',
      variables: {
        colorPrimary: '#0e7c7b',
        colorBackground: '#ffffff',
        colorText: '#1f2937',
        colorDanger: '#dc2626',
        fontFamily: 'Plus Jakarta Sans, system-ui, -apple-system, sans-serif',
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
