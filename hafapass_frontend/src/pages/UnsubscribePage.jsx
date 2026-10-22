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
      .then(({ data }) => { if (active) setState({ organization: data.organization, event: data.event, scope: data.scope, unsubscribed: data.unsubscribed }) })
      .catch(() => { if (active) setState({ error: t('unsubscribe.linkError') }) })
    return () => { active = false }
  }, [token, t])

  async function unsubscribe(scope) {
    setBusy(true)
    try {
      await apiClient.post(`/marketing/unsubscribe/${encodeURIComponent(token)}`, scope ? { scope } : {})
      setState(previous => ({ ...previous, unsubscribed: true, chosenScope: scope, error: null }))
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
          <p role="status" className="mt-4">{state.scope === 'waitlist' ? (state.chosenScope === 'organizer' ? t('unsubscribe.waitlistOrganizerConfirmation', { organization: state.organization }) : t('unsubscribe.waitlistEventConfirmation', { event: state.event })) : t('unsubscribe.unsubscribedConfirmation', { organization: state.organization })}</p>
          {state.scope === 'waitlist' && state.chosenScope !== 'organizer' && <button type="button" disabled={busy} onClick={() => unsubscribe('organizer')} className="btn-secondary mt-6">{t('unsubscribe.waitlistStopOrganizer')}</button>}
        </> : <>
          {state.scope === 'waitlist' ? <>
            <p className="mt-4">{t('unsubscribe.waitlistPrompt', { event: state.event })}</p>
            <div className="mt-6 flex flex-col gap-3">
              <button type="button" disabled={busy} onClick={() => unsubscribe('event')} className="btn-primary">{t('unsubscribe.waitlistStopEvent')}</button>
              <button type="button" disabled={busy} onClick={() => unsubscribe('organizer')} className="btn-secondary">{t('unsubscribe.waitlistStopOrganizer')}</button>
            </div>
          </> : <>
            <p className="mt-4">{t('unsubscribe.prompt', { organization: state.organization })}</p>
            <button type="button" disabled={busy} onClick={() => unsubscribe()} className="btn-primary mt-6">{busy ? t('unsubscribe.saving') : t('unsubscribe.action')}</button>
          </>}
        </>}
  </main>
}
