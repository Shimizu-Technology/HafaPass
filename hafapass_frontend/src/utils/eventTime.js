export const DEFAULT_EVENT_TIME_ZONE = 'Pacific/Guam'

function validDate(value) {
  if (!value) return null
  const date = new Date(value)
  return Number.isNaN(date.valueOf()) ? null : date
}

export function formatEventDate(value, timeZone = DEFAULT_EVENT_TIME_ZONE, options = {}) {
  const date = validDate(value)
  if (!date) return ''
  return date.toLocaleDateString('en-US', {
    timeZone,
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    ...options,
  })
}

export function formatEventTime(value, timeZone = DEFAULT_EVENT_TIME_ZONE, options = {}) {
  const date = validDate(value)
  if (!date) return ''
  return date.toLocaleTimeString('en-US', {
    timeZone,
    hour: 'numeric',
    minute: '2-digit',
    ...options,
  })
}

export function formatEventDateTime(value, timeZone = DEFAULT_EVENT_TIME_ZONE, options = {}) {
  const date = validDate(value)
  if (!date) return ''
  return date.toLocaleString('en-US', {
    timeZone,
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    ...options,
  })
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

export function compareLocalDateTimes(first, second) {
  return first && second ? first.localeCompare(second) : 0
}
