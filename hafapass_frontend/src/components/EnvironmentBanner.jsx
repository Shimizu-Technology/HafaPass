import { useEffect, useState } from 'react'
import apiClient from '../api/client'

export default function EnvironmentBanner({ offlineOnly = false }) {
  const [environment, setEnvironment] = useState(() => offlineOnly ? window.localStorage.getItem('hafapass_runtime_environment') : null)
  useEffect(() => {
    if (offlineOnly) return
    let active = true
    apiClient.get('/config').then(response => {
      if (!active) return
      const current = response.data.environment || null
      setEnvironment(current)
      if (current) window.localStorage.setItem('hafapass_runtime_environment', current)
      else window.localStorage.removeItem('hafapass_runtime_environment')
    }).catch(() => {})
    return () => { active = false }
  }, [offlineOnly])
  if (!environment || environment === 'production') return null
  return <div className="border-b border-amber-200 bg-amber-50 px-4 py-2 text-center text-sm text-amber-950" role="status">
    <strong>Test environment.</strong> Use test information and test payment methods. These tickets are for testing.
  </div>
}
