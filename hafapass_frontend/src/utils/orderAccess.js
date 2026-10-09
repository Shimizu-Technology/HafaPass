const accessKey = (orderId) => `hafapass:order-access:${orderId}`
const activeCheckoutKey = (slug) => `hafapass:active-checkout:${slug}`

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
}

export function getActiveCheckout(slug) {
  if (!slug) return null
  return window.sessionStorage.getItem(activeCheckoutKey(slug))
}

export function clearActiveCheckout(slug) {
  if (!slug) return
  window.sessionStorage.removeItem(activeCheckoutKey(slug))
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
  const updated = { ...attempt, status }
  window.sessionStorage.setItem(buyerRefundStorageKey(orderId, operation), JSON.stringify(updated))
  return updated
}
