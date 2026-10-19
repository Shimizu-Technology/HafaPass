// Small copy helpers shared by organizer event tools (refunds, attendees).

export const pluralize = (count, singular, plural = `${singular}s`) => `${count} ${Number(count) === 1 ? singular : plural}`

export const ticketCountLabel = count => pluralize(count, 'ticket')

const formatDollars = cents => `$${(cents / 100).toFixed(2)}`

// Partial refunds must be a whole number of cents between 1 cent and the
// refundable amount; rounding would otherwise turn 0.004 into a $0.00 refund.
export const partialRefundCents = (amount, refundableCents) => {
  const text = String(amount ?? '').trim()
  if (!text) return { cents: null, error: 'Enter the amount to refund.' }
  if (!/^\d+(\.\d{1,2})?$/.test(text)) return { cents: null, error: 'Enter dollars and cents, like 12.50.' }
  const [whole, fraction = ''] = text.split('.')
  const cents = Number(whole) * 100 + Number(fraction.padEnd(2, '0'))
  if (!Number.isSafeInteger(cents) || cents < 1) return { cents: null, error: 'Enter at least $0.01.' }
  if (Number.isSafeInteger(refundableCents) && cents > refundableCents) return { cents: null, error: `Enter no more than ${formatDollars(refundableCents)}.` }
  return { cents, error: null }
}

// Names the money that will move so the destructive confirm is never ambiguous.
export const refundConfirmLabel = (order, form) => {
  if (form?.type === 'full' && Number.isSafeInteger(order?.refundable_cents) && order.refundable_cents > 0) {
    return `Refund ${formatDollars(order.refundable_cents)}`
  }
  if (form?.type === 'partial') {
    const { cents } = partialRefundCents(form.amount, order?.refundable_cents)
    if (cents) return `Refund ${formatDollars(cents)}`
  }
  return 'Process Refund'
}
