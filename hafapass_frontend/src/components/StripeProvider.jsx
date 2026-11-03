import { Elements } from '@stripe/react-stripe-js'
import { loadStripe } from '@stripe/stripe-js'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { RefreshCw } from 'lucide-react'
import { StripeRetryContext } from './stripeRetry'
import plusJakartaSans from '@fontsource-variable/plus-jakarta-sans/files/plus-jakarta-sans-latin-wght-normal.woff2'

// Cache loaded Stripe instances by publishable key to avoid re-loading.
// A failed load is dropped from the cache so Retry fetches Stripe.js again
// (stripe-js also resets its own script promise after a failure).
const stripeCache = {}

function getStripe(publishableKey, stripeAccount) {
  if (!publishableKey) return null
  const cacheKey = `${publishableKey}:${stripeAccount || 'platform'}`
  if (!stripeCache[cacheKey]) {
    const promise = loadStripe(publishableKey, stripeAccount ? { stripeAccount } : undefined)
      .then(stripe => {
        if (!stripe) throw new Error('Stripe.js unavailable')
        return stripe
      })
    promise.catch(() => { if (stripeCache[cacheKey] === promise) delete stripeCache[cacheKey] })
    stripeCache[cacheKey] = promise
  }
  return stripeCache[cacheKey]
}

export function PaymentLoadFailure({ onRetry }) {
  const { t } = useTranslation()
  return (
    <div role="alert" className="mb-4 rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm text-warning-800">
      <p className="font-semibold">{t('buyer.PaymentForm.paymentFormDidNotLoad')}</p>
      <p className="mt-1">{t('buyer.PaymentForm.paymentFormDidNotLoadHelp')}</p>
      {onRetry && (
        <button type="button" onClick={onRetry} className="btn-secondary mt-3 min-h-11">
          <RefreshCw aria-hidden="true" className="h-4 w-4" />
          {t('buyer.PaymentForm.retryPaymentForm')}
        </button>
      )}
    </div>
  )
}

/**
 * StripeProvider wraps children in Stripe Elements.
 * - publishableKey: from config API or order response (dynamic, not env var)
 * - clientSecret: from the PaymentIntent created by the backend
 */
export default function StripeProvider({ publishableKey, clientSecret, stripeAccount, children }) {
  const [attempt, setAttempt] = useState(0)
  const [loadFailed, setLoadFailed] = useState(false)
  // `attempt` re-reads the cache after a failed load has been evicted.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const stripePromise = useMemo(() => getStripe(publishableKey, stripeAccount), [publishableKey, stripeAccount, attempt])

  useEffect(() => {
    if (!stripePromise) return undefined
    let active = true
    stripePromise.catch(() => { if (active) setLoadFailed(true) })
    return () => { active = false }
  }, [stripePromise])

  const retry = useCallback(() => {
    setLoadFailed(false)
    setAttempt(value => value + 1)
  }, [])

  if (!stripePromise || !clientSecret) {
    return children
  }

  if (loadFailed) return <PaymentLoadFailure onRetry={retry} />

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
      // Match the app's .input fields: flat neutral border, teal focus ring.
      rules: {
        '.Input': { border: '1px solid #e2e8f0', boxShadow: 'none', padding: '12px 16px' },
        '.Input:hover': { borderColor: '#cbd5e1' },
        '.Input:focus': { borderColor: '#0d9e96', boxShadow: '0 0 0 3px rgba(13, 158, 150, 0.2)' },
        '.Input--invalid': { borderColor: '#fca5a5', boxShadow: 'none' },
        '.Label': { fontWeight: '500', color: '#334155' },
        '.Tab': { border: '1px solid #e2e8f0', boxShadow: 'none' },
        '.Tab:hover': { borderColor: '#cbd5e1' },
        '.Tab--selected': { borderColor: '#0d9e96', boxShadow: '0 0 0 1px #0d9e96' },
      },
    },
  }

  return (
    <StripeRetryContext.Provider value={retry}>
      <Elements key={attempt} stripe={stripePromise} options={options}>
        {children}
      </Elements>
    </StripeRetryContext.Provider>
  )
}
