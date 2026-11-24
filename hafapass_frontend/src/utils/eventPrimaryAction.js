import { remainingTickets } from './ticketPricing'
import { getServerNow } from './serverClock'

export function nextSalesOpening(ticketTypes = [], now = getServerNow()) {
  const openings = ticketTypes.filter(ticket => ticket.on_sale === false)
    .map(ticket => ticket.pricing_schedule?.next_tier?.starts_at || ticket.next_tier?.starts_at)
    .filter(value => Date.parse(value) > now)
    .sort((a, b) => Date.parse(a) - Date.parse(b))
  return openings[0] || null
}

export function getPrimaryAction(event, summary, now = getServerNow()) {
  if (event.private_preview) return { kind: 'private' }
  if (['cancelled', 'postponed'].includes(event.status)) return { kind: 'closed' }
  const end = event.ends_at ? Date.parse(event.ends_at) : Date.parse(event.starts_at) + 4 * 3600000
  if (event.status === 'completed' || end < now) return { kind: 'past', labelKey: 'eventActions.ended' }
  const tickets = event.ticket_types || []
  if (event.status === 'published' && tickets.length && tickets.every(ticket => remainingTickets(ticket) === 0)) {
    return { kind: 'waitlist', labelKey: 'eventActions.joinWaitlist', target: 'waitlist', actionable: true }
  }
  const opensAt = nextSalesOpening(tickets, now)
  if (tickets.length && tickets.every(ticket => ticket.on_sale === false) && opensAt) {
    return { kind: 'notify', labelKey: 'eventActions.notifyMe', opensAt, actionable: true }
  }
  if (event.purchasable === true && (event.assigned_seating || summary)) {
    return { kind: summary?.kind === 'free' ? 'free' : 'paid', labelKey: summary?.kind === 'free' ? 'eventActions.reserve' : 'buyer.EventDetail.getTickets', target: 'tickets', actionable: true }
  }
  return { kind: 'unavailable' }
}

export function selectionAction(selection) {
  return selection.totalCents === 0
    ? { key: 'eventActions.reserveCount', values: { count: selection.count } }
    : { key: 'eventActions.checkoutTotal', values: { total: selection.formattedTotal } }
}
