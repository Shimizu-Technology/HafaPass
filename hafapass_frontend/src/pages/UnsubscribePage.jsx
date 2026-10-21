import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import apiClient from '../api/client'
import { useTranslation } from 'react-i18next'

export default function UnsubscribePage() {
  const { t } = useTranslation()
  const { token } = useParams()
  const [state, setState] = useState({ loading: true })
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    let active = true
    apiClient.get(`/marketing/unsubscribe/${encodeURIComponent(token)}`)
      .then(({ data }) => { if (active) setState({ organization: data.organization, unsubscribed: data.unsubscribed }) })
      .catch(() => { if (active) setState({ error: t('unsubscribe.linkError') }) })
    return () => { active = false }
  }, [token, t])

  async function unsubscribe() {
    setBusy(true)
    try {
      await apiClient.post(`/marketing/unsubscribe/${encodeURIComponent(token)}`, {})
      setState(previous => ({ ...previous, unsubscribed: true, error: null }))
    } catch {
      setState(previous => ({ ...previous, error: t('unsubscribe.requestError') }))
    } finally { setBusy(false) }
  }

  return <main className="mx-auto max-w-xl px-4 py-16 sm:py-24">
    <h1 className="text-2xl font-semibold text-neutral-900">{t('unsubscribe.heading')}</h1>
    {state.error && <p role="alert" className="mt-4 text-red-700">{state.error}</p>}
    {state.loading ? <p role="status" className="mt-4">{t('unsubscribe.loading')}</p>
      : !state.organization ? null
        : state.unsubscribed ? <>
          <p role="status" className="mt-4">{t('unsubscribe.unsubscribedConfirmation', { organization: state.organization })}</p>
        </> : <>
          <p className="mt-4">{t('unsubscribe.prompt', { organization: state.organization })}</p>
          <button type="button" disabled={busy} onClick={unsubscribe} className="btn-primary mt-6">{busy ? t('unsubscribe.saving') : t('unsubscribe.action')}</button>
        </>}
  </main>
}
