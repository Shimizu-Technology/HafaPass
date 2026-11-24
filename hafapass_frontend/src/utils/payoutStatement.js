import { formatMoneyCents } from './money'

// Plain-language helpers for the organizer payout statement. Amounts and
// statuses come from the API; these only format them.

// A calendar date (YYYY-MM-DD) from the API, shown as written, never shifted
// by the viewer's time zone.
export const formatDay = value => {
  if (!value) return ''
  const [year, month, day] = String(value).slice(0, 10).split('-').map(Number)
  return new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' })
    .format(new Date(Date.UTC(year, month - 1, day)))
}

export function signedMoney(cents, currency = 'USD') {
  const value = Number(cents) || 0
  return `${value < 0 ? '−' : ''}${formatMoneyCents(Math.abs(value), currency)}`
}

export function statusSummary(data) {
  const { status, totals, schedule, transfers = [] } = data
  const money = cents => formatMoneyCents(cents, data.currency)
  const lastSent = [...transfers].reverse().find(transfer => transfer.status === 'paid')
  switch (status) {
    case 'sales_open':
      return 'Sales are still open, so these numbers will change until the event ends.'
    case 'waiting_for_payout':
      if (transfers.some(transfer => ['pending', 'processing', 'held'].includes(transfer.status))) {
        return `A transfer of ${money(totals.in_progress_cents)} is on its way to your bank account.`
      }
      if (schedule.reserve_released) return `Your reserve was released. HåfaPass is sending the remaining ${money(totals.still_to_come_cents)}.`
      return schedule.transfer_expected_by
        ? `The event has ended. HåfaPass sends your bank transfer within 2–3 business days, by ${formatDay(schedule.transfer_expected_by)}.`
        : 'The event has ended. HåfaPass sends your bank transfer within 2–3 business days.'
    case 'reserve_held': {
      const sent = lastSent ? `We sent ${money(totals.transferred_cents)} to your bank account. ` : ''
      const held = `${money(totals.reserve_held_cents)} is held until ${formatDay(schedule.reserve_release_on)} in case of chargebacks`
      if (totals.still_to_come_cents < 0) return `${sent}${held}, but later refunds or chargebacks are bigger than it: you owe ${money(-totals.still_to_come_cents)}.`
      if (totals.still_to_come_cents < totals.reserve_held_cents) return `${sent}${held}. Later refunds or chargebacks come out of it, so ${money(totals.still_to_come_cents)} will be sent to you.`
      return `${sent}${held}, then sent to you.`
    }
    default:
      if (totals.still_to_come_cents < 0) return `This event is closed. You owe ${money(-totals.still_to_come_cents)}, which comes out of your next payout.`
      return totals.transferred_cents > 0 ? `Everything for this event has been paid: ${money(totals.transferred_cents)} in total.` : 'This event is closed. Nothing is owed.'
  }
}

// The note under the "Still to come" figure. When later refunds or chargebacks
// have used part of the held reserve, say so instead of claiming the figure
// includes the whole reserve.
export function stillToComeDetail(data) {
  const { totals, schedule } = data
  const money = cents => formatMoneyCents(cents, data.currency)
  const still = totals.still_to_come_cents
  const held = totals.reserve_held_cents
  if (still < 0) return 'Taken from your next payout'
  if (!(held > 0)) return null
  const due = formatDay(schedule.reserve_release_on)
  if (still < held) return `What is left of the ${money(held)} reserve after later refunds or chargebacks (${money(held - still)}), due ${due}`
  return `Includes the ${money(held)} reserve, due ${due}`
}

// The warning when a statement fails its own checks. Arithmetic mismatches
// give the amount; a wording contradiction never shows "off by $0.00".
export function reconcileWarning(data) {
  if (data.reconciles) return null
  const after = 'Please contact HåfaPass before relying on it.'
  if (data.difference_cents > 0) return `These lines do not add up to the totals (off by ${formatMoneyCents(data.difference_cents, data.currency)}). ${after}`
  return `Some wording on this statement does not match its numbers. ${after}`
}
