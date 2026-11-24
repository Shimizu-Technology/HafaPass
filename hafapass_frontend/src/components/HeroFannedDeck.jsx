import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ArrowRight, Calendar, ChevronLeft, ChevronRight, MapPin, Pause, Play } from 'lucide-react'
import BrandTicketCover from './BrandTicketCover'
import { TicketTop, TicketStub } from './Ticket'
import usePrefersReducedMotion from '../hooks/usePrefersReducedMotion'
import useTranslatedContent from '../hooks/useTranslatedContent'
import { approvedImageUrl, focalPosition } from '../utils/eventPageDesign'
import { formatEventDate, formatEventTime } from '../utils/eventTime'
import { formatTicketPrice, priceSummary, remainingTickets } from '../utils/ticketPricing'

const AUTO_ADVANCE_MS = 6000
const GLIDE_MS = 620
const GLIDE_EASE = 'cubic-bezier(0.22, 1, 0.36, 1)'
const AXIS_LOCK_PX = 8
const SWIPE_DISTANCE_PX = 64
const SWIPE_VELOCITY_PX_MS = 0.32
const SWIPE_MIN_FLICK_PX = 20

// Deterministic 15x15 static decorative QR motif for the HåfaPass brand pass.
const BRAND_QR_PATH = (() => {
  const size = 15
  let d = ''
  const inFinder = (x, y) => [[0, 0], [10, 0], [0, 10]].find(([fx, fy]) => x >= fx && x < fx + 5 && y >= fy && y < fy + 5)
  for (let y = 0; y < size; y += 1) {
    for (let x = 0; x < size; x += 1) {
      const f = inFinder(x, y)
      const on = f
        ? (x - f[0] === 0 || y - f[1] === 0 || x - f[0] === 4 || y - f[1] === 4 || (x - f[0] === 2 && y - f[1] === 2))
        : ((x * 5 + y * 11 + x * y) % 5 < 2)
      if (on) d += `M${x} ${y}h1v1h-1z`
    }
  }
  return d
})()

function stackTransform(depth) {
  if (depth === 0) return 'translate3d(0px, 0px, 0px) scale(1)'
  if (depth === 1) return 'translate3d(0px, 12px, 0px) scale(0.915)'
  return 'translate3d(0px, 22px, 0px) scale(0.84)'
}

function stackOpacity(depth) {
  if (depth <= 2) return 1
  return 0
}

function BrandDefaultTicketFace() {
  const { t } = useTranslation()

  return (
    <div
      className="ticket featured-ticket flex h-full flex-col text-content"
      data-testid="hero-brand-card"
      data-brand-variant="1"
    >
      <TicketTop>
        <BrandTicketCover  />
        <div className="px-5 pb-4 pt-4 sm:px-6">
          <p className="text-xs font-semibold uppercase tracking-[0.08em] text-brand-800">
            {t('pass.home.brandCardKicker')}
          </p>
          <p className="mt-1 line-clamp-2 min-h-[2.85rem] font-display text-[1.25rem] font-bold leading-[1.18] tracking-[-0.02em] text-neutral-950 sm:min-h-[3.2rem] sm:text-[1.4rem]">
            {t('pass.home.brandCardHeadline')}
          </p>
        </div>
      </TicketTop>
      <TicketStub className="flex flex-1 flex-col justify-between">
        <div className="flex flex-1 flex-col justify-between gap-3 px-5 pb-5 pt-4 text-sm text-neutral-800 sm:px-6">
          <div className="flex items-center gap-3.5">
            <div
              aria-hidden="true"
              className="flex h-12 w-12 shrink-0 items-center justify-center rounded-xl border border-neutral-200 bg-neutral-50 p-1.5"
            >
              <svg viewBox="-1 -1 17 17" shapeRendering="crispEdges" className="h-full w-full">
                <path d={BRAND_QR_PATH} fill="#0f172a" />
              </svg>
            </div>
            <div className="min-w-0 space-y-0.5">
              <p className="truncate font-semibold text-neutral-950">{t('pass.home.instantTickets')}</p>
              <p className="truncate text-xs text-content-muted">{t('pass.home.emailDelivery')}</p>
            </div>
          </div>
          <div className="mt-auto flex items-center justify-between gap-3 pt-1">
            <div className="min-h-[2.75rem] flex flex-col justify-center">
              <p className="font-display text-base font-bold leading-tight text-neutral-950 sm:text-lg">
                {t('pass.home.islandWide')}
              </p>
              <p className="font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-content-muted">
                {t('pass.home.admitOne')}
              </p>
            </div>
            <span className="inline-flex min-h-11 shrink-0 items-center gap-1.5 rounded-xl bg-action px-4 text-sm font-semibold text-white">
              {t('buyer.Home.browseEvents')}
              <ArrowRight aria-hidden="true" className="h-4 w-4 shrink-0" />
            </span>
          </div>
        </div>
      </TicketStub>
    </div>
  )
}

function EventDeckTicketFace({ event, isFront, showFace }) {
  const { t } = useTranslation()
  const content = useTranslatedContent(event)
  const [failedArtwork, setFailedArtwork] = useState(null)
  const hasArtwork = approvedImageUrl(event.cover_image_url, event.image_asset_host) && failedArtwork !== event.cover_image_url
  const summary = priceSummary(event.ticket_types)
  const hasInventory = !event.ticket_types || event.ticket_types.some(ticket => remainingTickets(ticket) === null || remainingTickets(ticket) > 0)
  const place = [event.venue_name, event.venue_city].filter(Boolean).join(' · ')

  return (
    <div
      className="ticket featured-ticket flex h-full flex-col text-content"
      style={{ visibility: showFace ? 'visible' : 'hidden' }}
    >
      <TicketTop>
        <div className="relative aspect-video overflow-hidden bg-brand-800">
          {hasArtwork ? (
            <img
              src={event.cover_image_url}
              alt=""
              width="1600"
              height="900"
              fetchpriority={isFront ? 'high' : undefined}
              draggable={false}
              onError={() => setFailedArtwork(event.cover_image_url)}
              className="h-full w-full object-cover"
              style={{ objectPosition: focalPosition(event.page_customization) }}
            />
          ) : (
            <div aria-hidden="true" className="flex h-full flex-col items-start justify-end p-6 text-white">
              <span className="font-display text-sm font-semibold uppercase tracking-[0.16em] text-brand-200">
                {formatEventDate(event.starts_at, event.timezone, { month: 'short', day: undefined, year: undefined })}
              </span>
              <span className="font-display text-5xl font-bold leading-none">
                {formatEventDate(event.starts_at, event.timezone, { month: undefined, day: 'numeric', year: undefined })}
              </span>
            </div>
          )}
        </div>
        <div className="px-5 pb-4 pt-4 sm:px-6">
          <p className="text-xs font-semibold uppercase tracking-[0.08em] text-brand-800">
            {event.is_featured ? t('pass.home.featuredOnGuam') : t('pass.home.nextUpOnGuam')}
          </p>
          <p className="mt-1 line-clamp-2 min-h-[2.85rem] font-display text-[1.25rem] font-bold leading-[1.18] tracking-[-0.02em] text-neutral-950 [overflow-wrap:anywhere] sm:min-h-[3.2rem] sm:text-[1.4rem]">
            {content.title}
          </p>
        </div>
      </TicketTop>
      <TicketStub className="flex flex-1 flex-col justify-between">
        <div className="flex flex-1 flex-col justify-between gap-3 px-5 pb-5 pt-4 text-sm text-neutral-800 sm:px-6">
          <div className="grid gap-1.5">
            <p className="flex items-start gap-2">
              <Calendar aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-brand-700" />
              <span className="truncate">
                {formatEventDate(event.starts_at, event.timezone, { weekday: 'short', year: undefined })} · {formatEventTime(event.starts_at, event.timezone)}
              </span>
            </p>
            <p className="flex items-start gap-2">
              <MapPin aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-brand-700" />
              <span className="min-w-0 truncate">{place || 'Guam'}</span>
            </p>
          </div>
          <div className="mt-auto flex items-center justify-between gap-3 pt-1">
            <div className="min-h-[2.75rem] flex flex-col justify-center">
              {!summary ? (
                <span className="text-sm font-semibold text-neutral-600">
                  {hasInventory ? t('events.salesUnavailable') : t('events.soldOut')}
                </span>
              ) : (
                <>
                  <p className="font-display text-lg font-bold tabular-nums text-neutral-950 sm:text-xl">
                    {summary.kind === 'free' ? (
                      <span>{t('events.free')}</span>
                    ) : (
                      <>
                        <span className="text-xs font-semibold text-neutral-700 sm:text-sm">{t('events.from')}</span>{' '}
                        <span>{formatTicketPrice(summary.cents)}</span>
                      </>
                    )}
                  </p>
                  {summary.kind === 'from' && summary.hasFree && (
                    <p className="text-xs text-content-muted">{t('events.freeTicketsAvailable')}</p>
                  )}
                </>
              )}
            </div>
            <span className="inline-flex min-h-11 shrink-0 items-center gap-1.5 rounded-xl bg-action px-4 text-sm font-semibold text-white">
              {t('pass.home.seeTickets')}
              <ArrowRight aria-hidden="true" className="h-4 w-4 shrink-0" />
            </span>
          </div>
        </div>
      </TicketStub>
    </div>
  )
}

/**
 * Hero Deck: Always leads with the branded HåfaPass default ticket, followed by
 * up to 3 featured upcoming Guam events. All cards share identical height and
 * ticket anatomy. Uses composite-only transform/opacity transitions (620ms
 * soft ease-out glide), 1:1 pointer swipe with 8px axis lock and velocity-aware
 * momentum, and 6s auto-advance paused on touch, hover, focus, hidden tab, or
 * offscreen. Reduced motion disables auto-advance and swaps cards instantly.
 */
export default function HeroFannedDeck({ events = [], loading = false }) {
  const { t } = useTranslation()
  const location = useLocation()
  const reducedMotion = usePrefersReducedMotion()

  const cards = useMemo(() => {
    const featured = Array.isArray(events) ? events.slice(0, 3) : []
    return [
      { kind: 'brand', id: 'hafapass-default', label: t('pass.home.brandPassLabel') },
      ...featured.map(event => ({
        kind: 'event',
        id: `event-${event.id ?? event.slug}`,
        label: event.title || t('pass.home.featuredEventLabel'),
        event,
      })),
    ]
  }, [events, t])

  const count = cards.length
  const cardSetKey = cards.map(card => card.id).join('|')
  const showStack = loading || count > 1
  const isSkeleton = loading && count <= 1
  const [activeIndex, setActiveIndex] = useState(0)
  const [exiting, setExiting] = useState(null)
  const [hoverPaused, setHoverPaused] = useState(false)
  const [focusPaused, setFocusPaused] = useState(false)
  const [touchPaused, setTouchPaused] = useState(false)
  const [tabHidden, setTabHidden] = useState(() => (typeof document !== 'undefined' ? document.hidden : false))
  const [offscreen, setOffscreen] = useState(false)
  const [dragging, setDragging] = useState(false)

  const rootRef = useRef(null)
  const cardRefs = useRef([])
  const activeIndexRef = useRef(0)
  const exitingRef = useRef(null)
  const dragState = useRef(null)
  const swallowClickRef = useRef(false)
  const lastInteractionWasPointerRef = useRef(false)
  const exitSeqRef = useRef(0)
  const countRef = useRef(count)
  countRef.current = count
  const exitFrameRef = useRef(null)
  const keyboardFocusRef = useRef(null)
  const [rotationStopped, setRotationStopped] = useState(false)
  const exitTimerRef = useRef(null)
  const exitSettleTimerRef = useRef(null)
  const exitAnimsRef = useRef([])
  const touchResumeTimerRef = useRef(null)
  const snapBackTimerRef = useRef(null)

  const safeIndex = count > 0 ? activeIndex % count : 0
  activeIndexRef.current = safeIndex
  exitingRef.current = exiting

  const isPaused = rotationStopped || reducedMotion || hoverPaused || focusPaused || touchPaused || tabHidden || offscreen || dragging || count < 2

  const restoreCardNode = useCallback((node, idx, activeIdx, total) => {
    if (!node || !node.isConnected) return
    const depth = (idx - activeIdx + total) % total
    const isFront = depth === 0
    node.style.transition = ''
    node.style.transform = stackTransform(depth)
    node.style.opacity = String(stackOpacity(depth))
    node.style.zIndex = String(isFront ? Math.max(total + 1, 4) : total - depth)
    const veil = node.querySelector('.hero-deck-back-veil')
    if (veil) {
      veil.style.transition = ''
      veil.style.opacity = isFront ? '0' : '1'
    }
    const face = node.querySelector('.ticket')
    if (face) face.style.visibility = isFront ? 'visible' : 'hidden'
  }, [])

  const pauseForPointer = useCallback(() => {
    if (touchResumeTimerRef.current) {
      window.clearTimeout(touchResumeTimerRef.current)
      touchResumeTimerRef.current = null
    }
    setTouchPaused(true)
    touchResumeTimerRef.current = window.setTimeout(() => {
      touchResumeTimerRef.current = null
      setTouchPaused(false)
    }, AUTO_ADVANCE_MS)
  }, [])

  const clearExitAnimation = useCallback(() => {
    if (exitFrameRef.current) cancelAnimationFrame(exitFrameRef.current)
    exitFrameRef.current = null
    if (exitTimerRef.current) {
      window.clearTimeout(exitTimerRef.current)
      exitTimerRef.current = null
    }
    if (exitSettleTimerRef.current) {
      window.clearTimeout(exitSettleTimerRef.current)
      exitSettleTimerRef.current = null
    }
    if (exitAnimsRef.current.length > 0) {
      exitAnimsRef.current.forEach(anim => {
        try { anim.cancel() } catch { /* ignore */ }
      })
      exitAnimsRef.current = []
    }
    const prevExiting = exitingRef.current
    if (prevExiting) {
      const prevNode = cardRefs.current[prevExiting.index]
      if (prevNode && prevNode.isConnected) {
        restoreCardNode(prevNode, prevExiting.index, activeIndexRef.current, countRef.current)
      }
    }
  }, [restoreCardNode])

  // Reconcile imperative gesture styles with the selected card before paint.
  useLayoutEffect(() => {
    if (dragging) return
    cardRefs.current.forEach((node, idx) => {
      if (idx !== exiting?.index) restoreCardNode(node, idx, safeIndex, count)
    })
    if (keyboardFocusRef.current) {
      const target = keyboardFocusRef.current === 'link'
        ? cardRefs.current[safeIndex]?.querySelector('a')
        : rootRef.current?.querySelectorAll('[data-slide-selector]')[safeIndex]
      target?.focus({ preventScroll: true })
      keyboardFocusRef.current = null
    }
  }, [safeIndex, count, exiting, dragging, restoreCardNode])

  useLayoutEffect(() => {
    clearExitAnimation()
    setExiting(null)
    setActiveIndex(0)
    dragState.current = null
    setDragging(false)
  }, [cardSetKey, clearExitAnimation])

  // Cleanup timers and animations on unmount.
  useEffect(() => () => {
    clearExitAnimation()
    if (touchResumeTimerRef.current) window.clearTimeout(touchResumeTimerRef.current)
    if (snapBackTimerRef.current) window.clearTimeout(snapBackTimerRef.current)
  }, [clearExitAnimation])

  // Distinguish keyboard navigation into the deck from pointer taps/clicks.
  useEffect(() => {
    if (typeof window === 'undefined') return undefined
    const onGlobalKeyDown = event => {
      if (event.key === 'Tab' || event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
        lastInteractionWasPointerRef.current = false
      }
    }
    window.addEventListener('keydown', onGlobalKeyDown, true)
    return () => window.removeEventListener('keydown', onGlobalKeyDown, true)
  }, [])

  // Pause auto-advance when tab is hidden.
  useEffect(() => {
    if (typeof document === 'undefined') return undefined
    const onVisibility = () => setTabHidden(document.hidden)
    document.addEventListener('visibilitychange', onVisibility)
    return () => document.removeEventListener('visibilitychange', onVisibility)
  }, [])

  // Pause auto-advance when hero deck scrolls offscreen.
  useEffect(() => {
    const node = rootRef.current
    if (!node || typeof IntersectionObserver !== 'function') return undefined
    const observer = new IntersectionObserver(
      entries => {
        const entry = entries[0]
        if (entry) setOffscreen(!entry.isIntersecting)
      },
      { threshold: 0.25 },
    )
    observer.observe(node)
    return () => observer.disconnect()
  }, [])

  const transitionTo = useCallback((targetIndex, { direction = -1, startX = 0, durationMs = GLIDE_MS } = {}) => {
    if (count < 2) return
    const next = ((targetIndex % count) + count) % count
    const current = activeIndexRef.current
    if (next === current) return

    clearExitAnimation()

    if (reducedMotion) {
      setExiting(null)
      setActiveIndex(next)
      return
    }

    // Clear only lingering inline transition overrides on non-exiting cards so
    // React's target transform/opacity/veil values animate cleanly.
    cardRefs.current.forEach((el, idx) => {
      if (!el || idx === current) return
      el.style.transition = ''
      const veil = el.querySelector('.hero-deck-back-veil')
      if (veil) veil.style.transition = ''
    })

    exitSeqRef.current += 1
    setExiting({
      index: current,
      direction,
      startX,
      durationMs,
      key: exitSeqRef.current,
    })
    setActiveIndex(next)
  }, [clearExitAnimation, count, reducedMotion])

  const step = useCallback((delta, options = {}) => {
    if (count < 2) return
    const direction = delta > 0 ? -1 : 1
    transitionTo(activeIndexRef.current + delta, { direction, ...options })
  }, [count, transitionTo])

  const goTo = useCallback(index => {
    if (count < 2) return
    const current = activeIndexRef.current
    const target = ((index % count) + count) % count
    if (target === current) return
    const direction = target > current ? -1 : 1
    transitionTo(target, { direction })
  }, [count, transitionTo])

  // Drive the outgoing card's smooth composite-only glide via WAAPI.
  // Transform glides out over the full duration while opacity holds at 1 until
  // 60% of the glide (when the card has cleared the stack), preventing ghosting.
  useLayoutEffect(() => {
    if (!exiting) return undefined
    const el = cardRefs.current[exiting.index]
    if (!el) return undefined

    el.style.transition = 'none'
    el.style.transform = stackTransform(0)
    el.style.opacity = '1'
    const face = el.querySelector('.ticket')
    if (face) face.style.visibility = 'visible'

    const fromTransform = `translate3d(${exiting.startX}px, 0px, 0px) scale(1)`
    const toTransform = `translate3d(${exiting.direction * 108}%, -6px, 0px) scale(0.96)`

    if (typeof el.animate === 'function') {
      const transformAnim = el.animate(
        [
          { transform: fromTransform },
          { transform: toTransform },
        ],
        {
          duration: exiting.durationMs,
          easing: GLIDE_EASE,
          fill: 'forwards',
        },
      )
      const opacityAnim = el.animate(
        [
          { opacity: 1 },
          { opacity: 1, offset: 0.6 },
          { opacity: 0 },
        ],
        {
          duration: exiting.durationMs,
          easing: 'linear',
          fill: 'forwards',
        },
      )
      exitAnimsRef.current = [transformAnim, opacityAnim]
    }

    exitTimerRef.current = window.setTimeout(() => {
      exitAnimsRef.current.forEach(anim => {
        try { anim.cancel() } catch { /* ignore */ }
      })
      exitAnimsRef.current = []

      if (el && el.isConnected) {
        const newDepth = (exiting.index - activeIndexRef.current + count) % count
        const targetOpacity = stackOpacity(newDepth)
        const veil = el.querySelector('.hero-deck-back-veil')
        el.style.transition = 'none'
        el.style.transform = stackTransform(newDepth)
        el.style.zIndex = String(newDepth === 0 ? count + 1 : count - newDepth)
        if (veil) {
          veil.style.transition = 'none'
          veil.style.opacity = newDepth === 0 ? '0' : '1'
        }
        if (targetOpacity === 0) {
          el.style.opacity = '0'
          exitFrameRef.current = window.requestAnimationFrame(() => {
            if (!el.isConnected) return
            el.style.transition = ''
            if (veil) veil.style.transition = ''
          })
        } else {
          el.style.opacity = '0'
          exitFrameRef.current = window.requestAnimationFrame(() => {
            if (!el.isConnected) return
            el.style.transition = `opacity 360ms ${GLIDE_EASE}`
            el.style.opacity = String(targetOpacity)
            if (veil) veil.style.transition = ''
            exitSettleTimerRef.current = window.setTimeout(() => {
              if (el.isConnected) el.style.transition = ''
            }, 380)
          })
        }
      }
      setExiting(null)
    }, exiting.durationMs + 16)

    return () => {
      if (exitTimerRef.current) {
        window.clearTimeout(exitTimerRef.current)
        exitTimerRef.current = null
      }
      exitAnimsRef.current.forEach(animation => { try { animation.cancel() } catch { /* Already cancelled. */ } })
      exitAnimsRef.current = []
    }
  }, [count, exiting])

  // Auto-advance every 6s when active, visible, and not paused.
  useEffect(() => {
    if (isPaused) return undefined
    const timer = window.setInterval(() => {
      if (typeof document !== 'undefined' && document.hidden) return
      step(1)
    }, AUTO_ADVANCE_MS)
    return () => window.clearInterval(timer)
  }, [isPaused, step])

  const handlePointerDown = event => {
    if (count < 2 || dragState.current || event.isPrimary === false) return
    if (event.pointerType === 'mouse' && event.button !== 0) return
    lastInteractionWasPointerRef.current = true
    if (touchResumeTimerRef.current) {
      window.clearTimeout(touchResumeTimerRef.current)
      touchResumeTimerRef.current = null
    }
    if (snapBackTimerRef.current) {
      window.clearTimeout(snapBackTimerRef.current)
      snapBackTimerRef.current = null
    }
    pauseForPointer()
    const now = performance.now()
    dragState.current = {
      pointerId: event.pointerId,
      pointerType: event.pointerType,
      startX: event.clientX,
      startY: event.clientY,
      startTime: now,
      dx: 0,
      locked: null,
      lastNextIdx: null,
      samples: [{ x: event.clientX, t: now }],
    }
  }

  const handlePointerMove = event => {
    const state = dragState.current
    if (!state || state.pointerId !== event.pointerId) return
    const dx = event.clientX - state.startX
    const dy = event.clientY - state.startY

    if (!state.locked) {
      if (Math.abs(dx) < AXIS_LOCK_PX && Math.abs(dy) < AXIS_LOCK_PX) return
      if (Math.abs(dy) > Math.abs(dx)) {
        // Vertical gesture: abort drag and allow native page scroll.
        dragState.current = null
        setTouchPaused(false)
        return
      }
      state.locked = 'x'
      setDragging(true)
      try { event.currentTarget.setPointerCapture?.(event.pointerId) } catch { /* ignore */ }
    }

    state.dx = dx
    const now = performance.now()
    state.samples.push({ x: event.clientX, t: now })
    if (state.samples.length > 6) state.samples.shift()

    if (reducedMotion) return

    // Direct 1:1 transform write without React re-renders (composite-only).
    // Keep the dragged front card fully opaque (opacity 1) so the next card never bleeds through.
    const frontNode = cardRefs.current[activeIndexRef.current]
    if (frontNode) {
      const clamped = Math.abs(dx) > 260 ? Math.sign(dx) * (260 + (Math.abs(dx) - 260) * 0.25) : dx
      frontNode.style.transition = 'none'
      frontNode.style.transform = `translate3d(${clamped}px, 0px, 0px) scale(1)`
      frontNode.style.opacity = '1'
    }

    // Gently lift the peeking next card and fade its solid veil in proportion to drag distance.
    const nextIdx = (activeIndexRef.current + (dx < 0 ? 1 : count - 1)) % count
    if (state.lastNextIdx !== null && state.lastNextIdx !== nextIdx) {
      restoreCardNode(cardRefs.current[state.lastNextIdx], state.lastNextIdx, activeIndexRef.current, count)
    }
    state.lastNextIdx = nextIdx

    const nextNode = cardRefs.current[nextIdx]
    if (nextNode && nextIdx !== activeIndexRef.current) {
      const progress = Math.min(1, Math.abs(dx) / 220)
      const y = (12 * (1 - progress * 0.65)).toFixed(1)
      const sc = (0.915 + 0.065 * progress).toFixed(4)
      nextNode.style.transition = 'none'
      nextNode.style.transform = `translate3d(0px, ${y}px, 0px) scale(${sc})`
      nextNode.style.opacity = '1'
      if (dx > 0) nextNode.style.zIndex = String(count)
      const veil = nextNode.querySelector('.hero-deck-back-veil')
      if (veil) {
        veil.style.transition = 'none'
        veil.style.opacity = String((1 - progress).toFixed(3))
      }
      const nextFace = nextNode.querySelector('.ticket')
      if (nextFace) nextFace.style.visibility = 'visible'
    }
  }

  const finishDrag = (event, cancelled = false) => {
    const state = dragState.current
    if (!state || state.pointerId !== event.pointerId) return
    const wasLocked = state.locked === 'x'
    const dx = state.dx
    const now = performance.now()

    // Instantaneous release velocity from recent pointer samples (last ~90ms).
    // Only treat velocity as a commit flick when it moves in the same direction as dx,
    // so dragging out and pulling back toward center always snaps back cleanly.
    const recent = state.samples.find(sample => now - sample.t <= 90) || state.samples[0]
    const dt = Math.max(1, now - recent.t)
    const vx = (event.clientX - recent.x) / dt
    const avgVelocity = Math.abs(dx) / Math.max(1, now - state.startTime)
    const sameDirectionVx = vx * dx > 0 ? Math.abs(vx) : 0
    const releaseSpeed = Math.abs(dx) >= SWIPE_DISTANCE_PX
      ? Math.max(sameDirectionVx, avgVelocity)
      : sameDirectionVx
    dragState.current = null

    const frontIdx = activeIndexRef.current
    const frontNode = cardRefs.current[frontIdx]

    const shouldCommit = wasLocked && !cancelled && (
      Math.abs(dx) >= SWIPE_DISTANCE_PX ||
      (releaseSpeed >= SWIPE_VELOCITY_PX_MS && Math.abs(dx) >= SWIPE_MIN_FLICK_PX)
    )
    const commitDelta = dx < 0 ? 1 : -1
    const committedNextIdx = shouldCommit ? (frontIdx + commitDelta + count) % count : null

    // Restore non-front cards to their exact resting values (or let the committed
    // incoming card glide cleanly from its dragged lift into depth 0).
    cardRefs.current.forEach((node, idx) => {
      if (!node || idx === frontIdx) return
      if (idx === committedNextIdx) {
        node.style.transition = ''
        const veil = node.querySelector('.hero-deck-back-veil')
        if (veil) veil.style.transition = ''
      } else {
        restoreCardNode(node, idx, frontIdx, count)
      }
    })

    if (wasLocked) {
      setDragging(false)
      swallowClickRef.current = true
      window.setTimeout(() => { swallowClickRef.current = false }, 350)

      if (shouldCommit) {
        const durationMs = Math.round(Math.max(550, Math.min(680, 660 - releaseSpeed * 80)))
        step(commitDelta, { startX: dx, durationMs })
      } else if (frontNode) {
        // Glide smoothly back to rest while staying fully opaque.
        frontNode.style.transition = reducedMotion
          ? 'none'
          : `transform 560ms ${GLIDE_EASE}`
        frontNode.style.transform = stackTransform(0)
        frontNode.style.opacity = '1'
        snapBackTimerRef.current = window.setTimeout(() => {
          if (frontNode.isConnected) {
            frontNode.style.transition = ''
          }
        }, reducedMotion ? 0 : 580)
      }
    }

    if (state.pointerType === 'touch') {
      pauseForPointer()
    } else {
      setTouchPaused(false)
    }
  }

  useEffect(() => {
    const clearOutsidePress = event => {
      const state = dragState.current
      if (!state || state.pointerId !== event.pointerId || state.locked) return
      dragState.current = null
      pauseForPointer()
    }
    window.addEventListener('pointerup', clearOutsidePress)
    window.addEventListener('pointercancel', clearOutsidePress)
    return () => {
      window.removeEventListener('pointerup', clearOutsidePress)
      window.removeEventListener('pointercancel', clearOutsidePress)
    }
  }, [pauseForPointer])

  const handleKeyDown = event => {
    if (count < 2) return
    if (event.key === 'ArrowRight' || event.key === 'ArrowLeft') {
      if (event.target.closest?.('a.hero-deck-link')) keyboardFocusRef.current = 'link'
      else if (event.target.closest?.('[data-slide-selector]')) keyboardFocusRef.current = 'selector'
    }
    if (event.key === 'ArrowRight') {
      event.preventDefault()
      step(1)
    } else if (event.key === 'ArrowLeft') {
      event.preventDefault()
      step(-1)
    }
  }

  const handleControlClick = (clickEvent, action) => {
    if (clickEvent.detail !== 0) {
      lastInteractionWasPointerRef.current = true
      setFocusPaused(false)
      pauseForPointer()
    }
    action()
  }

  return (
    <div
      ref={rootRef}
      className="hero-deck-root mx-auto w-full max-w-[26.5rem]"
      role="region"
      aria-roledescription={count > 1 ? 'carousel' : undefined}
      aria-label={t('pass.home.deckLabel')}
      data-testid="hero-fanned-deck"
      data-active-index={safeIndex}
      data-card-count={count}
      data-paused={isPaused ? 'true' : 'false'}
      onPointerDownCapture={() => { lastInteractionWasPointerRef.current = true }}
      onKeyDownCapture={() => { lastInteractionWasPointerRef.current = false }}
      onPointerEnter={event => {
        if (event.pointerType === 'mouse') setHoverPaused(true)
      }}
      onPointerLeave={event => {
        if (event.pointerType === 'mouse') setHoverPaused(false)
      }}
      onFocus={() => {
        if (lastInteractionWasPointerRef.current) {
          setFocusPaused(false)
          pauseForPointer()
        } else {
          setFocusPaused(true)
        }
      }}
      onBlur={event => {
        if (!event.currentTarget.contains(event.relatedTarget)) setFocusPaused(false)
      }}
      onKeyDown={handleKeyDown}
    >
      <div
        className={`hero-deck-stage relative grid ${showStack ? 'pb-8' : ''}`}
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={event => finishDrag(event, false)}
        onPointerCancel={event => finishDrag(event, true)}
      >
        {isSkeleton && [2, 1].map(depth => (
          <div
            key={`skeleton-${depth}`}
            aria-hidden="true"
            data-testid="hero-deck-skeleton"
            data-depth={depth}
            className="hero-deck-skeleton hero-deck-card hero-deck-card-back pointer-events-none col-start-1 row-start-1 h-full"
            style={{
              zIndex: 3 - depth,
              opacity: 1,
              transform: stackTransform(depth),
            }}
          >
            <div className="relative h-full rounded-[1.25rem]">
              <div className="ticket featured-ticket flex h-full flex-col">
                <TicketTop className="flex-1" />
                <TicketStub className="flex-1" />
              </div>
              <span className="hero-deck-back-veil pointer-events-none absolute inset-0 rounded-[1.25rem]" style={{ opacity: 1 }} />
            </div>
          </div>
        ))}

        {cards.map((card, index) => {
          const isExiting = exiting?.index === index
          const depth = (index - safeIndex + count) % count
          const isFront = depth === 0 && !isExiting
          const zIndex = isExiting ? count + 3 : isFront ? Math.max(count + 1, 4) : count - depth
          const opacity = isExiting ? 1 : stackOpacity(depth)
          const transform = isExiting ? stackTransform(0) : stackTransform(depth)
          const to = card.kind === 'brand' ? '/events' : `/events/${card.event.slug || card.event.id}`

          return (
            <div
              key={card.id}
              ref={el => { cardRefs.current[index] = el }}
              className={`hero-deck-card col-start-1 row-start-1 h-full ${isFront || isExiting ? 'hero-deck-card-front' : 'hero-deck-card-back'}`}
              data-card-kind={card.kind}
              data-depth={depth}
              data-exiting={isExiting ? 'true' : 'false'}
              data-front={isFront ? 'true' : 'false'}
              aria-hidden={!isFront}
              style={{
                zIndex,
                opacity,
                transform,
                pointerEvents: isFront ? 'auto' : 'none',
              }}
            >
              <Link
                to={to}
                state={card.kind === 'event' ? { browseFrom: `${location.pathname}${location.search}` } : undefined}
                tabIndex={isFront ? 0 : -1}
                draggable={false}
                className="hero-deck-link relative block h-full rounded-[1.25rem]"
                onClick={clickEvent => {
                  if (swallowClickRef.current && clickEvent.detail !== 0) {
                    clickEvent.preventDefault()
                    swallowClickRef.current = false
                  }
                }}
              >
                {card.kind === 'brand' ? (
                  <BrandDefaultTicketFace  />
                ) : (
                  <EventDeckTicketFace event={card.event} isFront={isFront} showFace={isFront || isExiting || dragging} />
                )}
                <span
                  aria-hidden="true"
                  className="hero-deck-back-veil pointer-events-none absolute inset-0 rounded-[1.25rem]"
                  style={{ opacity: isFront || isExiting ? 0 : 1 }}
                />
              </Link>
            </div>
          )
        })}
      </div>

      {showStack && (
        <div className="mt-1 flex flex-wrap items-center justify-between gap-2" data-testid="hero-deck-controls">
          {isSkeleton ? (
            <>
              <div className="flex items-center gap-0.5" aria-hidden="true">
                {[0, 1, 2, 3].map(idx => (
                  <button
                    key={idx}
                    type="button"
                    disabled
                    tabIndex={-1}
                    className="hero-deck-dot-btn inline-flex h-11 w-11 items-center justify-center rounded-full"
                  >
                    <span
                      data-active={idx === 0 ? 'true' : 'false'}
                      className={`hero-deck-dot block h-2 rounded-full ${idx === 0 ? 'bg-brand-300/60' : 'bg-white/20'}`}
                    />
                  </button>
                ))}
              </div>
              <div className="flex items-center gap-1" aria-hidden="true">
                <button
                  type="button"
                  disabled
                  tabIndex={-1}
                  className="hero-deck-nav inline-flex h-11 w-11 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white/40"
                >
                  <ChevronLeft className="h-5 w-5" />
                </button>
                <button
                  type="button"
                  disabled
                  tabIndex={-1}
                  className="hero-deck-nav inline-flex h-11 w-11 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white/40"
                >
                  <ChevronRight className="h-5 w-5" />
                </button>
                <span className="inline-block h-11 w-11" />
              </div>
            </>
          ) : (
            <>
              <div className="flex items-center gap-0.5" role="group" aria-label={t('pass.home.choosePass')}>
                {cards.map((card, index) => {
                  const active = index === safeIndex
                  return (
                    <button
                      key={card.id}
                      type="button"
                      data-slide-selector="true"
                      aria-pressed={active}
                      aria-label={t('pass.home.showPass', { label: card.label, index: index + 1, count })}
                      onClick={clickEvent => handleControlClick(clickEvent, () => goTo(index))}
                      className="hero-deck-dot-btn inline-flex h-11 w-11 items-center justify-center rounded-full"
                    >
                      <span
                        aria-hidden="true"
                        data-active={active ? 'true' : 'false'}
                        className={`hero-deck-dot block h-2 rounded-full ${active ? 'bg-brand-300' : 'bg-white/35'}`}
                      />
                    </button>
                  )
                })}
              </div>
              <div className="flex items-center gap-1">
                <span className="sr-only" aria-live={isPaused ? 'polite' : 'off'} data-testid="hero-deck-live">
                  {t('pass.home.passPosition', { index: safeIndex + 1, count, label: cards[safeIndex]?.label })}
                </span>
                <button
                  type="button"
                  onClick={clickEvent => handleControlClick(clickEvent, () => step(-1))}
                  aria-label={t('pass.home.previousPass')}
                  className="hero-deck-nav tactile-press inline-flex h-11 w-11 items-center justify-center rounded-full border border-white/20 bg-white/5 text-white"
                >
                  <ChevronLeft aria-hidden="true" className="h-5 w-5" />
                </button>
                <button
                  type="button"
                  onClick={clickEvent => handleControlClick(clickEvent, () => step(1))}
                  aria-label={t('pass.home.nextPass')}
                  className="hero-deck-nav tactile-press inline-flex h-11 w-11 items-center justify-center rounded-full border border-white/20 bg-white/5 text-white"
                >
                  <ChevronRight aria-hidden="true" className="h-5 w-5" />
                </button>
                <button type="button" onClick={() => setRotationStopped(value => !value)}
                  aria-label={t(rotationStopped ? 'pass.home.resumeRotation' : 'pass.home.pauseRotation')}
                  className="hero-deck-nav inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-full border border-white/25 text-white">
                  {rotationStopped ? <Play aria-hidden="true" className="h-4 w-4" /> : <Pause aria-hidden="true" className="h-4 w-4" />}
                </button>
              </div>
            </>
          )}
        </div>
      )}
    </div>
  )
}
