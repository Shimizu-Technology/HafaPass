import { describe, expect, it } from 'vitest'
import {
  calculateHostPayout, describeFee, formatPercent, parseHostPricing, parsePriceInput, parseQuantityInput, serviceFeeCents,
} from './hostPricing'

const launch = { basisPoints: 500, flatCents: 100 }

describe('parseHostPricing', () => {
  it('reads the Rails decimal string and optional launch fields', () => {
    expect(parseHostPricing({ service_fee_percent: '5.0', service_fee_flat_cents: 100, processing_fee_bearer: 'platform', payout_schedule_text: ' within 3 business days after your event ' }))
      .toEqual({ basisPoints: 500, flatCents: 100, processingIncluded: true, payoutScheduleText: 'within 3 business days after your event' })
  })

  it('leaves absent optional fields unknown instead of assuming them', () => {
    expect(parseHostPricing({ service_fee_percent: 3, service_fee_flat_cents: 50 }))
      .toEqual({ basisPoints: 300, flatCents: 50, processingIncluded: null, payoutScheduleText: null })
    expect(parseHostPricing({ service_fee_percent: 3, service_fee_flat_cents: 50, processing_fee_bearer: 'organizer' }).processingIncluded).toBe(false)
  })

  it.each([
    [null], [undefined], [{}], [{ service_fee_percent: '5.0' }], [{ service_fee_flat_cents: 100 }],
    [{ service_fee_percent: 'abc', service_fee_flat_cents: 100 }], [{ service_fee_percent: -1, service_fee_flat_cents: 100 }],
    [{ service_fee_percent: 5, service_fee_flat_cents: 1.5 }], [{ service_fee_percent: null, service_fee_flat_cents: null }],
  ])('returns null when the fee is missing or invalid (%j)', config => {
    expect(parseHostPricing(config)).toBeNull()
  })
})

describe('fee wording', () => {
  it('describes the configured fee without inventing parts', () => {
    expect(describeFee(launch)).toBe('5% + $1.00 per paid ticket')
    expect(describeFee({ basisPoints: 325, flatCents: 0 })).toBe('3.25% per paid ticket')
    expect(describeFee({ basisPoints: 0, flatCents: 75 })).toBe('$0.75 per paid ticket')
    expect(describeFee({ basisPoints: 0, flatCents: 0 })).toBe('No fee on tickets')
    expect(formatPercent(350)).toBe('3.5%')
  })
})

describe('input parsing', () => {
  it.each([['25', 2500], ['12.5', 1250], ['12.50', 1250], ['$1,250.00', 125000], ['.99', 99], ['0', 0], [' 7 ', 700]])('reads %j as %i cents', (input, cents) => {
    expect(parsePriceInput(input)).toBe(cents)
  })

  it.each([[''], ['abc'], ['-5'], ['12.345'], ['1e3'], ['10000.01'], ['.']])('rejects %j', input => {
    expect(parsePriceInput(input)).toBeNull()
  })

  it('accepts whole ticket counts within range only', () => {
    expect(parseQuantityInput('4')).toBe(4)
    for (const input of ['0', '1.5', '-2', '', 'two', '1001']) expect(parseQuantityInput(input)).toBeNull()
  })
})

describe('calculateHostPayout', () => {
  it('passes the fee to the buyer or takes it from the organizer', () => {
    expect(calculateHostPayout({ priceCents: 2500, quantity: 1, pricing: launch })).toEqual({
      subtotalCents: 2500,
      feeCents: 225,
      buyerPays: { buyerTotalCents: 2725, organizerReceivesCents: 2500 },
      organizerAbsorbs: { buyerTotalCents: 2500, organizerReceivesCents: 2275 },
      feeExceedsPrice: false,
    })
  })

  it('applies the percentage to the order subtotal and the flat fee per ticket', () => {
    const result = calculateHostPayout({ priceCents: 1999, quantity: 3, pricing: launch })
    // 5% of $59.97 = $2.9985 -> $3.00, plus 3 x $1.00.
    expect(result.feeCents).toBe(600)
    expect(result.buyerPays.buyerTotalCents).toBe(6597)
    expect(result.organizerAbsorbs.organizerReceivesCents).toBe(5397)
  })

  it('rounds half a cent up like the checkout without float drift', () => {
    expect(serviceFeeCents({ priceCents: 1010, quantity: 1, pricing: { basisPoints: 500, flatCents: 0 } })).toBe(51) // 50.5
    expect(serviceFeeCents({ priceCents: 1009, quantity: 1, pricing: { basisPoints: 500, flatCents: 0 } })).toBe(50) // 50.45
    expect(serviceFeeCents({ priceCents: 100, quantity: 1, pricing: { basisPoints: 350, flatCents: 0 } })).toBe(4) // 3.5
  })

  it('charges nothing on free tickets', () => {
    expect(calculateHostPayout({ priceCents: 0, quantity: 25, pricing: launch })).toEqual({
      subtotalCents: 0,
      feeCents: 0,
      buyerPays: { buyerTotalCents: 0, organizerReceivesCents: 0 },
      organizerAbsorbs: { buyerTotalCents: 0, organizerReceivesCents: 0 },
      feeExceedsPrice: false,
    })
  })

  it('floors absorbed proceeds at zero like checkout when the fee exceeds a cheap ticket', () => {
    const result = calculateHostPayout({ priceCents: 50, quantity: 1, pricing: launch })
    expect(result.feeCents).toBe(103)
    expect(result.organizerAbsorbs.organizerReceivesCents).toBe(0)
    expect(result.feeExceedsPrice).toBe(true)
    expect(result.buyerPays).toEqual({ buyerTotalCents: 153, organizerReceivesCents: 50 })
  })
})
