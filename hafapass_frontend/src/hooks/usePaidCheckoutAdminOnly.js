import { useEffect, useState } from 'react'
import apiClient from '../api/client'

// Whether the server currently limits paid checkout to platform admins
// (production while payments are in Stripe test mode). Looks it up only once
// `enabled` (a paid selection exists), so free browsing makes no extra request.
export default function usePaidCheckoutAdminOnly(enabled = true) {
  const [adminOnly, setAdminOnly] = useState(false)
  useEffect(() => {
    if (!enabled) return
    let active = true
    Promise.resolve().then(() => apiClient.get('/config'))
      .then(response => { if (active) setAdminOnly(response?.data?.paid_checkout_admin_only === true) })
      .catch(() => {})
    return () => { active = false }
  }, [enabled])
  return adminOnly
}
