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
