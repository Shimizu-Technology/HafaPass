import { describe, expect, it } from 'vitest'
import { feeExample, feeRateLabel, organizerFeeExplanation, parseFeeTerms, platformFeeCents, quoteBuyerFeeCents } from './feeTerms'
import parity from './__fixtures__/serviceFeeParity.json'

const allIn = { service_fee_percent: '5.0', service_fee_flat_cents: 100, processing_fee_bearer: 'platform', payout_schedule_text: 'within 3 to 5 business days after your event' }

describe('fee terms', () => {
  it.each(parity.cases)('matches checkout to the cent at $price_cents × $quantity and $buyer_fee_percent% buyer share', example => {
    const terms = parseFeeTerms({ service_fee_percent: example.service_fee_percent,
      service_fee_flat_cents: example.service_fee_flat_cents })
    const quote = quoteBuyerFeeCents(terms, example.price_cents, example.buyer_fee_percent)
    expect(quote.platformFeeCents * example.quantity).toBe(example.platform_fee_cents)
    expect(quote.buyerFeeCents * example.quantity).toBe(example.buyer_fee_cents)
    expect(quote.allInPriceCents * example.quantity).toBe(example.all_in_total_cents)
  })
  it('parses server terms and refuses to guess missing or invalid values', () => {
    expect(parseFeeTerms(allIn)).toEqual({ percent: 5, flatCents: 100, bearer: 'platform', payoutScheduleText: 'within 3 to 5 business days after your event' })
    expect(parseFeeTerms({ ...allIn, service_fee_percent: undefined })).toBeNull()
    expect(parseFeeTerms({ ...allIn, service_fee_flat_cents: null })).toBeNull()
    expect(parseFeeTerms({ ...allIn, service_fee_percent: 'abc' })).toBeNull()
    expect(parseFeeTerms({ ...allIn, service_fee_flat_cents: 1.5 })).toBeNull()
    expect(parseFeeTerms(null)).toBeNull()
    expect(parseFeeTerms({ ...allIn, processing_fee_bearer: 'buyer' }).bearer).toBeNull()
  })

  it('matches the server fee formula and charges nothing on free tickets', () => {
    const terms = parseFeeTerms(allIn)
    expect(platformFeeCents(terms, 12500, 3)).toBe(925)
    expect(platformFeeCents(terms, 0, 2)).toBe(0)
    expect(feeRateLabel(terms)).toBe('5% + $1.00 per paid ticket')
    // Two $25 paid tickets plus free tickets: only the paid ones carry $1.00.
    expect(platformFeeCents(terms, 5000, 2)).toBe(450)
    expect(feeExample(terms, 2500, 'buyer_pays', 100)).toEqual({ buyerPaysCents: 2725, organizerReceivesCents: 2500 })
    expect(feeExample(terms, 2500, 'split_fees', 50)).toEqual({ buyerPaysCents: 2613, organizerReceivesCents: 2388 })
    expect(feeExample(terms, 0, 'buyer_pays', 100)).toEqual({ buyerPaysCents: 0, organizerReceivesCents: 0 })
    expect(feeRateLabel(parseFeeTerms({ ...allIn, service_fee_percent: '3.5', service_fee_flat_cents: 0 }))).toBe('3.5% of paid ticket sales')
  })

  it('explains each policy for the platform and organizer bearer', () => {
    const platform = parseFeeTerms(allIn)
    const organizer = parseFeeTerms({ ...allIn, processing_fee_bearer: 'organizer' })
    expect(organizerFeeExplanation(platform, 'buyer_pays', 100)).toBe('Buyers pay a service fee of 5% + $1.00 per paid ticket, which includes card processing. You receive the full ticket price. Free tickets have no fee.')
    expect(organizerFeeExplanation(platform, 'organizer_absorbs', 0)).toContain('HåfaPass covers card processing on tickets out of this fee.')
    expect(organizerFeeExplanation(platform, 'split_fees', 40)).toContain('Buyers pay 40% of the service fee (5% + $1.00 per paid ticket) and you cover the rest.')
    expect(organizerFeeExplanation(organizer, 'buyer_pays', 100)).toBe('Buyers pay a service fee of 5% + $1.00 per paid ticket. Card processing costs are deducted from your proceeds. Free tickets have no fee.')
    expect(organizerFeeExplanation(organizer, 'organizer_absorbs', 0)).not.toContain('HåfaPass covers')
  })
})
