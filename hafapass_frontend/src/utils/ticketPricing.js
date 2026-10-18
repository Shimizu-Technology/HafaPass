// Discovery is a snapshot. Checkout still obtains the authoritative server quote.
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

export function lowestPurchasablePrice(ticketTypes = []) {
  const prices = ticketTypes.filter(isTicketPurchasable).map(ticketPriceCents).filter(price => price !== null)
  return prices.length ? Math.min(...prices) : null
}

export function formatTicketPrice(cents, freeLabel = 'Free') {
  if (cents === null || !Number.isSafeInteger(cents) || cents < 0) return ''
  return cents === 0 ? freeLabel : `$${(cents / 100).toFixed(2)}`
}
