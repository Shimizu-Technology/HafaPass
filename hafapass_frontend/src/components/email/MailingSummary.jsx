import { useTranslation } from 'react-i18next'
import { Check } from 'lucide-react'
import { STEP_KEYS, countValues, formatDateTime } from './emailFlowModel'

export function StepNav({ step, reachable, onStep }) {
  const { t } = useTranslation()
  const name = t(`emailFlow.steps.${STEP_KEYS[step]}`)
  return (
    <nav aria-label={t('emailFlow.steps.label')}>
      <p className="sr-only">{t('emailFlow.steps.progress', { current: step + 1, total: STEP_KEYS.length, name })}</p>
      <ol className="mt-2 grid grid-cols-4 gap-1.5 sm:mt-0 sm:gap-2">
        {STEP_KEYS.map((key, index) => {
          const current = index === step
          const done = index < step
          const canGo = reachable(index) && !current
          const label = t(`emailFlow.steps.${key}`)
          return (
            <li key={key} className="min-w-0">
              <button type="button" disabled={!canGo} aria-current={current ? 'step' : undefined} onClick={() => onStep(index)}
                className="group flex min-h-11 w-full min-w-0 flex-col items-stretch gap-1.5 rounded-lg text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus disabled:cursor-default">
                <span aria-hidden="true" className={`h-1.5 rounded-full transition-colors ${current || done ? 'bg-brand-600' : 'bg-neutral-200'}`} />
                <span aria-hidden="true" className={`flex min-h-6 items-center gap-1 text-xs sm:min-h-8 sm:gap-1.5 sm:text-sm ${current ? 'font-semibold text-neutral-950' : done ? 'text-brand-800 group-enabled:group-hover:underline' : 'text-neutral-500'}`}>
                  <span className={`flex h-5 w-5 shrink-0 items-center justify-center rounded-full text-[0.6875rem] font-semibold sm:h-6 sm:w-6 sm:text-xs ${current ? 'bg-brand-600 text-white' : done ? 'bg-brand-100 text-brand-800' : 'bg-neutral-100 text-neutral-600'}`}>
                    {done ? <Check className="h-3 w-3 sm:h-3.5 sm:w-3.5" /> : index + 1}
                  </span>
                  <span className="min-w-0 truncate sm:hidden">{t(`emailFlow.steps.short.${key}`)}</span>
                  <span className="hidden min-w-0 truncate sm:inline">{label}</span>
                </span>
                <span className="sr-only">{`${index + 1}. ${label}${done ? ` (${t('emailFlow.steps.done')})` : ''}`}</span>
              </button>
            </li>
          )
        })}
      </ol>
    </nav>
  )
}

export default function MailingSummary({ audienceLabel, filterText, eligible, subject, timing, scheduledAt, tested }) {
  const { t } = useTranslation()
  const rows = [
    ['to', <>
      <span className="block">{audienceLabel}</span>
      {eligible != null && <span className="block font-semibold tabular-nums text-neutral-950">{t('emailFlow.count.summary', countValues(eligible))}</span>}
      {filterText && <span className="block text-xs text-neutral-500">{t('emailFlow.summary.filtered', { filters: filterText })}</span>}
    </>],
    ['subject', subject ? <span className="line-clamp-3" title={subject}>{subject}</span> : <span className="text-neutral-500">{t('emailFlow.summary.notWritten')}</span>],
    ['when', timing !== 'later' ? t('emailFlow.send.rightAway') : scheduledAt ? formatDateTime(scheduledAt) : <span className="text-neutral-500">{t('emailFlow.send.later')}</span>],
    ['test', tested ? <span className="text-emerald-800">{t('emailFlow.summary.testSent')}</span> : <span className="text-neutral-500">{t('emailFlow.summary.testNotSent')}</span>],
  ]
  return (
    <aside aria-labelledby="email-summary-heading" className="rounded-2xl border border-neutral-200 bg-white p-4 sm:p-5">
      <h2 id="email-summary-heading" className="text-sm font-semibold uppercase tracking-wide text-neutral-600">{t('emailFlow.summary.heading')}</h2>
      <dl className="mt-3 grid grid-cols-[4.5rem_minmax(0,1fr)] gap-x-3 gap-y-2 text-sm">
        {rows.map(([key, value]) => (
          <div key={key} className="contents">
            <dt className="text-neutral-500">{t(`emailFlow.summary.${key}`)}</dt>
            <dd className="min-w-0 break-words text-neutral-800 [overflow-wrap:anywhere]">{value}</dd>
          </div>
        ))}
      </dl>
    </aside>
  )
}
