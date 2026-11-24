import { useCallback, useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router-dom'
import apiClient from '../api/client'
import { useOrganizerIdentity } from '../hooks/useOrganizerContext'

export default function AudienceMailingsPage() {
  const identity = useOrganizerIdentity()
  const [search] = useSearchParams()
  if (!identity.ready) return null
  return <AudienceMailingsSession key={`${identity.accountKey}:${identity.organizationId}:${search.get('scope')}`} identity={identity} />
}

function AudienceMailingsSession({ identity }) {
  const { t } = useTranslation()
  const [search] = useSearchParams()
  const scope = search.get('scope') === 'platform' ? 'platform' : 'organizer'
  const [audience, setAudience] = useState(scope === 'platform' ? 'platform' : 'buyers')
  const [q, setQ] = useState('')
  const [status, setStatus] = useState('')
  const [source, setSource] = useState('')
  const [interest, setInterest] = useState('')
  const [since, setSince] = useState('')
  const [subject, setSubject] = useState('')
  const [body, setBody] = useState('')
  const [scheduledAt, setScheduledAt] = useState('')
  const [list, setList] = useState(null)
  const [history, setHistory] = useState([])
  const [preview, setPreview] = useState(null)
  const [draftId, setDraftId] = useState(null)
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState('')
  const generation = useRef(0)
  const boundConfig = { organizationId: identity.organizationId, ...(identity.authContext ? { authContext: identity.authContext } : {}) }
  const params = { scope, audience, q, status, source, interest, since }
  const load = useCallback(async () => {
    const request = ++generation.current
    try {
      const [a, h] = await Promise.all([apiClient.get('/audience_mailings/audience', { organizationId: identity.organizationId, ...(identity.authContext ? { authContext: identity.authContext } : {}), params: { scope, audience, q, status, source, interest, since } }), apiClient.get('/audience_mailings', { organizationId: identity.organizationId, ...(identity.authContext ? { authContext: identity.authContext } : {}), params: { scope } })])
      if (request !== generation.current) return
      setList(a.data); setHistory(h.data.mailings)
    } catch { if (request === generation.current) setNotice(t('emailBase.error')) }
  }, [scope, audience, q, status, source, interest, since, t, identity.organizationId, identity.authContext])
  useEffect(() => { load() }, [load])
  async function action(fn) {
    setBusy(true); setNotice('')
    try { await fn() } catch { setNotice(t('emailBase.error')) }
    finally { setBusy(false) }
  }
  function changed(setter, value) { setter(value); setPreview(null); setDraftId(null) }
  return <main className="mx-auto max-w-6xl space-y-6 px-4 py-10">
    <h1 className="text-2xl font-semibold">{t('emailBase.audiences')}</h1>
    {notice && <p role="status">{notice}</p>}
    <section className="space-y-4 rounded-xl border border-neutral-200 p-5">
      <label>{t('emailBase.audience')}<select disabled={busy} className="input" value={audience} onChange={e => changed(setAudience, e.target.value)}>{(scope === 'platform' ? ['platform'] : ['buyers', 'followers', 'waitlists']).map(a => <option key={a} value={a}>{t(`emailBase.${a}`)}</option>)}</select></label>
      <label>{t('emailBase.search')}<input disabled={busy} className="input" value={q} onChange={e => changed(setQ, e.target.value)} /></label>
      {scope === 'platform' && <div className="grid gap-3 sm:grid-cols-4">
        <label>{t('emailBase.status')}<select disabled={busy} className="input" value={status} onChange={e => changed(setStatus, e.target.value)}>{['', 'pending', 'confirmed', 'unsubscribed', 'bounced', 'complained'].map(s => <option key={s} value={s}>{s || t('emailBase.all')}</option>)}</select></label>
        <label>{t('emailBase.source')}<input disabled={busy} className="input" value={source} onChange={e => changed(setSource, e.target.value)} /></label>
        <label>{t('emailBase.interest')}<input disabled={busy} className="input" value={interest} onChange={e => changed(setInterest, e.target.value)} /></label>
        <label>{t('emailBase.since')}<input type="date" disabled={busy} className="input" value={since} onChange={e => changed(setSince, e.target.value)} /></label>
      </div>}
      <p>{t('emailBase.count', { count: list?.eligible || 0 })} · {t('emailBase.records', { count: list?.count || 0 })}</p>
      {list?.counts && <p>{Object.entries(list.counts).map(([key, count]) => `${key}: ${count}`).join(' · ')}</p>}
      {list?.growth && <details><summary>{t('emailBase.growth')}</summary><table><tbody>{Object.entries(list.growth).map(([day, count]) => <tr key={day}><th className="pr-6">{day}</th><td>{count}</td></tr>)}</tbody></table></details>}
      <button disabled={busy} className="btn-secondary" onClick={() => action(async () => {
        const response = await apiClient.get('/audience_mailings/audience', { ...boundConfig, params: { ...params, format: 'csv' }, responseType: 'blob' })
        const url = URL.createObjectURL(response.data); const a = document.createElement('a'); a.href = url; a.download = 'audience.csv'; a.click(); URL.revokeObjectURL(url)
      })}>{t('emailBase.export')}</button>
      <div className="max-h-72 overflow-auto">{list?.subscribers.map(row => <details key={row.email} className="border-b py-2"><summary>{row.email} {row.status}</summary><pre className="overflow-auto text-xs">{JSON.stringify(row.consents || [], null, 2)}</pre>{scope === 'platform' && <button disabled={busy} className="btn-secondary" onClick={() => action(async () => { await apiClient.post(`/audience_mailings/suppress/${row.id}`, {}, { ...boundConfig, params: { scope } }); await load() })}>{t('emailBase.suppress')}</button>}</details>)}</div>
    </section>
    <section className="space-y-4 rounded-xl border border-neutral-200 p-5">
      <h2 className="text-xl font-semibold">{t('emailBase.compose')}</h2>
      <label className="block">{t('emailBase.subject')}<input disabled={busy} className="input" maxLength={240} value={subject} onChange={e => changed(setSubject, e.target.value)} /></label>
      <label className="block">{t('emailBase.body')}<textarea disabled={busy} className="input min-h-40" maxLength={20000} value={body} onChange={e => changed(setBody, e.target.value)} /></label>
      <button disabled={busy || !subject || !body} className="btn-secondary" onClick={() => action(async () => {
        const { data } = await apiClient.post('/audience_mailings/preview', { ...params, subject, body }, boundConfig); setPreview(data)
      })}>{t('emailBase.preview')}</button>
      {preview && <><p>{t('emailBase.count', { count: preview.eligible })}</p><div className="flex flex-wrap gap-4 overflow-auto">{[600, 375].map(width => <iframe key={width} title={`${t('emailBase.preview')} ${width}`} sandbox="" srcDoc={preview.html} style={{ width, maxWidth: '100%', height: 520 }} className="border" />)}</div>
        <button disabled={busy} className="btn-secondary" onClick={() => action(async () => {
          let id = draftId
          if (!id) { const { data } = await apiClient.post('/audience_mailings', { ...params, subject, body }, boundConfig); id = data.id }
          await apiClient.post(`/audience_mailings/${id}/test_send`, { scope }, boundConfig); setDraftId(id); setNotice(t('emailBase.testQueued')); await load()
        })}>{t('emailBase.test')}</button>
        <label className="block">{t('emailBase.schedule')}<input type="datetime-local" disabled={busy} className="input" value={scheduledAt} onChange={e => setScheduledAt(e.target.value)} /></label>
        <p>Send a TEST to yourself before sending to the audience.</p>
        <button disabled={busy || !draftId} className="btn-primary" onClick={() => { if (!window.confirm(`Send "${subject}" to ${preview.eligible} ${audience} recipients${scheduledAt ? " at the scheduled time" : " now"}?`)) return; action(async () => { await apiClient.post(`/audience_mailings/${draftId}/send_now`, { scope, scheduled_at: scheduledAt ? new Date(scheduledAt).toISOString() : null }, boundConfig); setDraftId(null); setPreview(null); setNotice(t('emailBase.queued')); await load() }) }}>{t(scheduledAt ? 'emailBase.scheduleSend' : 'emailBase.send')}</button>
      </>}
    </section>
    <section><h2 className="text-xl font-semibold">{t('emailBase.history')}</h2>{history.map(row => <article className="border-b py-3" key={row.id}><h3>{row.subject}</h3><p>{row.status} {row.blocked_reason}{row.status === 'scheduled' && <button disabled={busy} className="btn-secondary" onClick={() => action(async () => { await apiClient.post(`/audience_mailings/${row.id}/cancel`, { scope }, boundConfig); await load() })}>Cancel scheduled send</button>} · {Object.entries(row.counts).map(([k,v]) => `${k}: ${v}`).join(' · ')} · {t('emailBase.unsubscribed')}: {row.unsubscribed}</p></article>)}</section>
  </main>
}
