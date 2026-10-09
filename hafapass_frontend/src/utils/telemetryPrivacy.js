export function monitoringPath(url) {
  if (typeof url !== 'string') return url
  return url.split(/[?#]/)[0]
    .replace(/(\/tickets\/)[^/]+/gi, '$1:id')
    .replace(/(\/ticket-transfers\/)(?!accept(?:\/|$))[^/]+/gi, '$1:id')
    .replace(/(\/organization-invitations\/)(?!accept(?:\/|$))[^/]+/gi, '$1:id')
    .replace(/\/[0-9a-f-]{8,}/gi, '/:id')
    .replace(/\/\d+/g, '/:id')
}

export function scrubTelemetry(value, key = '') {
  if (/authorization|cookie|token|credential|password|email|body|request_body/i.test(key)) return '[redacted]'
  if (Array.isArray(value)) return value.map(item => scrubTelemetry(item))
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([name, item]) => [name, scrubTelemetry(item, name)]))
  if (typeof value === 'string') {
    if (/url|href|from|to|path|filename|transaction/i.test(key)) return monitoringPath(value)
    return value.replace(/(?:https?:\/\/[^\s]*\/tickets\/|\/tickets\/)[^\s/]+/gi, '/tickets/:id')
  }
  return value
}
