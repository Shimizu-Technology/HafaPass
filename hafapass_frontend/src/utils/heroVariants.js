export const HERO_VARIANTS = Object.freeze([
  {
    id: 1,
    shortLabel: 'Original',
    name: 'Original, refined',
    summary: 'Flat featured pass with refined spacing and LCP-safe type',
  },
  {
    id: 2,
    shortLabel: 'Deck',
    name: 'Fanned deck',
    summary: 'Flat 3-card upcoming stack, swipeable with gentle 5s advance',
  },
  {
    id: 3,
    shortLabel: 'Marquee',
    name: 'Event marquee',
    summary: 'Slow continuous ticket marquee with edge fade and Browse CTA',
  },
  {
    id: 4,
    shortLabel: 'Island QR',
    name: 'Island pass & QR',
    summary: 'Calm lagoon glow and one-shot QR tile assembly on the stub',
  },
])

export function parseHeroVariant(raw) {
  const num = Number.parseInt(String(raw ?? ''), 10)
  if (num >= 1 && num <= HERO_VARIANTS.length) return num
  return 1
}
