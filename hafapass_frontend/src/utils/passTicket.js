import { DEFAULT_EVENT_TIME_ZONE } from './eventTime'

function localDateKey(value, timeZone = DEFAULT_EVENT_TIME_ZONE) {
  if (!value) return null
  const date = value instanceof Date ? value : new Date(value)
  if (Number.isNaN(date.valueOf())) return null
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: timeZone || DEFAULT_EVENT_TIME_ZONE,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(date)
  const part = type => parts.find(item => item.type === type)?.value
  return `${part('year')}-${part('month')}-${part('day')}`
}

export function sortedChildTickets(childTickets = []) {
  return [...childTickets].sort((a, b) => {
    const aTime = a.event?.starts_at ? new Date(a.event.starts_at).getTime() : 0
    const bTime = b.event?.starts_at ? new Date(b.event.starts_at).getTime() : 0
    if (aTime !== bTime) return aTime - bTime
    return (a.id || 0) - (b.id || 0)
  })
}

export function getChildNightStatus(child, now = new Date()) {
  const tz = child.event?.timezone || DEFAULT_EVENT_TIME_ZONE
  const eventStatus = child.event?.status
  const blockReason = (child.admission_block_reason || '').toLowerCase()

  if (child.status === 'cancelled' || eventStatus === 'cancelled') {
    return { code: 'cancelled', label: 'Cancelled', className: 'bg-red-100 text-red-800' }
  }
  if (child.refund_pending || blockReason.includes('refund')) {
    return { code: 'refund_pending', label: 'Refund Pending', className: 'bg-amber-100 text-amber-900' }
  }
  if (eventStatus === 'postponed') {
    return { code: 'postponed', label: 'Postponed', className: 'bg-amber-100 text-amber-900' }
  }
  if (child.status === 'checked_in') {
    return { code: 'checked_in', label: 'Checked In', className: 'bg-emerald-100 text-emerald-800' }
  }
  if (child.status === 'transferred') {
    return { code: 'transferred', label: 'Transferred', className: 'bg-amber-100 text-amber-900' }
  }
  if (child.status === 'issued' && child.admission_allowed === false) {
    return { code: 'access_paused', label: 'Access Paused', className: 'bg-amber-100 text-amber-900' }
  }

  const startKey = localDateKey(child.event?.starts_at, tz)
  const nowKey = localDateKey(now, tz)
  const startMs = child.event?.starts_at ? new Date(child.event.starts_at).getTime() : null
  const endMs = child.event?.ends_at ? new Date(child.event.ends_at).getTime() : null
  const nowMs = now instanceof Date ? now.getTime() : new Date(now).getTime()

  if (child.status === 'issued' && (
    (startKey && nowKey && startKey === nowKey) ||
    (startMs !== null && endMs !== null && startMs <= nowMs && endMs >= nowMs)
  )) {
    return { code: 'tonight', label: 'Tonight', className: 'bg-brand-100 text-brand-900' }
  }
  if (child.status === 'issued' && ((startKey && nowKey && startKey > nowKey) || (startMs !== null && startMs > nowMs))) {
    return { code: 'upcoming', label: 'Upcoming', className: 'bg-brand-50 text-brand-800' }
  }
  return { code: 'past', label: 'Past', className: 'bg-neutral-100 text-neutral-700' }
}

export function selectSpotlightNight(childTickets = [], now = new Date()) {
  const ordered = sortedChildTickets(childTickets)
  if (ordered.length === 0) return { kind: null, ticket: null, ordered }

  const nowMs = now instanceof Date ? now.getTime() : new Date(now).getTime()
  const isActiveIssued = child => child.status === 'issued' && child.event?.status === 'published' && child.admission_allowed !== false

  const tonight = ordered.find(child => {
    if (!isActiveIssued(child)) return false
    const tz = child.event?.timezone || DEFAULT_EVENT_TIME_ZONE
    const startKey = localDateKey(child.event?.starts_at, tz)
    const nowKey = localDateKey(now, tz)
    const startMs = child.event?.starts_at ? new Date(child.event.starts_at).getTime() : null
    const endMs = child.event?.ends_at ? new Date(child.event.ends_at).getTime() : null
    return (startKey && nowKey && startKey === nowKey) || (startMs !== null && endMs !== null && startMs <= nowMs && endMs >= nowMs)
  })
  if (tonight) return { kind: 'tonight', ticket: tonight, ordered }

  const upcoming = ordered.find(child => {
    if (!isActiveIssued(child)) return false
    const tz = child.event?.timezone || DEFAULT_EVENT_TIME_ZONE
    const startKey = localDateKey(child.event?.starts_at, tz)
    const nowKey = localDateKey(now, tz)
    const startMs = child.event?.starts_at ? new Date(child.event.starts_at).getTime() : null
    return (startKey && nowKey && startKey > nowKey) || (startMs !== null && startMs > nowMs)
  })
  if (upcoming) return { kind: 'next', ticket: upcoming, ordered }

  const activeFallback = ordered.find(child => child.status === 'issued' && child.event?.status !== 'cancelled')
  return { kind: 'recent', ticket: activeFallback || ordered[ordered.length - 1], ordered }
}

export function childTicketHref(child, orderId) {
  const rawUrl = child.ticket_url || (
    (child.display_credential || child.display_token)
      ? `/tickets/${encodeURIComponent(child.display_credential || child.display_token)}`
      : null
  )
  if (!rawUrl) return null
  if (!orderId) return rawUrl
  const separator = rawUrl.includes('?') ? '&' : '?'
  return `${rawUrl}${separator}order=${encodeURIComponent(orderId)}`
}
