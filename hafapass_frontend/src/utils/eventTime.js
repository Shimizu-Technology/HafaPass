import { activeIntlLocale } from './locale'

// Times always show in the event's own time zone; the language only changes
// the wording and order (e.g. "Oct 21, 2026" or "2026年10月21日").
export const DEFAULT_EVENT_TIME_ZONE = 'Pacific/Guam'

function validDate(value) {
  if (!value) return null
  const date = new Date(value)
  return Number.isNaN(date.valueOf()) ? null : date
}

export function formatEventDate(value, timeZone = DEFAULT_EVENT_TIME_ZONE, options = {}) {
  const date = validDate(value)
  if (!date) return ''
  return date.toLocaleDateString(activeIntlLocale(), {
    timeZone,
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    ...options,
  })
}

function formatZoned(value, timeZone, options) {
  const date = validDate(value)
  if (!date) return ''
  const { locale = activeIntlLocale(), ...formatOptions } = options
  return new Intl.DateTimeFormat(locale, { ...formatOptions, timeZone, timeZoneName: 'short' })
    .formatToParts(date)
    .map(part => part.type === 'timeZoneName' && timeZone === DEFAULT_EVENT_TIME_ZONE ? 'Guam time' : part.value)
    .join('').replaceAll('\u202f', ' ')
}

export function formatEventTime(value, timeZone = DEFAULT_EVENT_TIME_ZONE, options = {}) {
  return formatZoned(value, timeZone, { hour: 'numeric', minute: '2-digit', ...options })
}

export function formatEventDateTime(value, timeZone = DEFAULT_EVENT_TIME_ZONE, options = {}) {
  return formatZoned(value, timeZone, {
    month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit', ...options,
  })
}

// Finance and platform operations use Guam time, regardless of browser locale.
export function formatPlatformDateTime(value) {
  return formatEventDateTime(value, DEFAULT_EVENT_TIME_ZONE, { locale: 'en-US' })
}

export function formatEventTimeRange(start, end, timeZone = DEFAULT_EVENT_TIME_ZONE) {
  const startTime = formatEventTime(start, timeZone)
  if (!startTime || !validDate(end)) return startTime
  const sameLocalDay = formatEventDate(start, timeZone) === formatEventDate(end, timeZone)
  const endLabel = sameLocalDay ? formatEventTime(end, timeZone) : formatEventDateTime(end, timeZone)
  return `${startTime} – ${endLabel}`
}

export function toEventLocalInput(value, timeZone = DEFAULT_EVENT_TIME_ZONE) {
  const date = validDate(value)
  if (!date) return ''
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(date)
  const part = (type) => parts.find(item => item.type === type)?.value
  return `${part('year')}-${part('month')}-${part('day')}T${part('hour')}:${part('minute')}`
}

export function fromEventLocalInput(value, timeZone = DEFAULT_EVENT_TIME_ZONE) {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(value || '')) return null
  const requested = Date.parse(`${value}:00Z`)
  if (Number.isNaN(requested)) return null
  let instant = requested
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const actual = Date.parse(`${toEventLocalInput(new Date(instant), timeZone)}:00Z`)
    instant += requested - actual
  }
  const result = new Date(instant)
  return toEventLocalInput(result, timeZone) === value ? result : null
}

export function compareLocalDateTimes(first, second) {
  return first && second ? first.localeCompare(second) : 0
}
