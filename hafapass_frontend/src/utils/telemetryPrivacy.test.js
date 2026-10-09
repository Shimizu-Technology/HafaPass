import { describe, expect, it } from 'vitest'
import { monitoringPath, scrubTelemetry } from './telemetryPrivacy'

describe('telemetry privacy', () => {
  it('redacts signed Rails ticket paths, even when they are not UUIDs', () => {
    const credential = 'eyJfcmFpbHMiOnsibWVzc2FnZSI6Ik1UST0ifX0--signed-secret'
    expect(monitoringPath(`/tickets/${credential}?order=42&guest_token=bearer`)).toBe('/tickets/:id')
    expect(monitoringPath(`/orders/42/tickets/7/rotate_scan`)).toBe('/orders/:id/tickets/:id/rotate_scan')
  })

  it('scrubs request headers, breadcrumbs, and transactions before they leave the browser', () => {
    const event = { request: { url: 'https://app.invalid/tickets/signed-ticket?guest_token=secret', headers: { Authorization: 'Bearer secret', Cookie: 'session=secret' } }, breadcrumbs: [{ data: { from: '/ticket-transfers/accept?token=secret', to: '/tickets/signed-ticket' } }], transaction: '/tickets/signed-ticket', extra: { buyer_email: 'buyer@private.invalid' } }
    const serialized = JSON.stringify(scrubTelemetry(event))
    expect(serialized).not.toContain('secret')
    expect(serialized).not.toContain('signed-ticket')
    expect(serialized).not.toContain('buyer@private.invalid')
  })
})
