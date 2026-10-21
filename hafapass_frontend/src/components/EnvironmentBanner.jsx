import { useEffect, useState } from 'react'
import apiClient from '../api/client'

const ENVIRONMENT_KEY = 'hafapass_runtime_environment'
const PAYMENT_MODE_KEY = 'hafapass_runtime_payment_mode'

const remember = (key, value) => {
  if (value) window.localStorage.setItem(key, value)
  else window.localStorage.removeItem(key)
}

// Shown on non-production servers, and on production while Stripe is in test
// mode. Never shown once payments are live.
function bannerKind(environment, paymentMode) {
  if (!environment || paymentMode === 'live') return null
  if (environment !== 'production') return 'environment'
  return paymentMode === 'test' ? 'payments' : null
}

export default function EnvironmentBanner({ offlineOnly = false }) {
  const [runtime, setRuntime] = useState(() => offlineOnly
    ? { environment: window.localStorage.getItem(ENVIRONMENT_KEY), paymentMode: window.localStorage.getItem(PAYMENT_MODE_KEY) }
    : { environment: null, paymentMode: null })
  useEffect(() => {
    if (offlineOnly) return
    let active = true
    apiClient.get('/config').then(response => {
      if (!active) return
      const environment = response.data.environment || null
      const paymentMode = response.data.payment_mode || null
      setRuntime({ environment, paymentMode })
      remember(ENVIRONMENT_KEY, environment)
      remember(PAYMENT_MODE_KEY, paymentMode)
    }).catch(() => {})
    return () => { active = false }
  }, [offlineOnly])
  const kind = bannerKind(runtime.environment, runtime.paymentMode)
  if (!kind) return null
  return <div className="border-b border-amber-200 bg-amber-50 px-4 py-2 text-center text-sm text-amber-950" role="status">
    {kind === 'payments'
      ? <><strong>Test payments.</strong> Only Stripe test cards work; no real card is charged. Tickets bought now are for testing.</>
      : <><strong>Test environment.</strong> Use test information and test payment methods. These tickets are for testing.</>}
  </div>
}
