import { describe, expect, it } from 'vitest'
import { promoDiscountFromApi, promoDiscountToApi } from './promoDiscount'

describe('promo discount units', () => {
  it('converts five dollars to exactly 500 cents', () => {
    expect(promoDiscountToApi('5.00', 'fixed')).toBe(500)
    expect(promoDiscountToApi('0.29', 'fixed')).toBe(29)
  })
  it('round-trips fixed amounts for display and editing', () => {
    for (const cents of [1, 29, 500, 123456]) {
      expect(promoDiscountToApi(promoDiscountFromApi(cents, 'fixed'), 'fixed')).toBe(cents)
    }
    expect(promoDiscountFromApi(500, 'fixed')).toBe('5.00')
  })
  it('limits fixed discounts to the API integer column range', () => {
    expect(promoDiscountToApi('21474836.47', 'fixed')).toBe(2147483647)
    expect(promoDiscountToApi('21474836.48', 'fixed')).toBeNull()
    expect(promoDiscountToApi('999999999999999999', 'fixed')).toBeNull()
    expect(promoDiscountToApi('100', 'percentage')).toBe(100)
    expect(promoDiscountToApi('2147483647', 'percentage')).toBeNull()
  })
  it('keeps percentage units and rejects ambiguous or invalid amounts', () => {
    expect(promoDiscountToApi('20', 'percentage')).toBe(20)
    for (const value of ['', '-1', '0', '5.001', 'Infinity', '1e2']) expect(promoDiscountToApi(value, 'fixed')).toBeNull()
    for (const value of ['0', '101', '5.5']) expect(promoDiscountToApi(value, 'percentage')).toBeNull()
  })
})
