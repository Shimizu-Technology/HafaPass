import { beforeEach, describe, expect, it, vi } from 'vitest'
import { anonymousId, captureQueryAttribution, currentAttribution, trackFunnel } from './marketplaceAttribution'

describe('marketplace attribution', () => {
  beforeEach(() => localStorage.clear())

  it('keeps an anonymous browser identifier separate from campaign data', async () => {
    captureQueryAttribution('?utm_source=hotel&utm_medium=partner&utm_campaign=summer&distribution_code=GUAM123')
    const identity = anonymousId()
    const apiClient = { post: vi.fn().mockResolvedValue({}) }

    await trackFunnel(apiClient, 42, 'event_view')

    expect(identity).toHaveLength(36)
    expect(currentAttribution()).toMatchObject({ source: 'hotel', medium: 'partner', campaign: 'summer', distribution_code: 'GUAM123' })
    expect(apiClient.post).toHaveBeenCalledWith('/marketplace_funnel_events', expect.objectContaining({
      event_id: 42, stage: 'event_view', anonymous_id: identity, source: 'hotel',
    }))
  })

  it('preserves trusted referral attribution when the redirect query is captured', () => {
    captureQueryAttribution('?utm_source=user_referral&utm_medium=share&utm_campaign=FAN123&event_referral_code=FAN123')
    captureQueryAttribution('?event_referral_code=FAN123')

    expect(currentAttribution()).toMatchObject({
      source: 'user_referral', medium: 'share', campaign: 'FAN123', event_referral_code: 'FAN123',
    })
  })

  it('replaces stale channel codes when the acquisition channel changes', () => {
    captureQueryAttribution('?utm_source=hotel&utm_medium=partner&distribution_code=HOTEL1')
    captureQueryAttribution('?utm_source=user_referral&utm_medium=share&event_referral_code=FAN1')
    expect(currentAttribution()).toMatchObject({ event_referral_code: 'FAN1', source: 'user_referral' })
    expect(currentAttribution()).not.toHaveProperty('distribution_code')

    captureQueryAttribution('?utm_source=search&utm_medium=organic')
    expect(currentAttribution()).not.toHaveProperty('event_referral_code')
  })
})
