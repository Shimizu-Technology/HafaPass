import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import apiClient from '../api/client'

export default function OrganizerEmailOptIn({ organizationId }) {
  const { t } = useTranslation()
  const [checked, setChecked] = useState(false)
  const [busy, setBusy] = useState(true)
  useEffect(() => {
    let active = true
    apiClient.get('/me/organizer_follows').then(({ data }) => {
      if (active) setChecked(data.organizers.find(org => org.id === organizationId)?.email_opt_in === true)
    }).catch(() => { if (active) setError(true) }).finally(() => { if (active) setBusy(false) })
    return () => { active = false }
  }, [organizationId])
  const [error, setError] = useState(false)
  return <div className="mt-4"><label className="flex gap-3 text-sm"><input type="checkbox" disabled={busy} checked={checked} onChange={async e => {
    const value = e.target.checked
    setBusy(true); setError(false)
    try { await apiClient.post('/me/organizer_follows', { organization_id: organizationId, email_opt_in: value, consent_only: true }); setChecked(value) }
    catch { setError(true) }
    finally { setBusy(false) }
  }} />{t('emailBase.followOptIn')}</label>{error && <p role="alert">{t('emailBase.error')}</p>}</div>
}
