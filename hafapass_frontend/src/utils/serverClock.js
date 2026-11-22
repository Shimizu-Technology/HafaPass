import { DEFAULT_EVENT_TIME_ZONE } from './eventTime'

let serverClockOffsetMs = 0
let clockSample

export function syncServerClock(serverNow) {
  const timestamp = Date.parse(serverNow)
  if (!Number.isFinite(timestamp) || (clockSample && timestamp < getServerNow())) return
  const clientNow = Date.now()
  serverClockOffsetMs = timestamp - clientNow
  // The monotonic clock keeps elapsed time stable when the device clock changes.
  clockSample = { timestamp, clientNow, monotonicNow: performance.now() }
}

export function getServerNow() {
  return clockSample
    ? clockSample.clientNow + (performance.now() - clockSample.monotonicNow) + serverClockOffsetMs
    : Date.now()
}

function zonePart(timestamp, timeZone, timeZoneName) {
  return new Intl.DateTimeFormat('en-US', { timeZone, timeZoneName })
    .formatToParts(timestamp).find(part => part.type === 'timeZoneName')?.value
}

export function scheduleTimezoneLabel(timeZone = DEFAULT_EVENT_TIME_ZONE) {
  return timeZone === DEFAULT_EVENT_TIME_ZONE ? 'Guam time (ChST, UTC+10)' : timeZone
}

export function formatScheduleTime(value, timeZone = DEFAULT_EVENT_TIME_ZONE, { includeLocal = true } = {}) {
  const timestamp = Date.parse(value)
  if (!Number.isFinite(timestamp)) return ''
  const dateOptions = { weekday: 'short', month: 'short', day: 'numeric' }
  const timeOptions = { hour: 'numeric', minute: '2-digit' }
  // Preserve second-level cutoffs when the organizer sets one.
  if (timestamp % 60_000 !== 0) timeOptions.second = '2-digit'
  const date = zone => new Intl.DateTimeFormat('en-US', { ...dateOptions, timeZone: zone }).format(timestamp)
  const time = zone => new Intl.DateTimeFormat('en-US', { ...timeOptions, timeZone: zone }).format(timestamp)
  const zoneName = zonePart(timestamp, timeZone, 'short')
  const eventLabel = timeZone === DEFAULT_EVENT_TIME_ZONE ? 'Guam time (ChST)' : `${timeZone} time (${zoneName})`
  const label = `${date(timeZone)} at ${time(timeZone)} ${eventLabel}`
  if (!includeLocal) return label

  const localZone = Intl.DateTimeFormat().resolvedOptions().timeZone
  const canonicalEventZone = new Intl.DateTimeFormat('en-US', { timeZone }).resolvedOptions().timeZone
  if (localZone === canonicalEventZone) return label

  const localDate = date(localZone) === date(timeZone) ? '' : `${date(localZone)} at `
  return `${label} (${localDate}${time(localZone)} ${zonePart(timestamp, localZone, 'short')} your time)`
}
