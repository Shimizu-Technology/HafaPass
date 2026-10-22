// The public site URL is configuration (VITE_PUBLIC_WEB_URL); without it the
// site's own origin is used, so links never point at a domain HåfaPass doesn't own.
export function resolvePublicWebUrl(configured = import.meta.env.VITE_PUBLIC_WEB_URL, origin = globalThis.location?.origin) {
  return (String(configured || '').trim() || origin || '').replace(/\/+$/, '')
}

export const PUBLIC_WEB_URL = resolvePublicWebUrl()
