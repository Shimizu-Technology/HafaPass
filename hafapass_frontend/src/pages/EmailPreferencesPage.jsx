import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import apiClient from '../api/client'

export default function EmailPreferencesPage({ confirm = false }) {
  const { token } = useParams()
  const { t } = useTranslation()
  const [data, setData] = useState(null)
  const [error, setError] = useState(false)
  const [busy, setBusy] = useState(false)
  useEffect(() => {
    if (confirm) return
    let active = true
    apiClient.get(`/email_preferences/${encodeURIComponent(token)}`).then(r => { if (active) setData(r.data) }).catch(() => { if (active) setError(true) })
    return () => { active = false }
  }, [token, confirm])
  async function save(change) {
    setBusy(true); setError(false)
    try { const response = confirm ? await apiClient.post(`/platform_subscriptions/confirm/${encodeURIComponent(token)}`) : await apiClient.patch(`/email_preferences/${encodeURIComponent(token)}`, change); setData(response.data) }
    catch { setError(true) }
    finally { setBusy(false) }
  }
  return <main className="mx-auto max-w-xl px-4 py-12">
    <h1 className="text-2xl font-semibold">{t(confirm ? 'emailBase.confirm' : 'emailBase.preferences')}</h1>
    <p className="my-4">{t('emailBase.transactional')}</p>
    {error && <p role="alert">{t('emailBase.error')}</p>}
    {confirm ? data?.confirmed ? <p role="status">{t('emailBase.confirmed')}</p> : <button disabled={busy} onClick={() => save({})} className="btn-primary">{t('emailBase.confirm')}</button> : data && <div className="space-y-5">
      <label className="flex gap-3"><input type="checkbox" disabled={busy} checked={data.platform} onChange={e => save({ platform: e.target.checked })} />{t('emailBase.signup')}</label>
      {data.organizers.map(org => <label key={org.id} className="flex gap-3"><input type="checkbox" disabled={busy} checked={org.enabled} onChange={e => save({ organizers: [{ id: org.id, enabled: e.target.checked }] })} />{org.name}</label>)}
      <button disabled={busy} onClick={() => save({ unsubscribe_all: true })} className="btn-secondary">{t('emailBase.unsubscribeAll')}</button>
    </div>}
  </main>
}
