// Pure helpers for the email audience flow. Display only: the API decides who
// is eligible; these functions explain the numbers it returns.

export const PLATFORM_SOURCES = ['footer', 'home', 'checkout', 'event_page', 'waitlist', 'preferences']
export const SUBSCRIBER_STATUSES = ['pending', 'confirmed', 'unsubscribed', 'bounced', 'complained']
export const ORGANIZER_AUDIENCES = ['buyers', 'followers', 'waitlists']
export const STEP_KEYS = ['audience', 'write', 'preview', 'send']
export const SUBJECT_MAX = 240
export const BODY_MAX = 20000

const numberFormat = new Intl.NumberFormat('en-US')
export const formatCount = value => numberFormat.format(Number.isFinite(Number(value)) ? Number(value) : 0)

// i18next picks the plural form from `count`; `n` is the formatted number.
export const countValues = (count, extra = {}) => ({ count: Number(count) || 0, n: formatCount(count), ...extra })

export function activeFilterCount(filters, scope) {
  const keys = scope === 'platform' ? ['q', 'status', 'source', 'interest', 'since'] : ['q']
  return keys.filter(key => String(filters?.[key] || '').trim()).length
}

// Who will get the email, who is left out, and why.
export function audienceBreakdown(list, scope) {
  if (!list) return null
  const eligible = Math.max(0, Number(list.eligible) || 0)
  const considered = Math.max(eligible, Number(list.considered ?? list.count) || 0)
  const excluded = considered - eligible
  const reasons = []
  if (scope === 'platform' && list.status_breakdown) {
    const by = list.status_breakdown
    const pending = Number(by.pending) || 0
    const unsubscribed = Number(by.unsubscribed) || 0
    const bounced = (Number(by.bounced) || 0) + (Number(by.complained) || 0)
    const blocked = Math.max(0, excluded - pending - unsubscribed - bounced)
    for (const [key, count] of [['pending', pending], ['unsubscribed', unsubscribed], ['bounced', bounced], ['blocked', blocked]]) {
      if (count > 0) reasons.push({ key, count })
    }
  } else if (excluded > 0) {
    reasons.push({ key: 'noConsent', count: excluded })
  }
  return { eligible, considered, excluded, reasons }
}

// Why a list has no one to email, so the screen can say what to do next.
export function zeroReason({ list, scope, filterCount }) {
  const breakdown = audienceBreakdown(list, scope)
  if (!breakdown || breakdown.eligible > 0) return null
  if (breakdown.considered === 0) return filterCount > 0 ? 'filtered' : 'emptyList'
  return 'allLeftOut'
}

export function deliveryTotals(row) {
  const counts = row?.counts || {}
  const n = key => Number(counts[key]) || 0
  const tracked = Object.values(counts).reduce((sum, value) => sum + (Number(value) || 0), 0)
  const recipients = Math.max(Number(row?.recipient_count) || 0, tracked)
  const delivered = n('delivered') + n('opened') + n('clicked')
  const waiting = n('queued') + n('sent') + n('delayed')
  const bounced = n('bounced')
  const spam = n('complained')
  const notSent = n('failed') + n('suppressed') + n('cancelled')
  return { recipients, delivered, waiting, bounced, spam, notSent, unsubscribed: Number(row?.unsubscribed) || 0, processed: Math.max(0, recipients - n('queued')) }
}

// The state a person cares about, derived from the mailing and its deliveries.
export function mailingState(row, now = Date.now()) {
  switch (row?.status) {
    case 'draft': return 'draft'
    case 'cancelled': return 'cancelled'
    case 'blocked': return 'notSent'
    case 'queueing': return 'sending'
    case 'queued': return (Number(row.counts?.queued) || 0) > 0 ? 'sending' : 'sent'
    case 'scheduled': return row.scheduled_at && Date.parse(row.scheduled_at) > now ? 'scheduled' : 'starting'
    default: return 'sent'
  }
}

export const STATE_TONES = {
  draft: 'bg-neutral-100 text-neutral-700 ring-neutral-200',
  scheduled: 'bg-sky-50 text-sky-800 ring-sky-200',
  starting: 'bg-sky-50 text-sky-800 ring-sky-200',
  sending: 'bg-amber-50 text-amber-900 ring-amber-200',
  sent: 'bg-emerald-50 text-emerald-800 ring-emerald-200',
  cancelled: 'bg-neutral-100 text-neutral-600 ring-neutral-200',
  notSent: 'bg-red-50 text-red-800 ring-red-200',
}

const dateTime = new Intl.DateTimeFormat('en-US', { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit', timeZoneName: 'short' })
const shortDate = new Intl.DateTimeFormat('en-US', { dateStyle: 'medium' })
export function formatDateTime(value) {
  const time = Date.parse(value)
  return Number.isNaN(time) ? '' : dateTime.format(time)
}
export function formatDate(value) {
  const time = Date.parse(value)
  return Number.isNaN(time) ? '' : shortDate.format(time)
}
export function localZoneName() {
  try { return Intl.DateTimeFormat().resolvedOptions().timeZone || '' } catch { return '' }
}

// Errors the API returns as plain text; anything else gets the generic message.
export function errorKey(error) {
  const message = String(error?.response?.data?.error || '')
  if (/postal address/i.test(message)) return 'addressMissing'
  if (/invalid schedule/i.test(message)) return 'scheduleInvalid'
  if (error?.response?.status === 409) return 'conflict'
  if (error?.response?.status === 403) return 'forbidden'
  return 'generic'
}

// Human-readable filter list, e.g. "Signed up from: Checkout, Search: avery".
export function describeFilters(t, filters, scope = 'platform') {
  const parts = []
  for (const key of ['q', 'status', 'source', 'interest', 'since']) {
    const value = String(filters?.[key] || '').trim()
    if (!value || (scope !== 'platform' && key !== 'q')) continue
    const label = t(`emailFlow.filters.${key === 'q' ? 'search' : key}`)
    const shown = key === 'status' ? t(`emailFlow.subscriberStatuses.${value}`, { defaultValue: value })
      : key === 'source' ? t(`emailFlow.sources.${value}`, { defaultValue: value })
        : key === 'since' ? formatDate(`${value}T12:00:00`) || value : value
    parts.push(`${label}: ${shown}`)
  }
  return parts.join(', ')
}
