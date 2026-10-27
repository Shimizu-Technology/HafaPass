import { DEFAULT_EVENT_TIME_ZONE, formatEventDate } from '../utils/eventTime'

export default function EventDateTile({ event, artwork = false }) {
  const timeZone = event.timezone || DEFAULT_EVENT_TIME_ZONE
  const date = formatEventDate(event.starts_at, timeZone, { weekday: 'long' })
  if (!date) return null
  const part = options => formatEventDate(event.starts_at, timeZone, { year: undefined, month: undefined, day: undefined, ...options })

  return (
    <time dateTime={event.starts_at} aria-label={date}
      className={`flex shrink-0 flex-col items-center justify-center font-display tabular-nums ${artwork ? 'h-full w-full bg-brand-800 text-white' : 'h-24 w-20 rounded-lg border border-brand-200 bg-brand-50 text-brand-900'}`}>
      <span aria-hidden="true" className={artwork ? 'text-base font-medium' : 'w-full border-b border-dashed border-brand-200 pb-1 text-center text-xs font-semibold'}>{part({ weekday: artwork ? 'long' : 'short' })}</span>
      <span aria-hidden="true" className={artwork ? 'my-1 text-7xl font-bold leading-none tracking-tight' : 'pt-1 text-3xl font-bold leading-none'}>{part({ day: 'numeric' })}</span>
      <span aria-hidden="true" className={artwork ? 'text-base font-medium' : 'mt-1 text-xs font-semibold'}>{part({ month: artwork ? 'long' : 'short' })}</span>
    </time>
  )
}
