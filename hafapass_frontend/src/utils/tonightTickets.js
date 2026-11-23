import { eventTimeZone } from './eventTime'

// Without an end time, an event counts as under way for six hours after it starts.
const DEFAULT_EVENT_LENGTH_MS = 6 * 60 * 60 * 1000
const parse = value => {
  if (!value) return null
  const date = new Date(value)
  return Number.isNaN(date.valueOf()) ? null : date
}
const localDay = (date, timeZone) => new Intl.DateTimeFormat('en-CA', { timeZone }).format(date)

// "Tonight" is the event's own calendar day, in its own time zone, until it
// ends. An event with no usable start date is never tonight.
export function happeningToday(event, now = new Date()) {
  const start = parse(event?.starts_at)
  if (!start) return false
  const end = parse(event.ends_at) || new Date(start.valueOf() + DEFAULT_EVENT_LENGTH_MS)
  if (end <= now) return false
  const timeZone = eventTimeZone(event.timezone)
  return start <= now || localDay(start, timeZone) === localDay(now, timeZone)
}

export const isPassParent = ticket => Boolean(ticket.pass_parent || (ticket.is_pass && !ticket.pass_child))

// Only a ticket that will scan tonight is pinned: issued, admitted by the
// server, and not a multi-night pass summary. Paused or pending-refund tickets
// stay in the list with their status.
export const pinnableTonight = (ticket, event, now = new Date()) => !isPassParent(ticket)
  && ticket.status === 'issued' && ticket.admission_allowed === true && happeningToday(event, now)
