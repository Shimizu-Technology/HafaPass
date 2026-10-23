import { Link } from 'react-router-dom'
import { formatEventTime } from '../../utils/eventTime'
import { activityDateKey, activityDay, activityPath } from '../../utils/activity'

const TIME_ZONE = 'Pacific/Guam'
const text = value => value == null || value === '' ? 'empty' : typeof value === 'object' ? JSON.stringify(value) : String(value)

export function ActivityChanges({ changes }) {
  return <div>
    <h3 className="font-semibold text-neutral-900">What changed</h3>
    {changes?.length ? <dl className="mt-3 space-y-3">
      {changes.map((change, index) => <div key={`${change.field}:${index}`} className="grid min-w-0 gap-1 sm:grid-cols-[10rem_minmax(0,1fr)]">
        <dt className="min-w-0 font-medium text-neutral-700 [overflow-wrap:anywhere]">{change.field}</dt>
        <dd className="min-w-0 whitespace-pre-wrap [overflow-wrap:anywhere]"><span className="text-neutral-600">Before: {text(change.before)}</span><br /><span className="text-neutral-900">After: {text(change.after)}</span></dd>
      </div>)}
    </dl> : <p className="mt-2 text-neutral-600">No field changes recorded.</p>}
  </div>
}

export function ActivityOutcome({ outcome }) {
  return outcome && !['succeeded', 'success'].includes(outcome) ? <span className="inline-flex rounded-full bg-amber-50 px-2 py-1 text-xs font-semibold text-amber-900">{String(outcome).replaceAll('_', ' ')}</span> : null
}

export default function ActivityTimeline({ entries }) {
  const groups = new Map()
  entries.forEach(entry => {
    const day = activityDateKey(entry.occurred_at)
    if (!groups.has(day)) groups.set(day, [])
    groups.get(day).push(entry)
  })
  return <div className="space-y-6">
    {[...groups].map(([day, rows]) => <section key={day} aria-label={activityDay(rows[0].occurred_at)}>
      <h2 className="mb-2 text-sm font-semibold text-neutral-700">{activityDay(rows[0].occurred_at)}</h2>
      <ul className="divide-y divide-neutral-100 rounded-xl border border-neutral-200 bg-white">
        {rows.map(entry => <li key={entry.id} className="min-w-0 p-4 sm:px-5">
          <div className="grid min-w-0 gap-2 sm:grid-cols-[6rem_minmax(0,1fr)] sm:gap-4">
            <time dateTime={entry.occurred_at} className="text-xs text-neutral-600">{formatEventTime(entry.occurred_at, TIME_ZONE, { locale: 'en-US', timeZoneName: undefined })}</time>
            <div className="min-w-0 space-y-2 text-sm [overflow-wrap:anywhere]">
              <p className="font-medium text-neutral-900">{entry.sentence}</p>
              <p className="text-neutral-600">{entry.actor?.name || entry.actor?.email || 'System'}{entry.area && ` · ${entry.area.replaceAll('_', ' ')}`}</p>
              <div className="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1">
                {entry.event && (activityPath(entry.event.url) ? <Link className="inline-flex min-h-11 max-w-full items-center font-medium text-brand-700 underline" to={entry.event.url}>{entry.event.title}</Link> : <span>{entry.event.title}</span>)}
                <ActivityOutcome outcome={entry.outcome} />
              </div>
              <details className="min-w-0">
                <summary className="min-h-11 cursor-pointer content-center font-semibold text-brand-700">Details<span className="sr-only"> for activity {entry.id}</span></summary>
                <div className="min-w-0 rounded-lg bg-neutral-50 p-3">
                  <ActivityChanges changes={entry.changes} />
                  {activityPath(entry.target?.url) && <Link className="mt-3 inline-flex min-h-11 items-center font-medium text-brand-700 underline" to={entry.target.url}>{entry.target.label || 'View record'}</Link>}
                </div>
              </details>
            </div>
          </div>
        </li>)}
      </ul>
    </section>)}
  </div>
}
