function selectedTicketType(event, ticketTypeId) {
  return event?.ticket_types?.find(type => String(type.id) === String(ticketTypeId))
}

const validCents = value => Number.isSafeInteger(value) && value >= 0

// The pre-order estimate for one selected line, priced exactly as it was
// advertised: a claimed waitlist offer keeps its offered unit price, held
// seats use the seat map's prices, and everything else uses the ticket type.
// Fees are the server's per-ticket buyer fees (Commerce::ServiceFee); a paid
// line without fee data returns feeCents null so checkout shows an error
// instead of a $0 fee.
export function estimateCheckoutLine(event, item, { waitlistOffer = null, seats = [] } = {}) {
  const tt = selectedTicketType(event, item.ticket_type_id)
  if (!tt) return null
  const absorbed = Number(event.buyer_fee_percent) === 0
  const feeFor = (price, fee) => validCents(fee) ? fee : price === 0 || absorbed ? 0 : null
  const base = { ...item, name: tt.name, active_tier: tt.active_tier }
  if (waitlistOffer && String(waitlistOffer.ticket_type_id) === String(item.ticket_type_id) && validCents(waitlistOffer.unit_price_cents)) {
    const price = waitlistOffer.unit_price_cents
    const fee = feeFor(price, waitlistOffer.service_fee_cents)
    return { ...base, price_cents: price, lineTotal: price * item.quantity, feeCents: fee === null ? null : fee * item.quantity }
  }
  const lineSeats = seats.filter(seat => String(seat.ticket_type_id) === String(item.ticket_type_id))
  if (lineSeats.length === item.quantity && lineSeats.every(seat => validCents(seat.price_cents))) {
    const fees = lineSeats.map(seat => feeFor(seat.price_cents, seat.service_fee_cents))
    return { ...base, price_cents: lineSeats[0].price_cents, lineTotal: lineSeats.reduce((sum, seat) => sum + seat.price_cents, 0),
      feeCents: fees.includes(null) ? null : fees.reduce((sum, fee) => sum + fee, 0) }
  }
  const price = tt.current_price_cents ?? tt.price_cents
  const fee = feeFor(price, tt.service_fee_cents)
  return { ...base, price_cents: price, lineTotal: price * item.quantity, feeCents: fee === null ? null : fee * item.quantity }
}
