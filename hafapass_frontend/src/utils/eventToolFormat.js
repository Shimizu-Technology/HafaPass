// Small copy helpers shared by organizer event tools (refunds, attendees).

export const pluralize = (count, singular, plural = `${singular}s`) => `${count} ${Number(count) === 1 ? singular : plural}`

export const ticketCountLabel = count => pluralize(count, 'ticket')

const formatDollars = cents => `$${(cents / 100).toFixed(2)}`

// Names the money that will move so the destructive confirm is never ambiguous.
export const refundConfirmLabel = (order, form) => {
  if (form?.type === 'full' && Number.isSafeInteger(order?.refundable_cents) && order.refundable_cents > 0) {
    return `Refund ${formatDollars(order.refundable_cents)}`
  }
  const partial = Number.parseFloat(form?.amount)
  if (form?.type === 'partial' && Number.isFinite(partial) && partial > 0) return `Refund ${formatDollars(Math.round(partial * 100))}`
  return 'Process Refund'
}
