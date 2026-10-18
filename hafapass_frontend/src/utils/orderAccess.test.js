import { beforeEach, describe, expect, it } from 'vitest'
import { CheckoutAttemptConflict, checkoutDefinitelyRejected, prepareCheckoutAttempt, getCheckoutAttempt, clearCheckoutAttempt, recordCheckoutOutcome, saveActiveCheckout, getActiveCheckout, clearActiveCheckout, getOrderAccess, getBuyerRefundAttempt, prepareBuyerRefundAttempt, recordBuyerRefundOutcome } from './orderAccess'

describe('buyer refund request persistence', () => {
  beforeEach(() => { window.sessionStorage.clear(); window.localStorage.clear() })
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
  it('retains simulated status through a lost response and a later completion', () => {
    prepareBuyerRefundAttempt(12, 'ticket:34')
    recordBuyerRefundOutcome(12, 'ticket:34', { refund_status: 'pending', refund_simulated: true })
    recordBuyerRefundOutcome(12, 'ticket:34', null)
    recordBuyerRefundOutcome(12, 'ticket:34', { refund_status: 'succeeded' })
    expect(getBuyerRefundAttempt(12, 'ticket:34')).toMatchObject({ status: 'succeeded', simulated: true })
  })
  it.each(['failed', 'cancelled', 'succeeded'])('holds a %s operation for finance review without rotating identity until the server explicitly clears review', status => {
    const initial = prepareBuyerRefundAttempt(12, 'ticket:34')
    recordBuyerRefundOutcome(12, 'ticket:34', { refund_status: status, finance_review_required: true, reconciliation_required: true })
    expect(getBuyerRefundAttempt(12, 'ticket:34').status).toBe('finance_review')
    expect(prepareBuyerRefundAttempt(12, 'ticket:34').key).toBe(initial.key)
    recordBuyerRefundOutcome(12, 'ticket:34', null)
    expect(getBuyerRefundAttempt(12, 'ticket:34').status).toBe('finance_review')
    recordBuyerRefundOutcome(12, 'ticket:34', { refund_status: status })
    expect(getBuyerRefundAttempt(12, 'ticket:34').status).toBe('finance_review')
    recordBuyerRefundOutcome(12, 'ticket:34', { refund_status: status, finance_review_required: false, reconciliation_required: false })
    expect(getBuyerRefundAttempt(12, 'ticket:34').status).toBe(status)
    expect(prepareBuyerRefundAttempt(12, 'ticket:34').key === initial.key).toBe(status === 'succeeded')
  })
  it('persists a secret checkout capability before posting and reuses it for an uncertain response', () => {
    const first = prepareCheckoutAttempt('event', { buyer_email: 'buyer@example.invalid' })
    expect(first.payload.checkout_key).toMatch(/^[0-9a-f]{64}$/)
    expect(prepareCheckoutAttempt('event', { buyer_email: 'buyer@example.invalid' })).toEqual(first)
    expect(getCheckoutAttempt('event')).toEqual(first)
    clearCheckoutAttempt('event', first.payload.checkout_key)
    expect(getCheckoutAttempt('event')).toBeNull()
  })

  it('does not overwrite edits or allocate another order identity while the earlier result is unknown', () => {
    const payload = { buyer_email: 'buyer@example.invalid', line_items: [{ quantity: 1, ticket_type_id: 7 }] }
    const first = prepareCheckoutAttempt('event', payload)
    expect(prepareCheckoutAttempt('event', { line_items: [{ ticket_type_id: 7, quantity: 1 }], buyer_email: 'buyer@example.invalid' })).toEqual(first)
    expect(() => prepareCheckoutAttempt('event', { ...payload, buyer_email: 'edited@example.invalid' })).toThrow(CheckoutAttemptConflict)
    expect(() => prepareCheckoutAttempt('event', { ...payload, line_items: [{ ticket_type_id: 7, quantity: 2 }] })).toThrow(CheckoutAttemptConflict)
    expect(() => prepareCheckoutAttempt('event', { ...payload, promo_code_id: 9 })).toThrow(CheckoutAttemptConflict)
    expect(getCheckoutAttempt('event')).toEqual(first)
    clearCheckoutAttempt('event', first.payload.checkout_key)
    const next = prepareCheckoutAttempt('event', { ...payload, buyer_email: 'edited@example.invalid' })
    expect(next.payload.buyer_email).toBe('edited@example.invalid')
    expect(next.payload.checkout_key).not.toBe(first.payload.checkout_key)
  })

  it('fences a late rejection or successful outcome against the exact newer attempt', () => {
    const first = prepareCheckoutAttempt('event', { buyer_email: 'buyer@example.invalid' })
    const newer = { buyerId: null, payload: { checkout_key: 'b'.repeat(64) }, expiresAt: Date.now() + 300000 }
    window.sessionStorage.setItem('hafapass:checkout-attempt:event', JSON.stringify(newer))
    expect(clearCheckoutAttempt('event', first.payload.checkout_key)).toBe(false)
    expect(recordCheckoutOutcome('event', first.payload.checkout_key, null, { id: 9, guest_access_token: 'old-token' })).toBe(false)
    expect(getCheckoutAttempt('event')).toEqual(newer)
    expect(getActiveCheckout('event')).toBeNull()
    expect(getOrderAccess(9)).toBeNull()
    expect(recordCheckoutOutcome('event', newer.payload.checkout_key, null, { id: 10, guest_access_token: 'current-token' })).toBe(true)
    expect(getCheckoutAttempt('event')).toBeNull()
    expect(getActiveCheckout('event')).toBe('10')
    expect(getOrderAccess(10)).toBe('current-token')
  })

  it('preserves recovery identities when the authenticated buyer changes', () => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'buyer-a')
    const attempt = prepareCheckoutAttempt('event', { buyer_email: 'buyer@example.invalid' })
    saveActiveCheckout('another-event', 9)
    window.localStorage.setItem('hafapass_scanner_user_id', 'buyer-b')
    expect(clearCheckoutAttempt('event', attempt.payload.checkout_key, 'buyer-a')).toBe(false)
    expect(() => prepareCheckoutAttempt('event', { buyer_email: 'buyer@example.invalid' })).toThrow(CheckoutAttemptConflict)
    expect(recordCheckoutOutcome('event', attempt.payload.checkout_key, 'buyer-a', { id: 10, guest_access_token: 'old-token' })).toBe(false)
    expect(getCheckoutAttempt('event')).toEqual(attempt)
    expect(getActiveCheckout('another-event')).toBeNull()
    expect(clearActiveCheckout('another-event', 9)).toBe(false)
    window.localStorage.setItem('hafapass_scanner_user_id', 'buyer-a')
    expect(getActiveCheckout('another-event')).toBe('9')
  })

  it('clears only the expected active order and leaves a newer active checkout intact', () => {
    saveActiveCheckout('event', 9)
    saveActiveCheckout('event', 10)
    expect(clearActiveCheckout('event', 9)).toBe(false)
    expect(getActiveCheckout('event')).toBe('10')
    expect(clearActiveCheckout('event', 10)).toBe(true)
    expect(getActiveCheckout('event')).toBeNull()
  })

  it.each([400, 401, 403, 404, 422])('recognizes a definitive no-order %s response', status => {
    expect(checkoutDefinitelyRejected({ response: { status, data: { checkout_recovery_required: false } } })).toBe(true)
  })

  it.each([
    { status: 422, data: {} },
    { status: 422, data: { checkout_recovery_required: true } },
    { status: 422, data: { checkout_recovery_required: false, id: 123 } },
    { status: 422, data: { checkout_recovery_required: false, order_id: 123 } },
    { status: 408, data: { checkout_recovery_required: false } },
    { status: 429, data: { checkout_recovery_required: false } },
    { status: 503, data: {} },
  ])('preserves uncertain or contradictory checkout outcome $status $data', response => {
    expect(checkoutDefinitelyRejected({ response })).toBe(false)
  })
})
