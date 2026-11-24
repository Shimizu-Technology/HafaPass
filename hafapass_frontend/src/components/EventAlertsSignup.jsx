import { useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import apiClient from '../api/client'

// Self-contained: Home redesign #231 can move this band without changing signup behavior.
export default function EventAlertsSignup({ source = 'home' }) {
  const { t } = useTranslation()
  const id = useId()
  const [email, setEmail] = useState('')
  const [state, setState] = useState('idle')
  async function submit(event) {
    event.preventDefault()
    setState('busy')
    try { await apiClient.post('/platform_subscriptions', { email, source }); setState('accepted') }
    catch { setState('error') }
  }
  return <section className="my-6 rounded-xl border border-current/20 p-4 sm:p-6">
    <h2 className="text-lg font-semibold">{t('emailBase.signup')}</h2>
    <p className="my-2 text-sm">{t('emailBase.consent')}</p>
    {/* Both messages reserve their wrapped height before any response. */}
    <div className="grid">
      <p role={state === 'accepted' ? 'status' : undefined} aria-hidden={state !== 'accepted' || undefined} className={`col-start-1 row-start-1 ${state === 'accepted' ? '' : 'invisible'}`}>{t('emailBase.checkInbox')}</p>
    <form onSubmit={submit} aria-hidden={state === 'accepted' || undefined} inert={state === 'accepted' ? '' : undefined} className={`col-start-1 row-start-1 flex flex-col gap-3 sm:flex-row ${state === 'accepted' ? 'invisible' : ''}`}>
      <label className="sr-only" htmlFor={id}>{t('emailBase.alertsEmail')}</label>
      <input id={id} type="email" autoComplete="email" maxLength={254} required value={email} onChange={e => setEmail(e.target.value)} className="input text-neutral-900" />
      <button disabled={state === 'busy'} className="btn-primary shrink-0">{t('emailBase.subscribe')}</button>
    </form>
    </div>
    <p role={state === 'error' ? 'alert' : undefined} aria-hidden={state !== 'error' || undefined} className={`mt-2 text-sm ${state === 'error' ? '' : 'invisible'}`}>{t('emailBase.error')}</p>
  </section>
}
