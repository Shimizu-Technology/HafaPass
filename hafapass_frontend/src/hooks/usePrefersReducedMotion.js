import { useSyncExternalStore } from 'react'

const QUERY = '(prefers-reduced-motion: reduce)'
const media = () => (typeof window !== 'undefined' && window.matchMedia ? window.matchMedia(QUERY) : null)

function subscribe(callback) {
  const list = media()
  if (!list) return () => {}
  list.addEventListener?.('change', callback)
  return () => list.removeEventListener?.('change', callback)
}

// The visitor's reduced-motion setting, without loading an animation library.
export default function usePrefersReducedMotion() {
  return useSyncExternalStore(subscribe, () => Boolean(media()?.matches), () => false)
}
