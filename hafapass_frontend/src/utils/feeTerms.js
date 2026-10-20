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
// the authoritative amount.
export function platformFeeCents(terms, ticketSubtotalCents, ticketCount) {
  if (!terms || ticketSubtotalCents <= 0) return 0
  return Math.round(ticketSubtotalCents * (terms.percent / 100)) + (ticketCount * terms.flatCents)
}

function dollars(cents) {
  return `$${(cents / 100).toFixed(2)}`
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
    ? 'HåfaPass covers card processing out of this fee.'
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
