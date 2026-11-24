import { useEffect, useId, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { AlertCircle, CalendarClock, CheckCircle2, Loader2, Monitor, Send, Smartphone } from 'lucide-react'
import Dialog from '../Dialog'
import { BODY_MAX, SUBJECT_MAX, countValues, formatCount, formatDateTime, localZoneName, scheduleLapsed } from './emailFlowModel'

// Platform mail comes from HåfaPass itself; organizer mail is "Name via HåfaPass".
const fromText = (t, sender) => (sender === 'HåfaPass' ? sender : t('emailFlow.preview.fromValue', { sender }))

export function WriteStep({ subject, body, onSubject, onBody, busy, showErrors }) {
  const { t } = useTranslation()
  const ids = useId()
  const subjectMissing = showErrors && !subject.trim()
  const bodyMissing = showErrors && !body.trim()
  return (
    <section aria-labelledby={`${ids}-heading`} className="space-y-5">
      <h2 id={`${ids}-heading`} className="text-xl font-semibold text-neutral-950">{t('emailFlow.write.heading')}</h2>
      <div>
        <label htmlFor={`${ids}-subject`} className="block text-sm font-medium text-neutral-800">{t('emailBase.subject')}</label>
        <p id={`${ids}-subject-hint`} className="text-sm text-neutral-600">{t('emailFlow.write.subjectHint')}</p>
        <input id={`${ids}-subject`} disabled={busy} className={`input mt-2 ${subjectMissing ? 'input-error' : ''}`} maxLength={SUBJECT_MAX} value={subject}
          aria-invalid={subjectMissing || undefined} aria-describedby={`${ids}-subject-hint ${ids}-subject-count${subjectMissing ? ` ${ids}-subject-error` : ''}`}
          onChange={event => onSubject(event.target.value.replace(/[\r\n]+/g, ' '))} />
        <div className="mt-1 flex justify-between gap-3 text-xs">
          <span id={`${ids}-subject-error`} className="text-red-700">{subjectMissing ? t('emailFlow.write.subjectMissing') : ''}</span>
          <span id={`${ids}-subject-count`} className="shrink-0 text-neutral-500 tabular-nums">{t('emailFlow.write.chars', { used: formatCount(subject.length), max: formatCount(SUBJECT_MAX) })}</span>
        </div>
      </div>
      <div>
        <label htmlFor={`${ids}-body`} className="block text-sm font-medium text-neutral-800">{t('emailBase.body')}</label>
        <p id={`${ids}-body-hint`} className="text-sm text-neutral-600">{t('emailFlow.write.bodyHint')}</p>
        <textarea id={`${ids}-body`} disabled={busy} className={`input mt-2 min-h-56 resize-y ${bodyMissing ? 'input-error' : ''}`} maxLength={BODY_MAX} value={body}
          aria-invalid={bodyMissing || undefined} aria-describedby={`${ids}-body-hint ${ids}-body-count${bodyMissing ? ` ${ids}-body-error` : ''}`}
          onChange={event => onBody(event.target.value)} />
        <div className="mt-1 flex justify-between gap-3 text-xs">
          <span id={`${ids}-body-error`} className="text-red-700">{bodyMissing ? t('emailFlow.write.bodyMissing') : ''}</span>
          <span id={`${ids}-body-count`} className="shrink-0 text-neutral-500 tabular-nums">{t('emailFlow.write.chars', { used: formatCount(body.length), max: formatCount(BODY_MAX) })}</span>
        </div>
      </div>
    </section>
  )
}

// Real email widths: desktop clients render about 600px, phones about 375px.
const FRAME = { desktop: { width: 600, height: 576 }, phone: { width: 375, height: 667 } }

// Width available to the preview frame, so a frame wider than the screen can be scaled to fit.
function useAvailableWidth(ref) {
  const [width, setWidth] = useState(0)
  useEffect(() => {
    const node = ref.current
    if (!node) return undefined
    const update = () => setWidth(node.clientWidth)
    update()
    if (typeof ResizeObserver !== 'function') return undefined
    const observer = new ResizeObserver(update)
    observer.observe(node)
    return () => observer.disconnect()
  }, [ref])
  return width
}

export function PreviewStep({ preview, previewState, previewError, onRetry, subject, sender, testState, testRecipient, onTest, busy, canTest }) {
  const { t } = useTranslation()
  const ids = useId()
  const [view, setView] = useState('desktop')
  const views = [['desktop', Monitor], ['phone', Smartphone]]
  const frameBox = useRef(null)
  const available = useAvailableWidth(frameBox)
  const { width, height } = FRAME[view]
  // Render at the real width and shrink to fit; never stretch above 100%.
  const scale = available > 0 ? Math.min(1, available / width) : 1
  return (
    <section aria-labelledby={`${ids}-heading`} className="space-y-5">
      <h2 id={`${ids}-heading`} className="text-xl font-semibold text-neutral-950">{t('emailFlow.preview.heading')}</h2>
      <div className="rounded-xl border border-neutral-200 bg-white">
        <div className="flex flex-col gap-3 border-b border-neutral-200 p-3 sm:flex-row sm:items-center sm:justify-between">
          <dl className="w-full min-w-0 text-sm sm:flex-1">
            <div className="flex gap-2"><dt className="w-16 shrink-0 text-neutral-500">{t('emailFlow.preview.from')}</dt><dd className="min-w-0 break-words font-medium text-neutral-900 [overflow-wrap:anywhere]">{fromText(t, sender)}</dd></div>
            <div className="flex gap-2"><dt className="w-16 shrink-0 text-neutral-500">{t('emailBase.subject')}</dt><dd className="min-w-0 break-words font-medium text-neutral-900 [overflow-wrap:anywhere]">{subject}</dd></div>
          </dl>
          <div role="group" aria-label={t('emailFlow.preview.viewLabel')} className="inline-flex shrink-0 rounded-xl bg-neutral-100 p-1">
            {views.map(([key, Icon]) => (
              <button key={key} type="button" aria-pressed={view === key} onClick={() => setView(key)}
                className={`inline-flex min-h-10 items-center gap-1.5 rounded-lg px-3 text-sm font-medium transition-colors ${view === key ? 'bg-white text-neutral-950 shadow-sm' : 'text-neutral-600 hover:text-neutral-900'}`}>
                <Icon aria-hidden="true" className="h-4 w-4" />{t(`emailFlow.preview.${key}`)}
              </button>
            ))}
          </div>
        </div>
        <div className="bg-neutral-100 p-3 sm:p-6">
          <div ref={frameBox} className="flex min-h-[24rem] w-full justify-center">
            {previewState === 'loading' && <p role="status" className="flex items-center gap-2 self-center text-sm text-neutral-600"><Loader2 aria-hidden="true" className="h-4 w-4 animate-spin motion-reduce:animate-none" />{t('emailFlow.preview.loading')}</p>}
            {previewState === 'error' && (
              <div role="alert" className="max-w-md self-center rounded-xl border border-red-200 bg-white p-4 text-sm text-red-800">
                <p className="flex items-start gap-2"><AlertCircle aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" />{previewError}</p>
                <button type="button" className="btn-secondary mt-3 !px-4 !py-2 text-sm" onClick={onRetry}>{t('emailFlow.preview.retry')}</button>
              </div>
            )}
            {previewState === 'ready' && preview && (
              <div data-testid="email-preview-frame" data-width={width} style={{ width: width * scale, height: height * scale }} className="shrink-0 overflow-hidden rounded-lg border border-neutral-200 bg-white shadow-sm">
                <iframe key={view} title={t('emailFlow.preview.frameTitle', { view: t(`emailFlow.preview.${view}`) })} sandbox="" srcDoc={preview.html}
                  style={{ width, height, transform: scale < 1 ? `scale(${scale})` : undefined, transformOrigin: 'top left' }} className="block border-0" />
              </div>
            )}
          </div>
          {previewState === 'ready' && preview && (
            <p className="mt-2 text-center text-xs text-neutral-500 tabular-nums">
              {t(scale < 1 ? 'emailFlow.preview.sizeScaled' : 'emailFlow.preview.size', { width, percent: Math.round(scale * 100) })}
            </p>
          )}
        </div>
      </div>

      <div className="rounded-xl border border-neutral-200 bg-white p-4">
        <h3 className="font-semibold text-neutral-950">{t('emailFlow.preview.testHeading')}</h3>
        <p className="mt-1 text-sm text-neutral-600">{t('emailFlow.preview.testBody')}</p>
        <div className="mt-3 flex flex-wrap items-center gap-3">
          <button type="button" disabled={busy || !canTest} onClick={onTest} className="btn-secondary gap-2">
            {testState === 'sending' ? <Loader2 aria-hidden="true" className="h-4 w-4 animate-spin motion-reduce:animate-none" /> : <Send aria-hidden="true" className="h-4 w-4" />}
            {t(testState === 'sending' ? 'emailFlow.preview.testSending' : testState === 'sent' ? 'emailFlow.preview.testAgain' : 'emailFlow.preview.testButton')}
          </button>
        </div>
        <div aria-live="polite" className="mt-3 text-sm">
          {testState === 'sent' && <p className="flex items-start gap-2 break-words text-emerald-800 [overflow-wrap:anywhere]"><CheckCircle2 aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" />{testRecipient ? t('emailFlow.preview.testQueued', { email: testRecipient }) : t('emailFlow.preview.testQueuedNoEmail')}</p>}
          {testState === 'failed' && <p className="flex items-start gap-2 text-red-700"><AlertCircle aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" />{t('emailFlow.preview.testFailed')}</p>}
        </div>
        <p className="mt-2 text-xs text-neutral-500">{t('emailFlow.preview.editsNeedTest')}</p>
      </div>
    </section>
  )
}

export function SendStep({ timing, onTiming, scheduledAt, onScheduledAt, blockers, onReview, busy }) {
  const { t } = useTranslation()
  const ids = useId()
  const zone = localZoneName()
  const scheduleInvalid = timing === 'later' && (!scheduledAt || scheduleLapsed(scheduledAt))
  return (
    <section aria-labelledby={`${ids}-heading`} className="space-y-5">
      <h2 id={`${ids}-heading`} className="text-xl font-semibold text-neutral-950">{t('emailFlow.send.heading')}</h2>
      <fieldset className="grid gap-3 sm:grid-cols-2">
        <legend className="sr-only">{t('emailFlow.send.heading')}</legend>
        {[['now', Send], ['later', CalendarClock]].map(([key, Icon]) => (
          <label key={key} className={`flex min-h-11 cursor-pointer items-start gap-3 rounded-xl border p-4 has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-focus ${timing === key ? 'border-brand-600 bg-brand-50/60' : 'border-neutral-200 bg-white hover:border-neutral-300'}`}>
            <input type="radio" name={`${ids}-timing`} value={key} checked={timing === key} disabled={busy} onChange={() => onTiming(key)} className="mt-1 h-4 w-4 shrink-0" />
            <span className="min-w-0">
              <span className="flex items-center gap-2 font-semibold text-neutral-900"><Icon aria-hidden="true" className="h-4 w-4 text-neutral-500" />{t(`emailFlow.send.${key}`)}</span>
              <span className="mt-0.5 block text-sm text-neutral-600">{t(`emailFlow.send.${key}Hint`)}</span>
            </span>
          </label>
        ))}
      </fieldset>
      {timing === 'later' && (
        <div>
          <label className="block text-sm font-medium text-neutral-800">{zone ? t('emailFlow.send.when', { zone }) : t('emailFlow.send.whenNoZone')}
            <input type="datetime-local" disabled={busy} className={`input mt-1 sm:max-w-xs ${scheduledAt && scheduleInvalid ? 'input-error' : ''}`} value={scheduledAt} onChange={event => onScheduledAt(event.target.value)} aria-describedby={`${ids}-when-hint`} />
          </label>
          <p id={`${ids}-when-hint`} className={`mt-1 text-xs ${scheduledAt && scheduleInvalid ? 'text-red-700' : 'text-neutral-500'}`}>{t('emailFlow.send.futureOnly')}</p>
        </div>
      )}
      {blockers.length > 0 && (
        <ul className="space-y-1 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950">
          {blockers.map(key => <li key={key} className="flex items-start gap-2"><AlertCircle aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" />{t(`emailFlow.send.${key}`)}</li>)}
        </ul>
      )}
      <button type="button" className="btn-primary w-full gap-2 sm:w-auto" disabled={busy || blockers.length > 0 || scheduleInvalid} onClick={onReview}>
        <Send aria-hidden="true" className="h-4 w-4" />{t('emailFlow.send.review')}
      </button>
    </section>
  )
}

// Ignore "Send now instead" this soon after the choice appears, so a click or held
// key meant for "Schedule" can never carry over into an immediate send.
export const FRESH_ACTIVATION_MS = 500

// The picked time passed (or is under a minute away) while confirming. A separate
// component, so React mounts new buttons instead of reusing the focused Schedule
// button, and focus starts on the safe choice.
function LapsedScheduleDialog({ count, scheduledAt, busy, onCancel, onSendNow }) {
  const { t } = useTranslation()
  const ids = useId()
  const pickRef = useRef(null)
  const shownAt = useRef(0)
  useEffect(() => { shownAt.current = performance.now() }, [])
  const past = !(Date.parse(scheduledAt) > Date.now())
  const sendNow = () => {
    if (performance.now() - shownAt.current < FRESH_ACTIVATION_MS) return
    onSendNow()
  }
  return (
    <Dialog labelledBy={`${ids}-title`} onClose={onCancel} busy={busy} className="max-w-lg" initialFocusRef={pickRef}>
      <h2 id={`${ids}-title`} className="text-xl font-semibold text-neutral-950">{t(past ? 'emailFlow.send.lapsedTitlePast' : 'emailFlow.send.lapsedTitleSoon')}</h2>
      <p className="mt-2 text-sm text-neutral-700">{t('emailFlow.send.lapsedBody', { time: formatDateTime(scheduledAt) })}</p>
      <p className="mt-2 text-sm text-neutral-700 tabular-nums">{t('emailFlow.send.estimate', countValues(count))}</p>
      <div className="mt-6 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
        <button type="button" className="btn-primary gap-2" disabled={busy} onClick={sendNow} onKeyDown={event => { if (event.repeat) event.preventDefault() }}>
          {busy && <Loader2 aria-hidden="true" className="h-4 w-4 animate-spin motion-reduce:animate-none" />}
          {busy ? t('emailFlow.send.sending') : t('emailFlow.send.sendNowInstead')}
        </button>
        <button ref={pickRef} type="button" className="btn-secondary" disabled={busy} onClick={onCancel}>{t('emailFlow.send.pickNewTime')}</button>
      </div>
    </Dialog>
  )
}

export function ConfirmSendDialog({ count, audienceLabel, subject, sender, timing, scheduledAt, lapsed, busy, onCancel, onConfirm, onSendNowInstead }) {
  const { t } = useTranslation()
  const ids = useId()
  const cancelRef = useRef(null)
  const later = timing === 'later'
  if (lapsed) return <LapsedScheduleDialog count={count} scheduledAt={scheduledAt} busy={busy} onCancel={onCancel} onSendNow={onSendNowInstead} />
  return (
    <Dialog labelledBy={`${ids}-title`} onClose={onCancel} busy={busy} className="max-w-lg" initialFocusRef={cancelRef}>
      <h2 id={`${ids}-title`} className="text-xl font-semibold text-neutral-950 tabular-nums">{t(later ? 'emailFlow.send.confirmLaterTitle' : 'emailFlow.send.confirmNowTitle', countValues(count))}</h2>
      <dl className="mt-4 divide-y divide-neutral-100 rounded-xl border border-neutral-200 text-sm">
        {[
          ['to', <>{audienceLabel}<span className="block font-normal text-neutral-600 tabular-nums">{t('emailFlow.send.estimate', countValues(count))}</span></>],
          ['subject', subject],
          ['when', later ? formatDateTime(scheduledAt) : t('emailFlow.send.rightAway')],
          ['from', fromText(t, sender)],
        ].map(([key, value]) => (
          <div key={key} className="grid grid-cols-[5rem_minmax(0,1fr)] gap-3 p-3">
            <dt className="text-neutral-500">{key === 'from' ? t('emailFlow.preview.from') : t(`emailFlow.summary.${key}`)}</dt>
            <dd className="break-words font-medium text-neutral-900 [overflow-wrap:anywhere]">{value}</dd>
          </div>
        ))}
      </dl>
      <p className="mt-4 text-sm text-neutral-700">{t(later ? 'emailFlow.send.confirmLaterWarning' : 'emailFlow.send.confirmNowWarning')}</p>
      <div className="mt-6 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
        <button ref={cancelRef} type="button" className="btn-secondary" disabled={busy} onClick={onCancel}>{t('emailFlow.send.goBack')}</button>
        <button type="button" className="btn-primary gap-2" disabled={busy} onClick={onConfirm}>
          {busy && <Loader2 aria-hidden="true" className="h-4 w-4 animate-spin motion-reduce:animate-none" />}
          {busy ? t('emailFlow.send.sending') : t(later ? 'emailFlow.send.confirmLater' : 'emailFlow.send.confirmNow')}
        </button>
      </div>
    </Dialog>
  )
}

export function SendDone({ result, onHistory, onAnother }) {
  const { t } = useTranslation()
  // Decided by the server's answer, not by what was picked: a lapsed time sends right away.
  const later = !result.startedNow
  return (
    <section className="rounded-2xl border border-emerald-200 bg-emerald-50 p-6 text-emerald-950" aria-labelledby="email-send-done">
      <CheckCircle2 aria-hidden="true" className="h-8 w-8 text-emerald-700" />
      <h2 id="email-send-done" tabIndex={-1} className="mt-3 text-xl font-semibold">{t(later ? 'emailFlow.send.doneLaterTitle' : 'emailFlow.send.doneNowTitle')}</h2>
      <p className="mt-1 tabular-nums">{later ? t('emailFlow.send.doneLaterBody', { time: formatDateTime(result.scheduledAt) }) : t('emailFlow.send.doneNowBody', countValues(result.count))}</p>
      <div className="mt-5 flex flex-col gap-2 sm:flex-row">
        <button type="button" className="btn-primary" onClick={onHistory}>{t('emailFlow.send.viewHistory')}</button>
        <button type="button" className="btn-secondary" onClick={onAnother}>{t('emailFlow.send.another')}</button>
      </div>
    </section>
  )
}
