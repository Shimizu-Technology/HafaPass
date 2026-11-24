export const DEFAULT_BRAND_VARIANT = 2

export const BRAND_VARIANTS = Object.freeze([
  {
    id: 1,
    shortLabel: 'Poster',
    name: 'Poster',
    summary: 'Event-poster grid with HåfaPass pill, two-line display headline, and ring motif',
  },
  {
    id: 2,
    shortLabel: 'Mark',
    name: 'Brand mark',
    summary: 'Centered HåfaPass emblem and wordmark over fine guilloché security linework',
  },
  {
    id: 3,
    shortLabel: 'Guam',
    name: 'Guam',
    summary: 'Sunset-over-lagoon glow with minimal Chamorro latte-stone silhouette and poster title',
  },
])

export function parseBrandVariant(raw) {
  const num = Number.parseInt(String(raw ?? ''), 10)
  if (num >= 1 && num <= BRAND_VARIANTS.length) return num
  return DEFAULT_BRAND_VARIANT
}
