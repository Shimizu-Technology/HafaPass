import { describe, expect, it } from 'vitest'
import { paidPayoutExplanation, payoutAccountLabel, payoutProviderLabel, payoutRequirementLabel } from './payoutLabels'

describe('payout labels', () => {
  it('names bank transfers and finance requirements without exposing storage codes', () => {
    expect(payoutProviderLabel('manual')).toBe('Bank transfer')
    expect(payoutAccountLabel({ provider: 'manual', status: 'requirements_due', payout_ready: false })).toBe('Bank transfer · Review needed')
    expect(payoutAccountLabel({ provider: 'check', status: 'ready', payout_ready: false })).toBe('Check · Review needed')
    expect(payoutAccountLabel({ provider: 'check', status: 'ready', payout_ready: true })).toBe('Check · Approved')
    expect(payoutRequirementLabel('independent_readiness_approval')).toBe('finance approval')
    expect(payoutRequirementLabel('unknown_provider_code')).toBe('payout details review')
  })
  it('distinguishes check recording from bank confirmation', () => {
    expect(paidPayoutExplanation('check')).toContain('does not confirm the check has cleared')
    expect(paidPayoutExplanation('manual')).toContain('bank or provider payment confirmation')
  })
})
