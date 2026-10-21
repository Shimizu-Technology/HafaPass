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

  it('redacts TIN and tax fields without over-redacting keys that merely contain "tin"', () => {
    const scrubbed = scrubTelemetry({ tin: '123456789', tin_last_four: '6789', taxpayer_id: '1', tax_information: { tin: 'x' }, destination: '/events/1', setting: 'on', meeting: 'yes' })
    expect(scrubbed.tin).toBe('[redacted]')
    expect(scrubbed.tin_last_four).toBe('[redacted]')
    expect(scrubbed.taxpayer_id).toBe('[redacted]')
    expect(scrubbed.tax_information).toBe('[redacted]')
    expect(scrubbed.destination).toBe('/events/1')
    expect(scrubbed.setting).toBe('on')
    expect(scrubbed.meeting).toBe('yes')
  })
})
