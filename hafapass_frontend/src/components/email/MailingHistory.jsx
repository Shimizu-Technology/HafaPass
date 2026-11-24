import { useId, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { AlertCircle, ChevronRight, Inbox, Loader2, Search } from 'lucide-react'
import Dialog from '../Dialog'
import { STATE_TONES, canCancel, countValues, deliveryTotals, describeFilters, formatCount, formatDateTime, mailingState } from './emailFlowModel'

const PAGE = 20
const BLOCKED = {
  'Missing mailing address or marketing permission': 'address',
  'Invalid schedule': 'schedule',
  'Schedule expired; create and confirm a new mailing': 'expired',
}

export function StateBadge({ state }) {
  const { t } = useTranslation()
  return <span className={`inline-flex shrink-0 items-center whitespace-nowrap rounded-full px-2.5 py-0.5 text-xs font-semibold ring-1 ring-inset ${STATE_TONES[state]}`}>{t(`emailFlow.history.states.${state}`)}</span>
}

function blockedText(t, reason) {
  if (!reason) return null
  const key = BLOCKED[reason]
  return key ? t(`emailFlow.history.blocked.${key}`) : t('emailFlow.history.blocked.other', { reason })
}

// Why nothing (or not everything) reached people, from the delivery outcomes.
function outcomeText(t, state, totals) {
  if (state === 'notDelivered' && totals.recipients === 0) return t('emailFlow.history.outcome.nobody')
  const parts = [
    totals.skipped > 0 && t('emailFlow.history.outcome.skipped', countValues(totals.skipped)),
    totals.failed > 0 && t('emailFlow.history.outcome.failed', countValues(totals.failed)),
    totals.bounced > 0 && t('emailFlow.history.outcome.bounced', countValues(totals.bounced)),
  ].filter(Boolean).join(', ')
  if (state === 'notDelivered') return t('emailFlow.history.outcome.none', { reasons: parts })
  if (state === 'partial') return t('emailFlow.history.outcome.partial', { reasons: parts })
  return null
}

function whenText(t, row, state) {
  if (state === 'scheduled' || state === 'starting') return t('emailFlow.history.scheduledFor', { time: formatDateTime(row.scheduled_at) })
  // Nothing went out for a not-delivered send, so never say "Sent".
  if (state === 'notDelivered' && row.scheduled_at) return t('emailFlow.history.startedAt', { time: formatDateTime(row.scheduled_at) })
  if (['sent', 'sending', 'partial'].includes(state) && row.scheduled_at) return t('emailFlow.history.sentAt', { time: formatDateTime(row.scheduled_at) })
  return t('emailFlow.history.created', { time: formatDateTime(row.created_at) })
}

function HistoryRow({ row, audienceLabel, onOpen }) {
  const { t } = useTranslation()
  const state = mailingState(row)
  const totals = deliveryTotals(row)
  const stats = totals.recipients > 0 ? [
    t('emailFlow.history.recipients', countValues(totals.recipients)),
    t('emailFlow.history.delivered', { n: formatCount(totals.delivered) }),
    totals.bounced > 0 && t('emailFlow.history.bounced', { n: formatCount(totals.bounced) }),
    totals.notSent > 0 && t('emailFlow.history.notSent', { n: formatCount(totals.notSent) }),
    totals.unsubscribed > 0 && t('emailFlow.history.unsubscribed', { n: formatCount(totals.unsubscribed) }),
  ].filter(Boolean) : []
  const outcome = outcomeText(t, state, totals)
  return (
    <li>
      <button type="button" onClick={() => onOpen(row)} aria-label={t('emailFlow.history.open', { subject: row.subject })}
        className="flex w-full min-w-0 items-start gap-3 px-3 py-4 text-left transition-colors hover:bg-neutral-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-focus sm:px-4">
        <span className="min-w-0 flex-1">
          <span className="flex flex-wrap items-center gap-2">
            <StateBadge state={state} />
            <span className="text-xs text-neutral-600">{audienceLabel(row.audience)}</span>
          </span>
          <span className="mt-1.5 line-clamp-2 break-words font-semibold text-neutral-950 [overflow-wrap:anywhere]">{row.subject}</span>
          <span className="mt-1 block text-sm text-neutral-600">{whenText(t, row, state)}</span>
          {state === 'sending' && totals.recipients > 0 && (
            <span className="mt-2 block">
              <span className="block h-1.5 overflow-hidden rounded-full bg-neutral-200"><span className="block h-full rounded-full bg-amber-500" style={{ width: `${Math.min(100, (totals.processed / totals.recipients) * 100)}%` }} /></span>
              <span className="mt-1 block text-xs text-neutral-600 tabular-nums">
                {t('emailFlow.history.progress', { done: formatCount(totals.handedOff), total: formatCount(totals.recipients) })}
                {totals.notSent > 0 && ` · ${t('emailFlow.history.notSent', { n: formatCount(totals.notSent) })}`}
              </span>
            </span>
          )}
          {state === 'notSent' && <span className="mt-1 block text-sm text-red-800">{blockedText(t, row.blocked_reason)}</span>}
          {outcome && <span className={`mt-1 block text-sm ${state === 'notDelivered' ? 'text-red-800' : 'text-amber-900'}`}>{outcome}</span>}
          {stats.length > 0 && state !== 'sending' && <span className="mt-1 block text-sm text-neutral-700 tabular-nums">{stats.join(' · ')}</span>}
        </span>
        <ChevronRight aria-hidden="true" className="mt-1 h-5 w-5 shrink-0 text-neutral-400" />
      </button>
    </li>
  )
}

function MailingDetail({ row, audienceLabel, busy, onClose, onCancel, onContinue }) {
  const { t } = useTranslation()
  const ids = useId()
  const [confirmingCancel, setConfirmingCancel] = useState(false)
  const closeRef = useRef(null)
  const state = mailingState(row)
  const totals = deliveryTotals(row)
  const outcome = outcomeText(t, state, totals)
  const stats = [['recipients', totals.recipients], ['delivered', totals.delivered], ['waiting', totals.waiting], ['bounced', totals.bounced], ['spam', totals.spam], ['notSent', totals.notSent], ['unsubscribed', totals.unsubscribed]]
  const filterText = describeFilters(t, row.filters, row.audience === 'platform' ? 'platform' : 'organizer')
  return (
    <Dialog labelledBy={`${ids}-title`} onClose={onClose} busy={busy} className="max-w-2xl" initialFocusRef={closeRef}>
      <div className="flex flex-wrap items-center gap-2"><StateBadge state={state} /><span className="text-sm text-neutral-600">{whenText(t, row, state)}</span></div>
      <h2 id={`${ids}-title`} className="mt-2 break-words text-xl font-semibold text-neutral-950 [overflow-wrap:anywhere]">{row.subject}</h2>
      {state === 'notSent' && <p className="mt-3 flex items-start gap-2 rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-800"><AlertCircle aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" />{blockedText(t, row.blocked_reason)}</p>}
      {outcome && <p className={`mt-3 flex items-start gap-2 rounded-xl border p-3 text-sm ${state === 'notDelivered' ? 'border-red-200 bg-red-50 text-red-800' : 'border-amber-200 bg-amber-50 text-amber-950'}`}><AlertCircle aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" />{outcome}</p>}
      <dl className="mt-4 text-sm">
        <div className="flex gap-2"><dt className="text-neutral-500">{t('emailFlow.history.audience')}</dt><dd className="min-w-0 break-words font-medium text-neutral-900">{audienceLabel(row.audience)}{filterText && ` · ${filterText}`}</dd></div>
      </dl>
      {state === 'starting' && canCancel(row) && <p className="mt-3 text-sm text-neutral-700">{t('emailFlow.history.startingNote')}</p>}
      {totals.recipients > 0 && <>
        <dl className="mt-4 grid grid-cols-2 gap-2 sm:grid-cols-4">
          {stats.map(([key, value]) => (
            <div key={key} className="rounded-xl bg-neutral-50 p-3">
              <dt className="text-xs text-neutral-600">{t(`emailFlow.history.stats.${key}`)}</dt>
              <dd className="mt-0.5 text-lg font-semibold text-neutral-950 tabular-nums">{formatCount(value)}</dd>
            </div>
          ))}
        </dl>
        <p className="mt-2 text-xs text-neutral-500">{t('emailFlow.history.statsNote')}</p>
      </>}
      {row.body && <div className="mt-4">
        <h3 className="text-sm font-semibold text-neutral-800">{t('emailFlow.history.message')}</h3>
        <p className="mt-1 max-h-60 overflow-y-auto whitespace-pre-wrap break-words rounded-xl border border-neutral-200 p-3 text-sm text-neutral-800 [overflow-wrap:anywhere]">{row.body}</p>
      </div>}
      {confirmingCancel ? (
        <div role="alertdialog" aria-labelledby={`${ids}-cancel-title`} className="mt-5 rounded-xl border border-red-200 bg-red-50 p-4">
          <p id={`${ids}-cancel-title`} className="font-semibold text-red-900">{t('emailFlow.history.cancelTitle')}</p>
          <p className="mt-1 text-sm text-red-900">{t('emailFlow.history.cancelBody')}</p>
          <div className="mt-3 flex flex-col-reverse gap-2 sm:flex-row">
            <button type="button" className="btn-secondary" disabled={busy} onClick={() => setConfirmingCancel(false)}>{t('emailFlow.history.keep')}</button>
            <button type="button" className="btn-danger gap-2" disabled={busy} onClick={() => onCancel(row)}>{busy && <Loader2 aria-hidden="true" className="h-4 w-4 animate-spin motion-reduce:animate-none" />}{t('emailFlow.history.cancelConfirm')}</button>
          </div>
        </div>
      ) : (
        <div className="mt-6 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <button ref={closeRef} type="button" className="btn-secondary" disabled={busy} onClick={onClose}>{t('emailFlow.history.close')}</button>
          {canCancel(row) && <button type="button" className="btn-secondary text-red-700" disabled={busy} onClick={() => setConfirmingCancel(true)}>{t('emailFlow.history.cancel')}</button>}
          {state === 'draft' && <button type="button" className="btn-primary" disabled={busy} onClick={() => onContinue(row)}>{t('emailFlow.history.continueDraft')}</button>}
        </div>
      )}
    </Dialog>
  )
}

export default function MailingHistory({ history, loading, error, onRetry, audienceLabel, busy, onCancel, onContinue }) {
  const { t } = useTranslation()
  const [query, setQuery] = useState('')
  const [shown, setShown] = useState(PAGE)
  const [openId, setOpenId] = useState(null)
  const matches = useMemo(() => {
    const q = query.trim().toLowerCase()
    return q ? history.filter(row => String(row.subject || '').toLowerCase().includes(q)) : history
  }, [history, query])
  const open = history.find(row => row.id === openId)
  const visible = matches.slice(0, shown)
  const remaining = Math.min(PAGE, matches.length - visible.length)

  return (
    <section aria-labelledby="email-history-heading" className="space-y-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <h2 id="email-history-heading" className="text-xl font-semibold text-neutral-950">{t('emailFlow.history.heading')}</h2>
        {history.length > 0 && (
          <label className="relative block sm:w-72">
            <span className="sr-only">{t('emailFlow.history.search')}</span>
            <Search aria-hidden="true" className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-neutral-500" />
            <input type="search" className="input !pl-9" placeholder={t('emailFlow.history.search')} value={query} onChange={event => { setQuery(event.target.value); setShown(PAGE) }} />
          </label>
        )}
      </div>
      {error && (
        <div role="alert" className="flex flex-wrap items-center gap-3 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800">
          <AlertCircle aria-hidden="true" className="h-5 w-5 shrink-0" /><span className="min-w-0 flex-1">{t('emailFlow.errors.load')}</span>
          <button type="button" className="btn-secondary !px-4 !py-2 text-sm" onClick={onRetry}>{t('emailFlow.errors.retry')}</button>
        </div>
      )}
      {loading && !history.length && <p role="status" className="flex items-center gap-2 text-sm text-neutral-600"><Loader2 aria-hidden="true" className="h-4 w-4 animate-spin motion-reduce:animate-none" />{t('emailFlow.history.loading')}</p>}
      {!loading && !error && history.length === 0 && (
        <div className="rounded-2xl border border-dashed border-neutral-300 bg-white p-8 text-center">
          <Inbox aria-hidden="true" className="mx-auto h-8 w-8 text-neutral-400" />
          <p className="mt-2 font-semibold text-neutral-900">{t('emailFlow.history.emptyTitle')}</p>
          <p className="mt-1 text-sm text-neutral-600">{t('emailFlow.history.emptyBody')}</p>
        </div>
      )}
      {history.length > 0 && matches.length === 0 && <p className="text-sm text-neutral-600">{t('emailFlow.history.noMatches')}</p>}
      {visible.length > 0 && (
        <ul className="divide-y divide-neutral-200 overflow-hidden rounded-2xl border border-neutral-200 bg-white">
          {visible.map(row => <HistoryRow key={row.id} row={row} audienceLabel={audienceLabel} onOpen={item => setOpenId(item.id)} />)}
        </ul>
      )}
      {matches.length > PAGE && (
        <div className="flex flex-col items-center gap-2 text-sm text-neutral-600 sm:flex-row sm:justify-between">
          <span className="tabular-nums">{t('emailFlow.history.showing', { shown: formatCount(visible.length), total: formatCount(matches.length) })}</span>
          {remaining > 0 && <button type="button" className="btn-secondary !px-4 !py-2 text-sm" onClick={() => setShown(count => count + PAGE)}>{t('emailFlow.history.showMore', countValues(remaining))}</button>}
        </div>
      )}
      {history.length >= 100 && <p className="text-xs text-neutral-500">{t('emailFlow.history.latestOnly')}</p>}
      {open && <MailingDetail row={open} audienceLabel={audienceLabel} busy={busy} onClose={() => setOpenId(null)}
        onCancel={async row => { if (await onCancel(row) !== false) setOpenId(null) }}
        onContinue={row => { setOpenId(null); onContinue(row) }} />}
    </section>
  )
}
