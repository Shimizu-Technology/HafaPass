// Only the public event listing can be a return target for this action.
export function eventBrowseReturn(value) {
  if (typeof value !== 'string' || !value.startsWith('/events') || value.startsWith('//')) return '/events'
  try {
    const url = new URL(value, 'https://hafapass.invalid')
    return url.origin === 'https://hafapass.invalid' && url.pathname === '/events'
      ? `${url.pathname}${url.search}` : '/events'
  } catch { return '/events' }
}
