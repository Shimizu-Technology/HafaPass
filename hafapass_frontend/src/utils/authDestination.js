export function safeReturnPath(value) {
  if (typeof value !== 'string' || !value.startsWith('/') || value.startsWith('//') || /[\\\r\n]/.test(value)) return '/'
  try {
    const url = new URL(value, window.location.origin)
    return url.origin === window.location.origin ? `${url.pathname}${url.search}${url.hash}` : '/'
  } catch {
    return '/'
  }
}

export function signInDestination(location) {
  const destination = `${location.pathname}${location.search}${location.hash}`
  return `/sign-in?returnTo=${encodeURIComponent(destination)}`
}
