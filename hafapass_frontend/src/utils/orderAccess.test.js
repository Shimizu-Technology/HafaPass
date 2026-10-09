import { beforeEach, describe, expect, it } from 'vitest'
import { getBuyerRefundAttempt, prepareBuyerRefundAttempt, recordBuyerRefundOutcome } from './orderAccess'

describe('buyer refund request persistence', () => {
  beforeEach(() => window.sessionStorage.clear())
  it('preserves unknown and pending operation identities, including contradictory reconciliation metadata', () => {
    const initial = prepareBuyerRefundAttempt(12, 'ticket:34')
    recordBuyerRefundOutcome(12, 'ticket:34', null)
    expect(prepareBuyerRefundAttempt(12, 'ticket:34').key).toBe(initial.key)
    recordBuyerRefundOutcome(12, 'ticket:34', { refund_status: 'failed', reconciliation_required: true })
    expect(getBuyerRefundAttempt(12, 'ticket:34').status).toBe('pending')
    expect(prepareBuyerRefundAttempt(12, 'ticket:34').key).toBe(initial.key)
  })
  it('creates one new identity after a definite terminal failure and preserves it until its own outcome is known', () => {
    const initial = prepareBuyerRefundAttempt(12, 'event:56')
    recordBuyerRefundOutcome(12, 'event:56', { refund_status: 'failed', reconciliation_required: false })
    const next = prepareBuyerRefundAttempt(12, 'event:56')
    expect(next.key).not.toBe(initial.key)
    expect(prepareBuyerRefundAttempt(12, 'event:56').key).toBe(next.key)
    expect(prepareBuyerRefundAttempt(13, 'event:56').key).not.toBe(next.key)
  })
  it('distinguishes a rejected request with no provider operation while retaining its identity for a safe retry', () => {
    const initial = prepareBuyerRefundAttempt(12, 'ticket:34')
    recordBuyerRefundOutcome(12, 'ticket:34', { error: 'Provider not supported', reconciliation_required: false })
    expect(getBuyerRefundAttempt(12, 'ticket:34').status).toBe('rejected')
    expect(prepareBuyerRefundAttempt(12, 'ticket:34').key).toBe(initial.key)
  })
})
