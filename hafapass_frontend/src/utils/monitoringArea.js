// The same `area` tag the API puts on its Sentry events (MonitoringArea), derived
// from the page path, so one Sentry alert rule can watch checkout, scanner and
// box-office errors in both projects. Only the path *shape* is read; nothing
// from the URL is sent.
export function monitoringAreaForPath(pathname = '') {
  const path = String(pathname || '').split(/[?#]/, 1)[0]
  if (/^\/(?:checkout|orders)(?:\/|$)/.test(path)) return 'checkout'
  if (/^\/dashboard\/scanner(?:\/|$)/.test(path)) return 'scanner'
  if (/^\/dashboard\/events\/[^/]+\/box-office(?:\/|$)/.test(path)) return 'box_office'
  return null
}
