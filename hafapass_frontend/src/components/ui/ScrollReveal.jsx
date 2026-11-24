import { useEffect, useRef, useState } from 'react'
import usePrefersReducedMotion from '../../hooks/usePrefersReducedMotion'

function useInViewOnce(ref, disabled) {
  const [inView, setInView] = useState(disabled)
  useEffect(() => {
    if (disabled || inView) return undefined
    const node = ref.current
    if (!node || typeof IntersectionObserver === 'undefined') {
      setInView(true)
      return undefined
    }
    const observer = new IntersectionObserver(
      entries => {
        if (entries.some(entry => entry.isIntersecting)) {
          setInView(true)
          observer.disconnect()
        }
      },
      { rootMargin: '-40px 0px' },
    )
    observer.observe(node)
    return () => observer.disconnect()
  }, [ref, disabled, inView])
  return disabled || inView
}

export const FadeUp = ({ children, delay = 0, className = '' }) => {
  const ref = useRef(null)
  const reducedMotion = usePrefersReducedMotion()
  const settled = useInViewOnce(ref, reducedMotion)
  const delayMs = reducedMotion ? 0 : Math.round(delay * 1000)

  return (
    <div
      ref={ref}
      data-reveal={settled ? 'settled' : 'resting'}
      className={`scroll-reveal ${className}`.trim()}
      style={{
        transitionDelay: delayMs ? `${delayMs}ms` : undefined,
        ...(reducedMotion ? { transform: 'none', transitionDuration: '0ms' } : {}),
      }}
    >
      {children}
    </div>
  )
}

export const StaggerContainer = ({ children, className = '' }) => {
  const ref = useRef(null)
  const reducedMotion = usePrefersReducedMotion()
  const settled = useInViewOnce(ref, reducedMotion)

  return (
    <div
      ref={ref}
      data-reveal={settled ? 'settled' : 'resting'}
      data-reduced-motion={reducedMotion ? 'true' : 'false'}
      className={`scroll-reveal-stagger ${className}`.trim()}
    >
      {children}
    </div>
  )
}

export const StaggerItem = ({ children, className = '' }) => {
  const reducedMotion = usePrefersReducedMotion()
  return (
    <div
      className={`scroll-reveal-item ${className}`.trim()}
      style={reducedMotion ? { transform: 'none', transitionDuration: '0ms', transitionDelay: '0ms' } : undefined}
    >
      {children}
    </div>
  )
}
