import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import apiClient from '../api/client'

export default function OrganizerEmailOptIn({ organizationId }) {
  const { t } = useTranslation()
  const [checked, setChecked] = useState(false)
  const [marker, setMarker] = useState(0)
  const [busy, setBusy] = useState(true)
  const [error, setError] = useState('')
  useEffect(() => {
    let active = true
    apiClient.get('/me/organizer_follows').then(({ data }) => {
      const row = data.organizers.find(org => org.id === organizationId)
      if (active) { setChecked(row?.email_opt_in === true); setMarker(row?.consent_marker ?? 0) }
    }).catch(() => { if (active) setError('emailBase.error') }).finally(() => { if (active) setBusy(false) })
    return () => { active = false }
  }, [organizationId])
  return <div className="mt-4"><label className="flex gap-3 text-sm"><input type="checkbox" disabled={busy} checked={checked} onChange={async e => {
    const value = e.target.checked
    setBusy(true); setError('')
    try {
      await apiClient.post('/me/organizer_follows', { organization_id: organizationId, email_opt_in: value, consent_only: true, consent_marker: marker })
      const { data } = await apiClient.get('/me/organizer_follows')
      const row = data.organizers.find(org => org.id === organizationId)
      setChecked(row?.email_opt_in === true); setMarker(row?.consent_marker ?? 0)
    } catch (failure) {
      if (failure.response?.status === 409) {
        try {
          const { data } = await apiClient.get('/me/organizer_follows')
          const row = data.organizers.find(org => org.id === organizationId)
          setChecked(row?.email_opt_in === true); setMarker(row?.consent_marker ?? 0)
          setError('emailBase.preferencesChanged')
        } catch { setError('emailBase.error') }
      } else setError('emailBase.error')
    } finally { setBusy(false) }
  }} />{t('emailBase.followOptIn')}</label>{error && <p role="alert">{t(error)}</p>}</div>
}
