import i18next from 'i18next'

// Kept apart from the axios client so pages can use these helpers while
// tests replace the client itself.

// A stalled request on venue Wi-Fi or a weak signal must end with a message,
// not a spinner. File downloads (CSV, PDF, wallet passes) get longer.
export const DEFAULT_TIMEOUT_MS = 20_000
export const DOWNLOAD_TIMEOUT_MS = 60_000
// Order and payment writes without an idempotency key wait longer: giving up
// early leaves the buyer unsure whether the action happened.
export const SLOW_WRITE_TIMEOUT_MS = 45_000
// File uploads sent through the API (FormData bodies) can take minutes on a
// weak signal.
export const UPLOAD_TIMEOUT_MS = 120_000

export const isTimeoutError = error => Boolean(error?.isTimeout)
export const slowConnectionMessage = () => i18next.t('common.slowConnection')
// The server's own explanation first, then the slow-connection notice, then the caller's fallback.
export function apiErrorMessage(error, fallback) {
  return error?.response?.data?.error || (isTimeoutError(error) ? slowConnectionMessage() : fallback)
}
