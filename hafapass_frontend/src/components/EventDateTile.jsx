import { DEFAULT_EVENT_TIME_ZONE, formatEventDate } from '../utils/eventTime'

export default function EventDateTile({ event }) {
  const timeZone = event.timezone || DEFAULT_EVENT_TIME_ZONE
  const date = formatEventDate(event.starts_at, timeZone, { weekday: 'long' })
  if (!date) return null
  const part = options => formatEventDate(event.starts_at, timeZone, { year: undefined, month: undefined, day: undefined, ...options })

  return (
    <time dateTime={event.starts_at} aria-label={date}
      className="flex h-24 w-20 shrink-0 flex-col items-center justify-center rounded-lg border border-brand-200 bg-brand-50 font-display text-brand-900 tabular-nums">
      <span aria-hidden="true" className="w-full border-b border-dashed border-brand-200 pb-1 text-center text-xs font-semibold">{part({ weekday: 'short' })}</span>
      <span aria-hidden="true" className="pt-1 text-3xl font-bold leading-none">{part({ day: 'numeric' })}</span>
      <span aria-hidden="true" className="mt-1 text-xs font-semibold">{part({ month: 'short' })}</span>
    </time>
  )
}
