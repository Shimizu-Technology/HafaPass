import { useEffect, useRef } from 'react'
import usePrefersReducedMotion from '../../hooks/usePrefersReducedMotion'

function useEdgeFade(ref, deps = []) {
  useEffect(() => {
    const el = ref.current
    if (!el) return undefined

    const update = () => {
      const maxScroll = el.scrollWidth - el.clientWidth
      if (maxScroll <= 2) {
        delete el.dataset.fadeStart
        delete el.dataset.fadeEnd
        return
      }
      if (el.scrollLeft > 2) el.dataset.fadeStart = ''
      else delete el.dataset.fadeStart
      if (el.scrollLeft < maxScroll - 2) el.dataset.fadeEnd = ''
      else delete el.dataset.fadeEnd
    }

    update()
    el.addEventListener('scroll', update, { passive: true })
    window.addEventListener('resize', update)
    let ro
    if (typeof ResizeObserver !== 'undefined') {
      ro = new ResizeObserver(update)
      ro.observe(el)
    }
    return () => {
      el.removeEventListener('scroll', update)
      window.removeEventListener('resize', update)
      ro?.disconnect()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)
}

/**
 * Single-line horizontally scrollable row of chips or pill actions.
 * Never wraps. Applies dynamic edge fades when content overflows and scrolls
 * the active chip into horizontal view without shifting page vertical scroll.
 */
export default function ChipRow({
  as = 'div',
  role,
  ariaLabel,
  activeKey,
  bleed = 'page',
  className = '',
  children,
  ...rest
}) {
  const rowRef = useRef(null)
  const reducedMotion = usePrefersReducedMotion()
  const Tag = as

  useEdgeFade(rowRef, [activeKey, children])

  useEffect(() => {
    const row = rowRef.current
    if (!row || activeKey === undefined) return
    const active = row.querySelector('[aria-pressed="true"], [aria-current="true"], [data-active="true"]')
    if (!active || typeof row.scrollTo !== 'function') return
    const maxScroll = row.scrollWidth - row.clientWidth
    if (maxScroll <= 2) return
    const targetLeft = Math.max(0, Math.min(maxScroll, active.getBoundingClientRect().left - row.getBoundingClientRect().left + row.scrollLeft - (row.clientWidth - active.offsetWidth) / 2))
    row.scrollTo({ left: targetLeft, behavior: reducedMotion ? 'auto' : 'smooth' })
  }, [activeKey, reducedMotion])

  const bleedClass = bleed === 'none'
    ? 'chip-row-contained'
    : bleed === 'mobile'
      ? 'chip-row-mobile-bleed'
      : ''

  return (
    <Tag
      ref={rowRef}
      role={Tag === 'ul' ? undefined : (role ?? (ariaLabel ? 'group' : undefined))}
      aria-label={ariaLabel}
      data-chip-row="true"
      className={`chip-row ${bleedClass} ${className}`.trim()}
      {...rest}
    >
      {children}
    </Tag>
  )
}

/**
 * Edge-to-edge swipeable event card track on phones, switching to a multi-column
 * grid at 768px+. Shares the ChipRow edge-fade indicator on scrollable screens.
 */
export function EventTrack({ ariaLabel, className = '', children, ...rest }) {
  const trackRef = useRef(null)
  useEdgeFade(trackRef, [children])
  return (
    <ul ref={trackRef} aria-label={ariaLabel} className={`event-track ${className}`.trim()} {...rest}>
      {children}
    </ul>
  )
}
