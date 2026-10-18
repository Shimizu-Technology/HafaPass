const accessKey = (orderId) => `hafapass:order-access:${orderId}`
const activeCheckoutKey = (slug) => `hafapass:active-checkout:${slug}`
const activeCheckoutBuyerKey = slug => `hafapass:active-checkout-buyer:${slug}`

export function checkoutBuyerIdentity() {
  // Written by ClerkProviderWrapper only after binding the authenticated user.
  return window.localStorage.getItem('hafapass_scanner_user_id')
}

export function saveOrderAccess(orderId, token) {
  if (!orderId || !token) return
  window.sessionStorage.setItem(accessKey(orderId), token)
}

export function getOrderAccess(orderId) {
  if (!orderId) return null
  return window.sessionStorage.getItem(accessKey(orderId))
}

export function orderAccessHeaders(orderId, token = getOrderAccess(orderId)) {
  return token ? { 'X-Guest-Order-Token': token } : {}
}

export function saveActiveCheckout(slug, orderId) {
  if (!slug || !orderId) return
  window.sessionStorage.setItem(activeCheckoutKey(slug), String(orderId))
  window.sessionStorage.setItem(activeCheckoutBuyerKey(slug), JSON.stringify(checkoutBuyerIdentity()))
}

export function getActiveCheckout(slug) {
  if (!slug) return null
  const buyer = window.sessionStorage.getItem(activeCheckoutBuyerKey(slug))
  if (buyer !== null && buyer !== JSON.stringify(checkoutBuyerIdentity())) return null
  return window.sessionStorage.getItem(activeCheckoutKey(slug))
}

export function activeCheckoutBuyerBound(slug) {
  return window.sessionStorage.getItem(activeCheckoutBuyerKey(slug)) !== null
}

export function clearActiveCheckout(slug, expectedOrderId) {
  if (!slug || !expectedOrderId || getActiveCheckout(slug) !== String(expectedOrderId)) return false
  window.sessionStorage.removeItem(activeCheckoutKey(slug))
  window.sessionStorage.removeItem(activeCheckoutBuyerKey(slug))
  return true
}

export function checkoutBuyerMatches(slug) {
  const attempt = getCheckoutAttempt(slug)
  if (attempt && Object.hasOwn(attempt, 'buyerId') && attempt.buyerId !== checkoutBuyerIdentity()) return false
  return !window.sessionStorage.getItem(activeCheckoutKey(slug)) || getActiveCheckout(slug) !== null
}

const buyerRefundStorageKey = (orderId, operation) => `hafapass:buyer-refund:${orderId}:${operation}`
const terminalFailedRefunds = new Set(['failed', 'cancelled'])

export function getBuyerRefundAttempt(orderId, operation) {
  try {
    const attempt = JSON.parse(window.sessionStorage.getItem(buyerRefundStorageKey(orderId, operation)) || 'null')
    return typeof attempt?.key === 'string' ? attempt : null
  } catch { return null }
}

export function prepareBuyerRefundAttempt(orderId, operation) {
  const previous = getBuyerRefundAttempt(orderId, operation)
  const [kind, resourceId] = operation.split(':')
  const originalKey = `${kind === 'ticket' ? 'buyer-ticket-cancel' : 'buyer-event-refund'}:${orderId}:${resourceId}`
  // Keep the original deterministic key compatible with requests made before persistence.
  // Only an explicit next click after a definitive failure starts a new provider operation.
  const attempt = previous && !terminalFailedRefunds.has(previous.status)
    ? previous
    : { key: previous ? `${originalKey}:${crypto.randomUUID()}` : originalKey, status: 'unconfirmed' }
  window.sessionStorage.setItem(buyerRefundStorageKey(orderId, operation), JSON.stringify(attempt))
  return attempt
}

export function recordBuyerRefundOutcome(orderId, operation, data = {}) {
  const attempt = getBuyerRefundAttempt(orderId, operation)
  if (!attempt) return null
  const outcome = data || {}
  const reported = outcome.refund_status === 'canceled' ? 'cancelled' : outcome.refund_status
  const financeReview = outcome.finance_review_required === true || (attempt.status === 'finance_review' && outcome.finance_review_required !== false)
  const status = financeReview ? 'finance_review'
    : outcome.reconciliation_required ? 'pending'
    : ['succeeded', 'failed', 'cancelled', 'pending'].includes(reported) ? reported
      : outcome.error && outcome.reconciliation_required === false ? 'rejected' : 'unconfirmed'
  const updated = { ...attempt, status, simulated: outcome.refund_simulated === true || attempt.simulated === true }
  window.sessionStorage.setItem(buyerRefundStorageKey(orderId, operation), JSON.stringify(updated))
  return updated
}

const checkoutAttemptKey = slug => `hafapass:checkout-attempt:${slug}`
export class CheckoutAttemptConflict extends Error {
  constructor() {
    super('An earlier checkout is still unconfirmed. Recover it before changing your order.')
    this.name = 'CheckoutAttemptConflict'
  }
}

function canonicalPayload(value) {
  if (Array.isArray(value)) return value.map(canonicalPayload)
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonicalPayload(value[key])]))
  return value
}

function checkoutPayloadIdentity(payload) {
  const request = { ...payload }
  delete request.checkout_key
  return JSON.stringify(canonicalPayload(request))
}

export function checkoutDefinitelyRejected(error) {
  const data = error.response?.data
  // A 4xx replay may reject changed terms before checking an existing order.
  // Status alone cannot establish that the earlier request created no order.
  return data?.checkout_recovery_required === false && !data.id && !data.order_id && !data.order?.id
    && ![408, 429].includes(error.response?.status)
}

export function getCheckoutAttempt(slug) {
  try {
    const attempt = JSON.parse(window.sessionStorage.getItem(checkoutAttemptKey(slug)) || 'null')
    if (!attempt || attempt.expiresAt <= Date.now()) {
      window.sessionStorage.removeItem(checkoutAttemptKey(slug))
      return null
    }
    return attempt
  } catch { return null }
}
export function prepareCheckoutAttempt(slug, payload) {
  if (!checkoutBuyerMatches(slug)) throw new CheckoutAttemptConflict()
  const previous = getCheckoutAttempt(slug)
  if (previous) {
    if (checkoutPayloadIdentity(previous.payload) !== checkoutPayloadIdentity(payload)) throw new CheckoutAttemptConflict()
    return previous
  }
  const bytes = crypto.getRandomValues(new Uint8Array(32))
  const key = Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('')
  const attempt = { buyerId: checkoutBuyerIdentity(), payload: { ...payload, checkout_key: key }, expiresAt: Date.now() + 30 * 60 * 1000 }
  // Fail before posting if persistence is unavailable: a lost response must be recoverable.
  window.sessionStorage.setItem(checkoutAttemptKey(slug), JSON.stringify(attempt))
  return attempt
}
export function checkoutAttemptCurrent(slug, expectedKey, expectedBuyerId = checkoutBuyerIdentity()) {
  if (!expectedKey || checkoutBuyerIdentity() !== expectedBuyerId) return false
  try {
    const attempt = JSON.parse(window.sessionStorage.getItem(checkoutAttemptKey(slug)) || 'null')
    return attempt?.payload?.checkout_key === expectedKey
      && (!Object.hasOwn(attempt, 'buyerId') || attempt.buyerId === expectedBuyerId)
  } catch { return false }
}

export function clearCheckoutAttempt(slug, expectedKey, expectedBuyerId = checkoutBuyerIdentity()) {
  if (!checkoutAttemptCurrent(slug, expectedKey, expectedBuyerId)) return false
  window.sessionStorage.removeItem(checkoutAttemptKey(slug))
  return true
}

export function recordCheckoutOutcome(slug, attemptKey, buyerId, order) {
  if (!order?.id || !checkoutAttemptCurrent(slug, attemptKey, buyerId)) return false
  saveOrderAccess(order.id, order.guest_access_token)
  saveActiveCheckout(slug, order.id)
  return clearCheckoutAttempt(slug, attemptKey, buyerId)
}
