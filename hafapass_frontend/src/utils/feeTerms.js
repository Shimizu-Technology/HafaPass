import { formatMoneyCents } from './money'

// Platform fee terms come only from the server (/config). A missing or invalid
// value returns null so callers can show a retryable error instead of guessing.
export function parseFeeTerms(config) {
  if (config?.service_fee_percent == null || config?.service_fee_flat_cents == null) return null
  const percent = Number(config.service_fee_percent)
  const flatCents = Number(config.service_fee_flat_cents)
  if (!Number.isFinite(percent) || percent < 0 || !Number.isInteger(flatCents) || flatCents < 0) return null
  const bearer = ['platform', 'organizer'].includes(config.processing_fee_bearer) ? config.processing_fee_bearer : null
  const payoutScheduleText = typeof config.payout_schedule_text === 'string' ? config.payout_schedule_text.trim() || null : null
  return { percent, flatCents, bearer, payoutScheduleText }
}

// Mirrors Commerce::OrderCreator#calculate_totals; the created order remains
// the authoritative amount. paidTicketCount counts only tickets whose unit
// price is above zero (before promo discounts): free tickets carry no fee.
export function platformFeeCents(terms, ticketSubtotalCents, paidTicketCount) {
  if (!terms || ticketSubtotalCents <= 0) return 0
  return Math.round(ticketSubtotalCents * (terms.percent / 100)) + (paidTicketCount * terms.flatCents)
}

// Buyer and organizer amounts for one ticket at a fee policy, using the same
// rounding as the server.
export function feeExample(terms, priceCents, feePolicy, buyerFeePercent) {
  const platformFee = platformFeeCents(terms, priceCents, priceCents > 0 ? 1 : 0)
  const buyerPercent = feePolicy === 'organizer_absorbs' ? 0 : feePolicy === 'split_fees' ? Number(buyerFeePercent) || 0 : 100
  const buyerFee = Math.round(platformFee * (buyerPercent / 100))
  return { buyerPaysCents: priceCents + buyerFee, organizerReceivesCents: priceCents - (platformFee - buyerFee) }
}

function dollars(cents) {
  return formatMoneyCents(cents)
}

export function feeRateLabel(terms) {
  const percent = `${Number(terms.percent.toFixed(2))}%`
  return terms.flatCents > 0 ? `${percent} + ${dollars(terms.flatCents)} per paid ticket` : `${percent} of paid ticket sales`
}

// Plain-language explanation of who pays what, for organizer screens.
export function organizerFeeExplanation(terms, feePolicy, buyerFeePercent) {
  if (!terms) return null
  const rate = feeRateLabel(terms)
  const platformCovers = terms.bearer === 'platform'
  const processing = platformCovers
    ? 'HåfaPass covers card processing on tickets out of this fee.'
    : terms.bearer === 'organizer' ? 'Card processing costs are deducted from your proceeds.' : null
  const buyerShare = Number(buyerFeePercent)
  let sentences
  if (feePolicy === 'organizer_absorbs') {
    sentences = [`You cover the service fee of ${rate}, so buyers pay only the ticket price.`, processing]
  } else if (feePolicy === 'split_fees') {
    const share = Number.isFinite(buyerShare) ? `${buyerShare}%` : 'part'
    sentences = [`Buyers pay ${share} of the service fee (${rate}) and you cover the rest.`, processing]
  } else if (platformCovers) {
    sentences = [`Buyers pay a service fee of ${rate}, which includes card processing. You receive the full ticket price.`]
  } else {
    sentences = [`Buyers pay a service fee of ${rate}.`, processing]
  }
  return [...sentences, 'Free tickets have no fee.'].filter(Boolean).join(' ')
}
