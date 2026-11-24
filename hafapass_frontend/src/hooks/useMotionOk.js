import { useEffect, useState } from 'react'
import usePrefersReducedMotion from './usePrefersReducedMotion'

// Below this height (a phone on its side) scroll moments show their still layout.
export const SHORT_SCREEN_PX = 560

// Still-first motion gate for public-page moments. False on the first render,
// so every screen renders its finished state before any script runs; false
// under reduced motion; and, with `shortScreen`, false on short viewports.
export default function useMotionOk({ shortScreen = false } = {}) {
  const reduced = usePrefersReducedMotion()
  const [mounted, setMounted] = useState(false)
  const [tooShort, setTooShort] = useState(false)
  const minHeight = typeof shortScreen === 'number' ? shortScreen : shortScreen ? SHORT_SCREEN_PX : 0
  useEffect(() => {
    setMounted(true)
    if (!minHeight) return undefined
    const check = () => setTooShort(window.innerHeight < minHeight)
    check()
    window.addEventListener('resize', check)
    return () => window.removeEventListener('resize', check)
  }, [minHeight])
  return mounted && !reduced && !(minHeight && tooShort)
}
