import { isTicketPurchasable, ticketPriceCents, ticketServiceFeeCents } from './ticketPricing'

export function allInPriceNoteKey(ticketTypes = [], includesProcessing = false) {
  const paid = ticketTypes.filter(ticket => isTicketPurchasable(ticket) && ticketPriceCents(ticket) > 0)
  if (!paid.length) return null
  const charged = paid.some(ticket => ticketServiceFeeCents(ticket) > 0)
  return !charged ? 'pricing.noAddedFees' : includesProcessing ? 'pricing.allInNote' : 'pricing.allInNoteNoProcessing'
}

