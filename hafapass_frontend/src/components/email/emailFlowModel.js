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
  } else if (excluded > 0 && scope !== 'platform') {
    // Platform reasons need `status_breakdown`; an older API omits it, so show no reasons then.
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

// Delivery outcomes, from MessageDelivery statuses. `delivered` (and `complained`,
// which follows delivery) means it arrived; `sent`/`delayed` were accepted by the
// provider with no result yet; `bounced`, `failed`, `suppressed` and `cancelled`
// did not arrive. Whether a row was handed to the provider comes from the API's
// `handed_off` (provider acceptance evidence), not from its final status.
const ACCEPTED_STATUSES = ['sent', 'delivered', 'delayed', 'bounced', 'complained']

export function deliveryTotals(row) {
  const counts = row?.counts || {}
  const n = key => Number(counts[key]) || 0
  const tracked = Object.values(counts).reduce((sum, value) => sum + (Number(value) || 0), 0)
  // The job records who it actually selected when sending starts; before that there is no count.
  const started = ['queueing', 'queued'].includes(row?.status)
  const recipients = started ? Number(row?.recipient_count) || tracked : tracked
  const queued = n('queued')
  const processed = Math.max(0, tracked - queued)
  // Older APIs omit `handed_off`; then only statuses that imply acceptance count.
  const reported = Number(row?.handed_off)
  const handedOff = Math.min(processed, Number.isFinite(reported) && row?.handed_off != null ? reported : ACCEPTED_STATUSES.reduce((sum, key) => sum + n(key), 0))
  const delivered = n('delivered')
  const spam = n('complained')
  const accepted = n('sent') + n('delayed')
  const bounced = n('bounced')
  const failed = n('failed')
  const skipped = n('suppressed') + n('cancelled')
  return {
    recipients, queued, accepted, delivered, spam, bounced, failed, skipped, handedOff, processed,
    notSent: processed - handedOff,
    arrived: delivered + spam,
    problems: bounced + failed + skipped,
    waiting: queued + accepted,
    unsubscribed: Number(row?.unsubscribed) || 0,
  }
}

// The state a person cares about, derived from the mailing and its delivery outcomes.
export function mailingState(row, now = Date.now()) {
  switch (row?.status) {
    case 'draft': return 'draft'
    case 'cancelled': return 'cancelled'
    case 'blocked': return 'notSent'
    case 'queueing': return 'sending'
    case 'queued': {
      const totals = deliveryTotals(row)
      if (totals.recipients === 0) return 'notDelivered'
      if (totals.queued > 0) return 'sending'
      // Nothing arrived and nothing is still on its way.
      if (totals.arrived + totals.accepted === 0) return 'notDelivered'
      return totals.problems > 0 ? 'partial' : 'sent'
    }
    case 'scheduled': return row.scheduled_at && Date.parse(row.scheduled_at) > now ? 'scheduled' : 'starting'
    default: return 'sent'
  }
}

// Only the server's status decides whether a send can still be cancelled; its lock settles races.
export const canCancel = row => row?.status === 'scheduled'

export const STATE_TONES = {
  draft: 'bg-neutral-100 text-neutral-700 ring-neutral-200',
  scheduled: 'bg-sky-50 text-sky-800 ring-sky-200',
  starting: 'bg-sky-50 text-sky-800 ring-sky-200',
  sending: 'bg-amber-50 text-amber-900 ring-amber-200',
  sent: 'bg-emerald-50 text-emerald-800 ring-emerald-200',
  partial: 'bg-amber-50 text-amber-900 ring-amber-200',
  notDelivered: 'bg-red-50 text-red-800 ring-red-200',
  cancelled: 'bg-neutral-100 text-neutral-600 ring-neutral-200',
  notSent: 'bg-red-50 text-red-800 ring-red-200',
}

// A lapsed schedule: the picked time is past or too close to send as "later".
export const SCHEDULE_MARGIN_MS = 60_000
export const scheduleLapsed = (scheduledAt, now = Date.now()) => !(Date.parse(scheduledAt) > now + SCHEDULE_MARGIN_MS)

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
  if (error?.response?.data?.code === 'schedule_lapsed') return 'scheduleLapsed'
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
