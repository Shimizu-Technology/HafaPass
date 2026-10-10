const DEFAULT_SUPPORT_EMAIL = 'shimizutechnology@gmail.com'

export function supportMailto(subject = 'HafaPass Support') {
  const email = import.meta.env.VITE_SUPPORT_EMAIL?.trim() || DEFAULT_SUPPORT_EMAIL
  const recipient = encodeURIComponent(email).replace(/%40/g, '@')
  return `mailto:${recipient}?subject=${encodeURIComponent(subject)}`
}
