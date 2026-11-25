import { describe, expect, it } from 'vitest'
import { monitoringAreaForPath } from './monitoringArea'

describe('monitoringAreaForPath', () => {
  it('names the checkout, scanner and box-office pages', () => {
    expect(monitoringAreaForPath('/checkout/copa-de-marianas')).toBe('checkout')
    expect(monitoringAreaForPath('/orders/123/confirmation')).toBe('checkout')
    expect(monitoringAreaForPath('/orders/recover')).toBe('checkout')
    expect(monitoringAreaForPath('/dashboard/scanner')).toBe('scanner')
    expect(monitoringAreaForPath('/dashboard/events/42/box-office')).toBe('box_office')
  })

  it('leaves everything else untagged', () => {
    expect(monitoringAreaForPath('/')).toBeNull()
    expect(monitoringAreaForPath('/events/copa')).toBeNull()
    expect(monitoringAreaForPath('/checkoutfoo')).toBeNull()
    expect(monitoringAreaForPath(undefined)).toBeNull()
  })
})
