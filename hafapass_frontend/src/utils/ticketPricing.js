import { formatMoneyCents } from './money'

// Discovery is a snapshot. Checkout still obtains the authoritative server quote.
//
// Prices lead with the all-in amount: the ticket price plus the mandatory
// per-ticket service fee the buyer pays under the event's fee policy (FTC
// 16 CFR Part 464). The API computes all_in_price_cents and service_fee_cents
// with the same code checkout uses; this module only reads and formats them.
export function remainingTickets(ticket) {
  if (Number.isFinite(ticket.quantity_remaining)) return Math.max(0, ticket.quantity_remaining)
  if (Number.isFinite(ticket.quantity_available) && Number.isFinite(ticket.quantity_sold)) {
    return Math.max(0, ticket.quantity_available - ticket.quantity_sold)
  }
  return null
}

export function isTicketPurchasable(ticket) {
  const remaining = remainingTickets(ticket)
  return ticket.on_sale !== false && (remaining === null || remaining > 0)
}

export function ticketPriceCents(ticket) {
  const price = ticket.current_price_cents ?? ticket.price_cents
  return Number.isSafeInteger(price) && price >= 0 ? price : null
}

const validCents = value => Number.isSafeInteger(value) && value >= 0

// The buyer's per-ticket total. Payloads without fee data (older cached
// responses) fall back to the ticket price, which is the all-in price when the
// organizer absorbs the fee.
export function ticketAllInCents(ticket) {
  const base = ticketPriceCents(ticket)
  if (base === null) return null
  if (validCents(ticket.all_in_price_cents)) return ticket.all_in_price_cents
  if (import.meta.env.DEV && base > 0) {
    console.warn('ticketAllInCents: no all_in_price_cents on a paid ticket; showing the base price', ticket.id ?? ticket.name)
  }
  return base
}

export function ticketServiceFeeCents(ticket) {
  return validCents(ticket.service_fee_cents) ? ticket.service_fee_cents : 0
}

// Lowest all-in price among purchasable tickets, for "From $X" labels.
export function lowestPurchasablePrice(ticketTypes = []) {
  const prices = ticketTypes.filter(isTicketPurchasable).map(ticketAllInCents).filter(price => price !== null)
  return prices.length ? Math.min(...prices) : null
}

// All-in prices of purchasable tickets, e.g. for structured data offers.
export function purchasableAllInPrices(ticketTypes = []) {
  return ticketTypes.filter(isTicketPurchasable).map(ticketAllInCents).filter(price => price !== null)
}

export function formatTicketPrice(cents, freeLabel = 'Free') {
  if (cents === null || !Number.isSafeInteger(cents) || cents < 0) return ''
  return cents === 0 ? freeLabel : formatMoneyCents(cents)
}
