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
      .catch(() => { if (active) setState({ error: 'This unsubscribe link could not be used.' }) })
    return () => { active = false }
  }, [token])

  async function unsubscribe() {
    setBusy(true)
    try {
      await apiClient.post(`/marketing/unsubscribe/${encodeURIComponent(token)}`, {})
      setState(previous => ({ ...previous, unsubscribed: true, error: null }))
    } catch {
      setState(previous => ({ ...previous, error: 'Could not unsubscribe. Please try again.' }))
    } finally { setBusy(false) }
  }

  return <main className="mx-auto max-w-xl px-4 py-16 sm:py-24">
    <h1 className="text-2xl font-semibold text-neutral-900">Email preferences</h1>
    {state.error && <p role="alert" className="mt-4 text-red-700">{state.error}</p>}
    {state.loading ? <p role="status" className="mt-4">Loading email preferences…</p>
      : !state.organization ? null
        : state.unsubscribed ? <>
          <p role="status" className="mt-4">{t('unsubscribe.unsubscribedConfirmation', { organization: state.organization })}</p>
        </> : <>
          <p className="mt-4">Unsubscribe from promotional emails from {state.organization}? Ticket and order updates will still arrive.</p>
          <button type="button" disabled={busy} onClick={unsubscribe} className="btn-primary mt-6">{busy ? 'Saving…' : 'Unsubscribe'}</button>
        </>}
  </main>
}
