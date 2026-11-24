import { useCallback, useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router-dom'
import { ArrowLeft, ArrowRight } from 'lucide-react'
import apiClient from '../api/client'
import { useOrganizerIdentity } from '../hooks/useOrganizerContext'
import { BackLink, PageHeader, WorkspacePage } from '../components/WorkspacePage'
import AudienceStep from '../components/email/AudienceStep'
import { ConfirmSendDialog, PreviewStep, SendDone, SendStep, WriteStep } from '../components/email/ComposeSteps'
import MailingHistory from '../components/email/MailingHistory'
import MailingSummary, { StepNav } from '../components/email/MailingSummary'
import { STEP_KEYS, audienceBreakdown, describeFilters, errorKey, scheduleLapsed } from '../components/email/emailFlowModel'
import { useCachedSelectedOrganization } from '../utils/organizerOrganizations'

const EMPTY_FILTERS = { q: '', status: '', source: '', interest: '', since: '' }

export default function AudienceMailingsPage() {
  const identity = useOrganizerIdentity()
  const [search] = useSearchParams()
  if (!identity.ready) return null
  return <AudienceMailingsSession key={`${identity.accountKey}:${identity.organizationId}:${search.get('scope')}`} identity={identity} />
}

function AudienceMailingsSession({ identity }) {
  const { t } = useTranslation()
  const [search, setSearch] = useSearchParams()
  const scope = search.get('scope') === 'platform' ? 'platform' : 'organizer'
  const view = search.get('view') === 'history' ? 'history' : 'compose'
  const organization = useCachedSelectedOrganization(identity.authContext)
  const boundConfig = { organizationId: identity.organizationId, ...(identity.authContext ? { authContext: identity.authContext } : {}) }

  const [audience, setAudience] = useState(scope === 'platform' ? 'platform' : 'buyers')
  const [filterInputs, setFilterInputs] = useState(EMPTY_FILTERS)
  const [filters, setFilters] = useState(EMPTY_FILTERS)
  useEffect(() => {
    const timer = setTimeout(() => setFilters(previous => Object.keys(EMPTY_FILTERS).every(key => previous[key] === filterInputs[key]) ? previous : filterInputs), 300)
    return () => clearTimeout(timer)
  }, [filterInputs])

  const [list, setList] = useState(null)
  const [listLoading, setListLoading] = useState(true)
  const [listError, setListError] = useState(false)
  const [history, setHistory] = useState([])
  const [historyLoading, setHistoryLoading] = useState(true)
  const [historyError, setHistoryError] = useState(false)

  const [step, setStep] = useState(0)
  const [subject, setSubject] = useState('')
  const [body, setBody] = useState('')
  const [showWriteErrors, setShowWriteErrors] = useState(false)
  const [preview, setPreview] = useState(null)
  const [previewState, setPreviewState] = useState('idle')
  const [previewErrorKey, setPreviewErrorKey] = useState(null)
  const [draftId, setDraftId] = useState(null)
  const [testedDraftId, setTestedDraftId] = useState(null)
  const [testState, setTestState] = useState('idle')
  const [testRecipient, setTestRecipient] = useState('')
  const [timing, setTiming] = useState('now')
  const [scheduledAt, setScheduledAt] = useState('')
  const [confirming, setConfirming] = useState(false)
  const [lapsed, setLapsed] = useState(false)
  const [sendResult, setSendResult] = useState(null)
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState(null)

  const listGeneration = useRef(0)
  const previewGeneration = useRef(0)
  const stepRef = useRef(null)
  const stepMounted = useRef(false)

  const loadList = useCallback(async () => {
    const request = ++listGeneration.current
    setListLoading(true); setListError(false)
    try {
      const { data } = await apiClient.get('/audience_mailings/audience', { ...boundConfig, params: { scope, audience, ...filters } })
      if (request !== listGeneration.current) return
      setList(data)
    } catch {
      if (request === listGeneration.current) setListError(true)
    } finally {
      if (request === listGeneration.current) setListLoading(false)
    }
  // boundConfig is rebuilt each render from these identity values.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scope, audience, filters, identity.organizationId, identity.authContext])
  useEffect(() => { loadList() }, [loadList])

  const loadHistory = useCallback(async () => {
    setHistoryLoading(true); setHistoryError(false)
    try {
      const { data } = await apiClient.get('/audience_mailings', { ...boundConfig, params: { scope } })
      setHistory(Array.isArray(data?.mailings) ? data.mailings : [])
    } catch { setHistoryError(true) } finally { setHistoryLoading(false) }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scope, identity.organizationId, identity.authContext])
  useEffect(() => { loadHistory() }, [loadHistory])

  function errorMessage(error) {
    const key = errorKey(error)
    if (key === 'addressMissing') return t(scope === 'platform' ? 'emailFlow.errors.addressMissingPlatform' : 'emailFlow.errors.addressMissingOrganizer')
    return t(`emailFlow.errors.${key}`)
  }

  // Any change to who or what is sent needs a fresh preview, draft and test.
  function invalidate() {
    previewGeneration.current += 1
    setPreview(null); setPreviewState('idle'); setPreviewErrorKey(null)
    setDraftId(null); setTestedDraftId(null); setTestState('idle')
  }
  const params = { scope, audience, ...filterInputs }

  const loadPreview = useCallback(async () => {
    const request = ++previewGeneration.current
    setPreviewState('loading'); setPreviewErrorKey(null)
    try {
      const { data } = await apiClient.post('/audience_mailings/preview', { scope, audience, ...filterInputs, subject, body }, boundConfig)
      if (request !== previewGeneration.current) return
      setPreview(data); setPreviewState('ready')
    } catch (error) {
      if (request !== previewGeneration.current) return
      setPreviewErrorKey(error); setPreviewState('error')
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scope, audience, filterInputs, subject, body, identity.organizationId, identity.authContext])
  useEffect(() => {
    if (step >= 2 && previewState === 'idle' && subject.trim() && body.trim()) loadPreview()
  }, [step, previewState, subject, body, loadPreview])

  useEffect(() => {
    if (!stepMounted.current) { stepMounted.current = true; return }
    stepRef.current?.focus({ preventScroll: true })
    stepRef.current?.scrollIntoView?.({ block: 'start', behavior: 'auto' })
  }, [step, sendResult])

  async function run(fn) {
    setBusy(true); setNotice(null)
    try { return await fn() } catch (error) { setNotice({ tone: 'error', text: errorMessage(error) }); return false } finally { setBusy(false) }
  }

  const written = Boolean(subject.trim() && body.trim())
  const reachable = index => index <= 1 || written
  function goTo(index) {
    if (index >= 2 && !written) { setShowWriteErrors(true); setStep(1); return }
    setStep(index)
  }

  async function sendTest() {
    setTestState('sending')
    setBusy(true); setNotice(null)
    try {
      let id = draftId
      if (!id) {
        const { data } = await apiClient.post('/audience_mailings', { ...params, subject, body }, boundConfig)
        id = data.id
        setDraftId(id)
      }
      const { data } = await apiClient.post(`/audience_mailings/${id}/test_send`, { scope }, boundConfig)
      setTestRecipient(typeof data?.recipient === 'string' ? data.recipient : '')
      setTestedDraftId(id); setTestState('sent')
      loadHistory()
    } catch (error) {
      setTestState('failed')
      if (errorKey(error) === 'addressMissing') setNotice({ tone: 'error', text: errorMessage(error) })
    } finally { setBusy(false) }
  }

  // `sendNow` is the explicit "Send now instead" answer after a scheduled time lapsed.
  async function confirmSend({ sendNow = false } = {}) {
    const id = draftId
    const count = preview?.eligible ?? audienceBreakdown(list, scope)?.eligible ?? 0
    const later = timing === 'later' && !sendNow
    // The time can pass while the dialog is open; the server would then send at once.
    if (later && scheduleLapsed(scheduledAt)) { setLapsed(true); return }
    const requestedAt = later ? new Date(scheduledAt).toISOString() : null
    const data = await run(async () => {
      const response = await apiClient.post(`/audience_mailings/${id}/send_now`, { scope, scheduled_at: requestedAt }, boundConfig)
      return response?.data || {}
    })
    setConfirming(false); setLapsed(false)
    if (data) {
      const at = Date.parse(data.scheduled_at || requestedAt || '')
      const startedNow = Number.isNaN(at) ? !later : at <= Date.now() + 5_000
      if (sendNow) setTiming('now')
      setSendResult({ startedNow, scheduledAt: data.scheduled_at || requestedAt, count })
      setDraftId(null); setTestedDraftId(null); setTestState('idle')
    } else {
      loadHistory()
    }
  }

  function startOver() {
    invalidate()
    setSubject(''); setBody(''); setShowWriteErrors(false); setTiming('now'); setScheduledAt('')
    setSendResult(null); setStep(0)
  }

  function setView(next) {
    const params = new URLSearchParams(search)
    if (next === 'history') params.set('view', 'history'); else params.delete('view')
    setSearch(params, { replace: true })
    if (next === 'history') loadHistory()
  }

  function continueDraft(row) {
    invalidate()
    const saved = { ...EMPTY_FILTERS, ...Object.fromEntries(Object.entries(row.filters || {}).map(([key, value]) => [key, String(value ?? '')])) }
    if (scope !== 'platform' && row.audience) setAudience(row.audience)
    setFilterInputs(saved); setFilters(saved)
    setSubject(row.subject || ''); setBody(row.body || '')
    setDraftId(row.id); setSendResult(null); setStep(2)
    setView('compose')
  }

  async function cancelScheduled(row) {
    const ok = await run(async () => {
      try {
        await apiClient.post(`/audience_mailings/${row.id}/cancel`, { scope }, boundConfig)
      } catch (error) {
        // The server's lock decides: 409 means sending already started.
        if (error?.response?.status !== 409) throw error
        setNotice({ tone: 'error', text: t('emailFlow.history.cancelTooLate') })
        return 'tooLate'
      }
      setNotice({ tone: 'success', text: t('emailFlow.history.cancelled') })
      return true
    })
    await loadHistory()
    return ok
  }

  async function unsubscribe(row) {
    const ok = await run(async () => {
      await apiClient.post(`/audience_mailings/suppress/${row.id}`, {}, { ...boundConfig, params: { scope } })
      setNotice({ tone: 'success', text: t('emailFlow.people.unsubscribed', { email: row.email }) })
      return true
    })
    await loadList()
    return ok
  }

  async function exportCsv() {
    await run(async () => {
      const response = await apiClient.get('/audience_mailings/audience', { ...boundConfig, params: { ...params, format: 'csv' }, responseType: 'blob' })
      const url = URL.createObjectURL(response.data)
      const link = document.createElement('a')
      link.href = url; link.download = scope === 'platform' ? 'event-alerts-subscribers.csv' : `${audience}-audience.csv`; link.click()
      URL.revokeObjectURL(url)
    })
  }

  const audienceLabel = key => t(`emailFlow.audiences.${key || (scope === 'platform' ? 'platform' : 'buyers')}`, { defaultValue: key })
  const breakdown = audienceBreakdown(list, scope)
  const eligible = preview?.eligible ?? breakdown?.eligible ?? null
  const sender = scope === 'platform' ? 'HåfaPass' : (organization?.name || t('emailFlow.preview.yourOrganization'))
  const tested = Boolean(draftId && testedDraftId === draftId)
  const blockers = [
    eligible === 0 && 'needsPeople',
    errorKey(previewErrorKey) === 'addressMissing' && 'needsAddress',
    !tested && 'needsTest',
  ].filter(Boolean)
  const nextLabels = ['emailFlow.steps.nextWrite', 'emailFlow.steps.nextPreview', 'emailFlow.steps.nextSend']

  return (
    <WorkspacePage>
      <PageHeader
        back={<BackLink to={scope === 'platform' ? '/admin' : '/dashboard'}>{scope === 'platform' ? 'Back to admin' : undefined}</BackLink>}
        title={t(scope === 'platform' ? 'emailFlow.titlePlatform' : 'emailFlow.titleOrganizer')}
        description={t(scope === 'platform' ? 'emailFlow.descriptionPlatform' : 'emailFlow.descriptionOrganizer')}
      />

      <div role="group" aria-label={t('emailFlow.tabs.label')} className="mb-6 inline-flex rounded-xl bg-neutral-100 p-1">
        {['compose', 'history'].map(key => (
          <button key={key} type="button" aria-pressed={view === key} onClick={() => setView(key)}
            className={`min-h-10 rounded-lg px-4 text-sm font-semibold transition-colors ${view === key ? 'bg-white text-neutral-950 shadow-sm' : 'text-neutral-600 hover:text-neutral-900'}`}>
            {t(`emailFlow.tabs.${key}`)}{key === 'history' && history.length > 0 ? ` (${history.length})` : ''}
          </button>
        ))}
      </div>

      {notice && (
        <p role={notice.tone === 'error' ? 'alert' : undefined} className={`mb-4 break-words rounded-xl border p-3 text-sm [overflow-wrap:anywhere] ${notice.tone === 'error' ? 'border-red-200 bg-red-50 text-red-800' : 'border-emerald-200 bg-emerald-50 text-emerald-900'}`}>{notice.text}</p>
      )}

      {view === 'history' ? (
        <MailingHistory history={history} loading={historyLoading} error={historyError} onRetry={loadHistory} audienceLabel={audienceLabel}
          busy={busy} onCancel={cancelScheduled} onContinue={continueDraft} />
      ) : sendResult ? (
        <div ref={stepRef} tabIndex={-1} className="scroll-mt-24 outline-none">
          <SendDone result={sendResult} onHistory={() => setView('history')} onAnother={startOver} />
        </div>
      ) : (
        <div className="space-y-6">
          <StepNav step={step} reachable={reachable} onStep={goTo} />
          <div className="grid min-w-0 gap-6 lg:grid-cols-[minmax(0,1fr)_18rem] lg:items-start">
            <div className="lg:order-last lg:sticky lg:top-24">
              <MailingSummary audienceLabel={audienceLabel(audience)} filterText={describeFilters(t, filterInputs, scope)} eligible={listLoading && !preview ? null : eligible}
                subject={subject} timing={timing} scheduledAt={scheduledAt} tested={tested} />
            </div>
            <div className="min-w-0 rounded-2xl border border-neutral-200 bg-white p-4 sm:p-6">
              <div ref={stepRef} tabIndex={-1} aria-label={t('emailFlow.steps.progress', { current: step + 1, total: STEP_KEYS.length, name: t(`emailFlow.steps.${STEP_KEYS[step]}`) })} className="scroll-mt-24 outline-none">
                {step === 0 && <AudienceStep scope={scope} audience={audience} busy={busy}
                  onAudience={value => { setAudience(value); invalidate() }}
                  filters={filterInputs} onFilter={(key, value) => { setFilterInputs(previous => ({ ...previous, [key]: value })); invalidate() }}
                  onClearFilters={() => { setFilterInputs(EMPTY_FILTERS); invalidate() }}
                  list={list} loading={listLoading} loadError={listError} onRetry={loadList} onExport={exportCsv} onUnsubscribe={unsubscribe} />}
                {step === 1 && <WriteStep subject={subject} body={body} busy={busy} showErrors={showWriteErrors}
                  onSubject={value => { setSubject(value); invalidate() }} onBody={value => { setBody(value); invalidate() }} />}
                {step === 2 && <PreviewStep preview={preview} previewState={previewState} previewError={previewErrorKey ? errorMessage(previewErrorKey) : ''} onRetry={() => setPreviewState('idle')}
                  subject={subject} sender={sender} testState={testState} testRecipient={testRecipient} onTest={sendTest} busy={busy}
                  canTest={previewState === 'ready'} />}
                {step === 3 && <SendStep timing={timing} onTiming={setTiming} scheduledAt={scheduledAt} onScheduledAt={setScheduledAt}
                  blockers={blockers} busy={busy} onReview={() => setConfirming(true)} />}
              </div>
              <div className="mt-6 flex flex-col-reverse gap-2 border-t border-neutral-200 pt-4 sm:flex-row sm:justify-between">
                {step > 0 ? <button type="button" className="btn-ghost gap-2" disabled={busy} onClick={() => setStep(step - 1)}><ArrowLeft aria-hidden="true" className="h-4 w-4" />{t('emailFlow.steps.back')}</button> : <span />}
                {step < 3 && <button type="button" className="btn-primary gap-2" disabled={busy}
                  onClick={() => { if (step === 1 && !written) { setShowWriteErrors(true); return } goTo(step + 1) }}>
                  {t(nextLabels[step])}<ArrowRight aria-hidden="true" className="h-4 w-4" />
                </button>}
              </div>
            </div>
          </div>
        </div>
      )}

      {confirming && <ConfirmSendDialog count={eligible || 0} audienceLabel={audienceLabel(audience)} subject={subject} sender={sender}
        timing={timing} scheduledAt={scheduledAt} lapsed={lapsed} busy={busy} onCancel={() => { setConfirming(false); setLapsed(false) }}
        onConfirm={() => confirmSend()} onSendNowInstead={() => confirmSend({ sendNow: true })} />}
    </WorkspacePage>
  )
}
