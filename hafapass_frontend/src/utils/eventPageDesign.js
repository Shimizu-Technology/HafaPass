export const SECTION_TYPES = ['lineup', 'schedule', 'faq', 'sponsors', 'video', 'links', 'gallery']
export const ACCENT_PRESETS = [
  '#087e82',
  '#185e96',
  '#5b4aa2',
  '#a62461',
  '#ad392d',
  '#845913',
  '#315f37',
  '#30435c',
  '#6b367c',
]
export const defaultDesign = () => ({
  sections: SECTION_TYPES.map((type) => ({
    type,
    enabled: false,
    ...(type === 'video' ? { url: '' } : { items: [] }),
  })),
  gallery: [],
})

const channel = (value) => {
  const s = value / 255
  return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4
}
const rgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16))
const luminance = (values) =>
  values.reduce((total, value, i) => total + channel(value) * [0.2126, 0.7152, 0.0722][i], 0)
const hex = (values) => `#${values.map((value) => Math.round(value).toString(16).padStart(2, '0')).join('')}`
export function accentStyle(value) {
  if (!/^#[\da-fA-F]{6}$/.test(value || '')) return undefined
  const values = rgb(value)
  const light = luminance(values)
  const onAccent = 1.05 / (light + 0.05) >= 4.5 ? '#ffffff' : '#000000'
  let link = values
  // A 4.5:1 link against the white page is guaranteed, even for pastel presets.
  for (let i = 0; i < 32 && 1.05 / (luminance(link) + 0.05) < 4.5; i++) link = link.map((v) => v * 0.9)
  return { '--event-accent': value, '--event-on-accent': onAccent, '--event-link': hex(link) }
}
export const focalPosition = (design) => `${design?.focal_point?.x ?? 50}% ${design?.focal_point?.y ?? 50}%`
export function safeLink(value) {
  try {
    const url = new URL(value)
    return ['https:', 'mailto:'].includes(url.protocol) ? url.href : null
  } catch {
    return null
  }
}
export function videoEmbed(value) {
  try {
    const url = new URL(value)
    if (url.protocol !== 'https:') return null
    if (
      ['youtube.com', 'www.youtube.com'].includes(url.hostname) &&
      url.pathname === '/watch' &&
      /^[\w-]{11}$/.test(url.searchParams.get('v') || '')
    )
      return `https://www.youtube-nocookie.com/embed/${url.searchParams.get('v')}`
    if (['youtu.be', 'www.youtu.be'].includes(url.hostname) && /^\/[\w-]{11}\/?$/.test(url.pathname))
      return `https://www.youtube-nocookie.com/embed/${url.pathname.split('/')[1]}`
    if (['vimeo.com', 'www.vimeo.com'].includes(url.hostname) && /^\/\d+\/?$/.test(url.pathname))
      return `https://player.vimeo.com/video/${url.pathname.split('/')[1]}?dnt=1`
  } catch {
    return null
  }
  return null
}
