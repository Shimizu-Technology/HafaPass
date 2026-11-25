import { useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { AlertCircle, ChevronDown, Download, Loader2, SlidersHorizontal, UserMinus, Users } from 'lucide-react'
import Dialog from '../Dialog'
import {
  ORGANIZER_AUDIENCES, PLATFORM_SOURCES, SUBSCRIBER_STATUSES, activeFilterCount, audienceBreakdown, countValues, formatCount, formatDate, formatDateTime, zeroReason,
} from './emailFlowModel'

export function AudienceCount({ list, scope, audience, loading }) {
  const { t } = useTranslation()
  const breakdown = audienceBreakdown(list, scope)
  // One polite status region announces count changes; the reasons below are static text.
  return (
    <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-4">
      <p role="status" className="flex items-center gap-2 text-lg font-semibold text-neutral-950 tabular-nums">
        {!breakdown || loading
          ? <><Loader2 aria-hidden="true" className="h-4 w-4 shrink-0 animate-spin text-neutral-500 motion-reduce:animate-none" /><span className="text-base font-medium text-neutral-600">{t('emailFlow.count.loading')}</span></>
          : <><Users aria-hidden="true" className="h-5 w-5 shrink-0 text-brand-700" />{t('emailFlow.count.willGet', countValues(breakdown.eligible))}</>}
      </p>
      {breakdown && !loading && (
        breakdown.excluded > 0 ? (
          <div className="mt-2 text-sm text-neutral-700">
            <p className="font-medium tabular-nums">{t('emailFlow.count.leftOut', countValues(breakdown.excluded))}</p>
            <ul className="mt-1 list-disc space-y-0.5 pl-5 tabular-nums">
              {breakdown.reasons.map(reason => (
                <li key={reason.key}>{reason.key === 'noConsent' ? t(`emailFlow.count.noConsent_${audience}`) : t(`emailFlow.count.${reason.key}`, countValues(reason.count))}</li>
              ))}
            </ul>
          </div>
        ) : breakdown.eligible > 0 && <p className="mt-1 text-sm text-neutral-600">{t('emailFlow.count.nobodyLeftOut')}</p>
      )}
      <p className="mt-2 text-xs text-neutral-600">{t('emailFlow.count.recheck')}</p>
    </div>
  )
}

function ZeroState({ reason, scope, audience, onClear }) {
  const { t } = useTranslation()
  if (!reason) return null
  const prefix = reason === 'filtered' ? 'filtered'
    : reason === 'emptyList' ? (scope === 'platform' ? 'emptyListPlatform' : 'emptyListOrganizer')
      : (scope === 'platform' ? 'allLeftOutPlatform' : `allLeftOut_${audience}`)
  return (
    <div className="flex items-start gap-3 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950">
      <AlertCircle aria-hidden="true" className="mt-0.5 h-5 w-5 shrink-0" />
      <div className="min-w-0">
        <p className="font-semibold">{t(`emailFlow.zero.${prefix}Title`)}</p>
        <p className="mt-1">{t(`emailFlow.zero.${prefix}Body`)}</p>
        {reason === 'filtered' && <button type="button" className="btn-secondary mt-3 !px-4 !py-2 text-sm" onClick={onClear}>{t('emailFlow.filters.clear')}</button>}
      </div>
    </div>
  )
}

function GrowthStrip({ growth }) {
  const { t } = useTranslation()
  const days = Object.entries(growth || {}).sort(([a], [b]) => a.localeCompare(b))
  if (!days.length) return null
  const total = days.reduce((sum, [, value]) => sum + (Number(value) || 0), 0)
  const max = Math.max(...days.map(([, value]) => Number(value) || 0), 1)
  return (
    <figure className="mt-4">
      <figcaption className="text-sm font-medium text-neutral-800 tabular-nums">{t('emailFlow.people.growth', countValues(total))}</figcaption>
      <div className="mt-2 flex h-10 items-end gap-px overflow-hidden" role="img" aria-label={t('emailFlow.people.growthLabel')}>
        {days.slice(-90).map(([day, value]) => (
          <span key={day} title={`${formatDate(`${day}T12:00:00`)}: ${formatCount(value)}`} className="min-w-[2px] flex-1 rounded-t-sm bg-brand-500/70" style={{ height: `${Math.max(8, (Number(value) / max) * 100)}%` }} />
        ))}
      </div>
    </figure>
  )
}

function SubscriberRow({ row, scope, busy, onUnsubscribe }) {
  const { t } = useTranslation()
  const consents = Array.isArray(row.consents) ? row.consents : []
  if (scope !== 'platform') return <li className="break-words py-2 text-sm text-neutral-800 [overflow-wrap:anywhere]">{row.email}</li>
  return (
    <li className="py-1">
      <details className="group rounded-lg">
        <summary aria-label={t('emailFlow.people.details', { email: row.email })} className="flex min-h-11 cursor-pointer list-none items-center gap-3 rounded-lg px-2 py-2 hover:bg-neutral-50 [&::-webkit-details-marker]:hidden">
          <span className="min-w-0 flex-1">
            <span className="block break-words text-sm font-medium text-neutral-900 [overflow-wrap:anywhere]">{row.email}</span>
            <span className="block break-words text-xs text-neutral-600">{row.name || t('emailFlow.people.noName')}{row.created_at ? ` · ${t('emailFlow.people.joined', { date: formatDate(row.created_at) })}` : ''}</span>
          </span>
          {row.status && <span className="shrink-0 whitespace-nowrap rounded-full bg-neutral-100 px-2 py-0.5 text-xs font-medium text-neutral-700">{t(`emailFlow.subscriberStatuses.${row.status}`, { defaultValue: row.status })}</span>}
          <ChevronDown aria-hidden="true" className="h-4 w-4 shrink-0 text-neutral-500 transition-transform group-open:rotate-180 motion-reduce:transition-none" />
        </summary>
        <div className="space-y-3 px-2 pb-3 text-sm text-neutral-700">
          <dl className="grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1">
            {row.source && <><dt className="text-neutral-500">{t('emailFlow.filters.source')}</dt><dd>{t(`emailFlow.sources.${row.source}`, { defaultValue: row.source })}</dd></>}
            {Array.isArray(row.interests) && row.interests.length > 0 && <><dt className="text-neutral-500">{t('emailFlow.filters.interest')}</dt><dd className="break-words">{row.interests.join(', ')}</dd></>}
          </dl>
          {consents.length > 0 && (
            <div>
              <p className="font-medium text-neutral-800">{t('emailFlow.people.history')}</p>
              <ol className="mt-1 space-y-1">
                {consents.map((consent, index) => (
                  <li key={`${consent.created_at}-${index}`} className="flex flex-wrap gap-x-2">
                    <span className="tabular-nums text-neutral-500">{formatDateTime(consent.created_at)}</span>
                    <span>{t(`emailFlow.consentActions.${consent.action}`, { defaultValue: t('emailFlow.consentActions.other', { action: consent.action }) })}</span>
                    {consent.version && <span className="text-neutral-500">({consent.version})</span>}
                  </li>
                ))}
              </ol>
            </div>
          )}
          {!['unsubscribed', 'bounced', 'complained'].includes(row.status) && (
            <button type="button" disabled={busy} onClick={() => onUnsubscribe(row)} className="btn-secondary gap-2 !px-4 !py-2 text-sm">
              <UserMinus aria-hidden="true" className="h-4 w-4" />{t('emailFlow.people.unsubscribe')}
            </button>
          )}
        </div>
      </details>
    </li>
  )
}

export default function AudienceStep({
  scope, audience, onAudience, filters, onFilter, onClearFilters, list, loading, loadError, onRetry, busy, onExport, onUnsubscribe,
}) {
  const { t } = useTranslation()
  const ids = useId()
  const [filtersOpen, setFiltersOpen] = useState(() => activeFilterCount(filters, scope) > 0)
  const [peopleOpen, setPeopleOpen] = useState(false)
  const [confirming, setConfirming] = useState(null)
  const filterCount = activeFilterCount(filters, scope)
  const options = scope === 'platform' ? ['platform'] : ORGANIZER_AUDIENCES
  const people = list?.subscribers || []
  const total = Number(list?.count) || 0
  const reason = loading ? null : zeroReason({ list, scope, filterCount })

  return (
    <section aria-labelledby={`${ids}-heading`} className="space-y-5">
      <h2 id={`${ids}-heading`} className="text-xl font-semibold text-neutral-950">{t('emailFlow.audiences.heading')}</h2>
      <fieldset>
        <legend className="sr-only">{t('emailBase.audience')}</legend>
        <div className={`grid gap-3 ${options.length > 1 ? 'sm:grid-cols-3' : ''}`}>
          {options.map(option => (
            <label key={option} className={`flex min-h-11 cursor-pointer items-start gap-3 rounded-xl border p-4 transition-colors has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-focus ${audience === option ? 'border-brand-600 bg-brand-50/60' : 'border-neutral-200 bg-white hover:border-neutral-300'}`}>
              <input type="radio" name={`${ids}-audience`} value={option} checked={audience === option} disabled={busy} onChange={() => onAudience(option)} className="mt-1 h-4 w-4 shrink-0" />
              <span className="min-w-0">
                <span className="block font-semibold text-neutral-900">{t(`emailFlow.audiences.${option}`)}</span>
                <span className="mt-0.5 block text-sm text-neutral-600">{t(`emailFlow.audiences.${option}Hint`)}</span>
              </span>
            </label>
          ))}
        </div>
      </fieldset>

      <div>
        <button type="button" aria-expanded={filtersOpen} aria-controls={`${ids}-filters`} onClick={() => setFiltersOpen(open => !open)} className="btn-ghost -ml-3 gap-2 !px-3 !py-2 text-sm">
          <SlidersHorizontal aria-hidden="true" className="h-4 w-4" />
          {t('emailFlow.filters.toggle')}
          {filterCount > 0 && <span className="rounded-full bg-brand-100 px-2 py-0.5 text-xs text-brand-900 tabular-nums">{t('emailFlow.filters.active', countValues(filterCount))}</span>}
          <ChevronDown aria-hidden="true" className={`h-4 w-4 transition-transform motion-reduce:transition-none ${filtersOpen ? 'rotate-180' : ''}`} />
        </button>
        <div id={`${ids}-filters`} hidden={!filtersOpen} className="mt-3 rounded-xl border border-neutral-200 bg-white p-4">
          <div className={`grid gap-4 ${scope === 'platform' ? 'sm:grid-cols-2 lg:grid-cols-3' : ''}`}>
            <label className="block text-sm font-medium text-neutral-800">{t('emailFlow.filters.search')}
              <input type="search" inputMode="email" autoComplete="off" disabled={busy} className="input mt-1" value={filters.q} onChange={event => onFilter('q', event.target.value)} />
            </label>
            {scope === 'platform' && <>
              <label className="block text-sm font-medium text-neutral-800">{t('emailFlow.filters.status')}
                <select disabled={busy} className="input mt-1" value={filters.status} onChange={event => onFilter('status', event.target.value)}>
                  <option value="">{t('emailFlow.filters.any')}</option>
                  {SUBSCRIBER_STATUSES.map(status => <option key={status} value={status}>{t(`emailFlow.subscriberStatuses.${status}`)}</option>)}
                </select>
              </label>
              <label className="block text-sm font-medium text-neutral-800">{t('emailFlow.filters.source')}
                <select disabled={busy} className="input mt-1" value={filters.source} onChange={event => onFilter('source', event.target.value)}>
                  <option value="">{t('emailFlow.filters.any')}</option>
                  {PLATFORM_SOURCES.map(source => <option key={source} value={source}>{t(`emailFlow.sources.${source}`)}</option>)}
                </select>
              </label>
              <label className="block text-sm font-medium text-neutral-800">{t('emailFlow.filters.interest')}
                <input disabled={busy} className="input mt-1" placeholder={t('emailFlow.filters.interestPlaceholder')} value={filters.interest} onChange={event => onFilter('interest', event.target.value)} />
              </label>
              <label className="block text-sm font-medium text-neutral-800">{t('emailFlow.filters.since')}
                <input type="date" disabled={busy} className="input mt-1" value={filters.since} onChange={event => onFilter('since', event.target.value)} />
              </label>
            </>}
          </div>
          {filterCount > 0 && <button type="button" disabled={busy} onClick={onClearFilters} className="btn-ghost -ml-3 mt-2 !px-3 !py-2 text-sm">{t('emailFlow.filters.clear')}</button>}
        </div>
      </div>

      {loadError ? (
        <div role="alert" className="flex flex-wrap items-center gap-3 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800">
          <AlertCircle aria-hidden="true" className="h-5 w-5 shrink-0" /><span className="min-w-0 flex-1">{t('emailFlow.errors.load')}</span>
          <button type="button" className="btn-secondary !px-4 !py-2 text-sm" onClick={onRetry}>{t('emailFlow.errors.retry')}</button>
        </div>
      ) : <AudienceCount list={list} scope={scope} audience={audience} loading={loading} />}
      <ZeroState reason={reason} scope={scope} audience={audience} onClear={onClearFilters} />

      {list && total > 0 && (
        <div className="rounded-xl border border-neutral-200 bg-white">
          <div className="flex flex-wrap items-center justify-between gap-2 p-2">
            <button type="button" aria-expanded={peopleOpen} aria-controls={`${ids}-people`} onClick={() => setPeopleOpen(open => !open)} className="btn-ghost gap-2 !px-3 !py-2 text-sm">
              {t(peopleOpen ? 'emailFlow.people.hide' : 'emailFlow.people.show')}
              <ChevronDown aria-hidden="true" className={`h-4 w-4 transition-transform motion-reduce:transition-none ${peopleOpen ? 'rotate-180' : ''}`} />
            </button>
            <button type="button" disabled={busy} onClick={onExport} className="btn-secondary gap-2 !px-4 !py-2 text-sm"><Download aria-hidden="true" className="h-4 w-4" />{t('emailFlow.people.download')}</button>
          </div>
          <div id={`${ids}-people`} hidden={!peopleOpen} className="border-t border-neutral-200 px-2 pb-2">
            {total > people.length && <p className="px-2 pt-3 text-xs text-neutral-600 tabular-nums">{t('emailFlow.people.showingFirst', { shown: formatCount(people.length), total: formatCount(total) })}</p>}
            <ul className="max-h-[28rem] divide-y divide-neutral-100 overflow-y-auto overscroll-contain px-1">
              {people.map(row => <SubscriberRow key={row.id || row.email} row={row} scope={scope} busy={busy} onUnsubscribe={setConfirming} />)}
            </ul>
            {scope === 'platform' && <div className="px-2 pb-2"><GrowthStrip growth={list.growth} /></div>}
          </div>
        </div>
      )}

      {confirming && (
        <Dialog labelledBy={`${ids}-unsubscribe-title`} onClose={() => setConfirming(null)} busy={busy} className="max-w-md">
          <h2 id={`${ids}-unsubscribe-title`} className="break-words text-lg font-semibold text-neutral-950 [overflow-wrap:anywhere]">{t('emailFlow.people.unsubscribeTitle', { email: confirming.email })}</h2>
          <p className="mt-2 text-sm text-neutral-700">{t('emailFlow.people.unsubscribeBody')}</p>
          <div className="mt-6 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
            <button type="button" className="btn-secondary" disabled={busy} onClick={() => setConfirming(null)}>{t('emailFlow.send.goBack')}</button>
            <button type="button" className="btn-danger" disabled={busy} onClick={async () => { const ok = await onUnsubscribe(confirming); if (ok !== false) setConfirming(null) }}>{t('emailFlow.people.unsubscribeConfirm')}</button>
          </div>
        </Dialog>
      )}
    </section>
  )
}
