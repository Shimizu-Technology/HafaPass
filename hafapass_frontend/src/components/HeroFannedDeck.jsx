import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ArrowRight, Calendar, ChevronLeft, ChevronRight, MapPin } from 'lucide-react'
import HafaPassMark from './HafaPassMark'
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
  if (depth === 1) return 'translate3d(0px, 14px, 0px) scale(0.955)'
  return 'translate3d(0px, 26px, 0px) scale(0.91)'
}

function stackOpacity(depth) {
  if (depth === 0) return 1
  if (depth === 1) return 0.92
  if (depth === 2) return 0.76
  return 0
}

function BrandDefaultTicketFace() {
  const { t } = useTranslation()

  return (
    <div className="ticket featured-ticket flex h-full flex-col text-content" data-testid="hero-brand-card">
      <TicketTop>
        <div className="relative aspect-video overflow-hidden bg-gradient-to-br from-[#032827] via-[#074d4b] to-[#0d8b84]">
          <svg
            aria-hidden="true"
            viewBox="0 0 1600 900"
            className="pointer-events-none absolute inset-0 h-full w-full"
            preserveAspectRatio="xMidYMid slice"
          >
            <g opacity="0.16" stroke="#53f5df" strokeWidth="2.5" fill="none">
              <circle cx="1260" cy="450" r="320" />
              <circle cx="1260" cy="450" r="220" />
              <circle cx="1260" cy="450" r="120" />
              <line x1="940" y1="450" x2="1580" y2="450" />
              <line x1="1260" y1="130" x2="1260" y2="770" />
            </g>
            <path d="M0 730 Q420 650 860 720 T1600 680 L1600 900 L0 900 Z" fill="#021c1b" opacity="0.45" />
          </svg>
          <div className="relative flex h-full flex-col justify-between p-5 text-white sm:p-6">
            <div className="flex items-center justify-between gap-2">
              <span className="inline-flex items-center rounded-full border border-brand-300/35 bg-brand-950/55 px-3 py-1 text-xs font-semibold uppercase tracking-[0.12em] text-brand-200">
                Guam · Official Pass
              </span>
            </div>
            <div className="flex items-center gap-3">
              <span className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-brand-700/95 ring-1 ring-white/20">
                <HafaPassMark className="h-6 w-6 text-white" />
              </span>
              <span className="font-display text-3xl font-bold tracking-tight text-white sm:text-[2.125rem]">
                Håfa<span className="text-brand-300">Pass</span>
              </span>
            </div>
          </div>
        </div>
        <div className="px-5 pb-4 pt-4 sm:px-6">
          <p className="text-xs font-semibold uppercase tracking-[0.08em] text-brand-800">
            HåfaPass Guam
          </p>
          <p className="mt-1 line-clamp-2 min-h-[2.85rem] font-display text-[1.25rem] font-bold leading-[1.18] tracking-[-0.02em] text-neutral-950 sm:min-h-[3.2rem] sm:text-[1.4rem]">
            Your pass to what’s on across Guam
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
              <p className="truncate font-semibold text-neutral-950">Instant mobile QR tickets</p>
              <p className="truncate text-xs text-content-muted">{t('pass.home.guamTime')}</p>
            </div>
          </div>
          <div className="mt-auto flex items-center justify-between gap-3 pt-1">
            <div className="min-h-[2.75rem] flex flex-col justify-center">
              <p className="font-mono text-xs font-semibold uppercase tracking-[0.12em] text-neutral-600">
                GU · ADMIT ONE
              </p>
              <p className="text-xs text-content-muted">No account needed</p>
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

function EventDeckTicketFace({ event, isFront }) {
  const { t } = useTranslation()
  const content = useTranslatedContent(event)
  const [failedArtwork, setFailedArtwork] = useState(null)
  const hasArtwork = approvedImageUrl(event.cover_image_url, event.image_asset_host) && failedArtwork !== event.cover_image_url
  const summary = priceSummary(event.ticket_types)
  const hasInventory = !event.ticket_types || event.ticket_types.some(ticket => remainingTickets(ticket) === null || remainingTickets(ticket) > 0)
  const place = [event.venue_name, event.venue_city].filter(Boolean).join(' · ')

  return (
    <div className="ticket featured-ticket flex h-full flex-col text-content">
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
export default function HeroFannedDeck({ events = [] }) {
  const location = useLocation()
  const reducedMotion = usePrefersReducedMotion()

  const cards = useMemo(() => {
    const featured = Array.isArray(events) ? events.slice(0, 3) : []
    return [
      { kind: 'brand', id: 'hafapass-default', label: 'HåfaPass Guam pass' },
      ...featured.map(event => ({
        kind: 'event',
        id: `event-${event.id ?? event.slug}`,
        label: event.title || 'Featured event',
        event,
      })),
    ]
  }, [events])

  const count = cards.length
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
  const dragState = useRef(null)
  const swallowClickRef = useRef(false)
  const exitSeqRef = useRef(0)
  const exitTimerRef = useRef(null)
  const exitAnimRef = useRef(null)
  const touchResumeTimerRef = useRef(null)
  const snapBackTimerRef = useRef(null)

  const safeIndex = count > 0 ? activeIndex % count : 0
  activeIndexRef.current = safeIndex

  const isPaused = reducedMotion || hoverPaused || focusPaused || touchPaused || tabHidden || offscreen || dragging || count < 2

  const clearExitAnimation = useCallback(() => {
    if (exitTimerRef.current) {
      window.clearTimeout(exitTimerRef.current)
      exitTimerRef.current = null
    }
    if (exitAnimRef.current) {
      try { exitAnimRef.current.cancel() } catch { /* ignore */ }
      exitAnimRef.current = null
    }
  }, [])

  // Cleanup timers and animations on unmount.
  useEffect(() => () => {
    clearExitAnimation()
    if (touchResumeTimerRef.current) window.clearTimeout(touchResumeTimerRef.current)
    if (snapBackTimerRef.current) window.clearTimeout(snapBackTimerRef.current)
  }, [clearExitAnimation])

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

    // Clear any lingering inline drag styles on non-exiting cards before transition.
    cardRefs.current.forEach((el, idx) => {
      if (!el || idx === current) return
      el.style.transition = ''
      el.style.transform = ''
      el.style.opacity = ''
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

  // Drive the outgoing card's smooth composite-only glide via WAAPI so it starts
  // seamlessly from startX (0 or drag release px) without snapping or jumping.
  useLayoutEffect(() => {
    if (!exiting) return undefined
    const el = cardRefs.current[exiting.index]
    if (!el) return undefined

    // Clear any inline drag transform before launching WAAPI.
    el.style.transition = 'none'
    el.style.transform = ''
    el.style.opacity = ''

    const fromTransform = `translate3d(${exiting.startX}px, 0px, 0px) scale(1)`
    const toTransform = `translate3d(${exiting.direction * 108}%, -6px, 0px) scale(0.96)`

    if (typeof el.animate === 'function') {
      const anim = el.animate(
        [
          { transform: fromTransform, opacity: 1 },
          { transform: toTransform, opacity: 0 },
        ],
        {
          duration: exiting.durationMs,
          easing: GLIDE_EASE,
          fill: 'forwards',
        },
      )
      exitAnimRef.current = anim
    }

    exitTimerRef.current = window.setTimeout(() => {
      if (exitAnimRef.current) {
        try { exitAnimRef.current.cancel() } catch { /* ignore */ }
        exitAnimRef.current = null
      }
      // Keep the card hidden at its new back-of-stack slot for one frame so it
      // never slides back from offscreen, then let it settle softly into depth.
      if (el) {
        el.style.transition = 'none'
        el.style.opacity = '0'
        window.requestAnimationFrame(() => {
          if (!el.isConnected) return
          el.style.transition = 'opacity 260ms ease-out'
          el.style.opacity = ''
          window.setTimeout(() => {
            if (el.isConnected) el.style.transition = ''
          }, 280)
        })
      }
      setExiting(null)
    }, exiting.durationMs + 16)

    return () => {
      if (exitTimerRef.current) {
        window.clearTimeout(exitTimerRef.current)
        exitTimerRef.current = null
      }
    }
  }, [exiting])

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
    if (count < 2) return
    if (event.pointerType === 'mouse' && event.button !== 0) return
    if (touchResumeTimerRef.current) {
      window.clearTimeout(touchResumeTimerRef.current)
      touchResumeTimerRef.current = null
    }
    if (snapBackTimerRef.current) {
      window.clearTimeout(snapBackTimerRef.current)
      snapBackTimerRef.current = null
    }
    setTouchPaused(true)
    const now = performance.now()
    dragState.current = {
      pointerId: event.pointerId,
      pointerType: event.pointerType,
      startX: event.clientX,
      startY: event.clientY,
      startTime: now,
      dx: 0,
      locked: null,
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
    const frontNode = cardRefs.current[activeIndexRef.current]
    if (frontNode) {
      const clamped = Math.abs(dx) > 260 ? Math.sign(dx) * (260 + (Math.abs(dx) - 260) * 0.25) : dx
      frontNode.style.transition = 'none'
      frontNode.style.transform = `translate3d(${clamped}px, 0px, 0px) scale(1)`
      frontNode.style.opacity = String(Math.max(0.55, 1 - Math.abs(clamped) / 540).toFixed(3))
    }

    // Gently lift the peeking next card as the user pulls the top card away.
    const nextIdx = (activeIndexRef.current + (dx < 0 ? 1 : count - 1)) % count
    const nextNode = cardRefs.current[nextIdx]
    if (nextNode && nextIdx !== activeIndexRef.current) {
      const progress = Math.min(1, Math.abs(dx) / 220)
      const y = (14 * (1 - progress * 0.65)).toFixed(1)
      const sc = (0.955 + 0.03 * progress).toFixed(4)
      nextNode.style.transition = 'none'
      nextNode.style.transform = `translate3d(0px, ${y}px, 0px) scale(${sc})`
      nextNode.style.opacity = String((0.92 + 0.08 * progress).toFixed(3))
    }
  }

  const finishDrag = (event, cancelled = false) => {
    const state = dragState.current
    if (!state || state.pointerId !== event.pointerId) return
    const wasLocked = state.locked === 'x'
    const dx = state.dx
    const now = performance.now()

    // Instantaneous release velocity from recent pointer samples (last ~90ms).
    const recent = state.samples.find(sample => now - sample.t <= 90) || state.samples[0]
    const dt = Math.max(1, now - recent.t)
    const vx = (event.clientX - recent.x) / dt
    const avgVelocity = Math.abs(dx) / Math.max(1, now - state.startTime)
    const releaseSpeed = Math.max(Math.abs(vx), avgVelocity)
    dragState.current = null

    const frontNode = cardRefs.current[activeIndexRef.current]
    // Restore any nudged next card so it glides smoothly via CSS transition.
    cardRefs.current.forEach((node, idx) => {
      if (!node || idx === activeIndexRef.current) return
      node.style.transition = ''
      node.style.transform = ''
      node.style.opacity = ''
    })

    if (wasLocked) {
      setDragging(false)
      swallowClickRef.current = true
      window.setTimeout(() => { swallowClickRef.current = false }, 350)

      const shouldCommit = !cancelled && (
        Math.abs(dx) >= SWIPE_DISTANCE_PX ||
        (releaseSpeed >= SWIPE_VELOCITY_PX_MS && Math.abs(dx) >= SWIPE_MIN_FLICK_PX)
      )

      if (shouldCommit) {
        const delta = dx < 0 ? 1 : -1
        const durationMs = Math.round(Math.max(550, Math.min(680, 660 - releaseSpeed * 80)))
        step(delta, { startX: dx, durationMs })
      } else if (frontNode) {
        // Glide smoothly back to rest.
        frontNode.style.transition = reducedMotion
          ? 'none'
          : `transform 560ms ${GLIDE_EASE}, opacity 560ms ${GLIDE_EASE}`
        frontNode.style.transform = stackTransform(0)
        frontNode.style.opacity = '1'
        snapBackTimerRef.current = window.setTimeout(() => {
          if (frontNode.isConnected) {
            frontNode.style.transition = ''
            frontNode.style.transform = ''
            frontNode.style.opacity = ''
          }
        }, reducedMotion ? 0 : 580)
      }
    }

    if (state.pointerType === 'touch') {
      touchResumeTimerRef.current = window.setTimeout(() => setTouchPaused(false), AUTO_ADVANCE_MS)
    } else {
      setTouchPaused(false)
    }
  }

  const handleKeyDown = event => {
    if (count < 2) return
    if (event.key === 'ArrowRight') {
      event.preventDefault()
      step(1)
    } else if (event.key === 'ArrowLeft') {
      event.preventDefault()
      step(-1)
    }
  }

  return (
    <div
      ref={rootRef}
      className="hero-deck-root mx-auto w-full max-w-[26.5rem]"
      role="region"
      aria-roledescription={count > 1 ? 'carousel' : undefined}
      aria-label="HåfaPass featured events deck"
      data-testid="hero-fanned-deck"
      data-active-index={safeIndex}
      data-card-count={count}
      data-paused={isPaused ? 'true' : 'false'}
      onMouseEnter={() => setHoverPaused(true)}
      onMouseLeave={() => setHoverPaused(false)}
      onFocus={() => setFocusPaused(true)}
      onBlur={event => {
        if (!event.currentTarget.contains(event.relatedTarget)) setFocusPaused(false)
      }}
      onKeyDown={handleKeyDown}
    >
      <div
        className={`hero-deck-stage relative grid ${count > 1 ? 'pb-8' : ''}`}
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={event => finishDrag(event, false)}
        onPointerCancel={event => finishDrag(event, true)}
      >
        {cards.map((card, index) => {
          const isExiting = exiting?.index === index
          const depth = (index - safeIndex + count) % count
          const isFront = depth === 0 && !isExiting
          const zIndex = isExiting ? count + 2 : count - depth
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
                  <BrandDefaultTicketFace />
                ) : (
                  <EventDeckTicketFace event={card.event} isFront={isFront} />
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

      {count > 1 && (
        <div className="mt-1 flex items-center justify-between gap-2" data-testid="hero-deck-controls">
          <div className="flex items-center gap-0.5" role="tablist" aria-label="Choose featured pass">
            {cards.map((card, index) => {
              const active = index === safeIndex
              return (
                <button
                  key={card.id}
                  type="button"
                  role="tab"
                  aria-selected={active}
                  aria-label={`Show ${card.label} (${index + 1} of ${count})`}
                  onClick={() => goTo(index)}
                  className="hero-deck-dot-btn inline-flex min-h-11 min-w-11 items-center justify-center rounded-full"
                >
                  <span
                    aria-hidden="true"
                    className={`hero-deck-dot block h-2 w-5 rounded-full ${active ? 'bg-brand-300' : 'bg-white/35'}`}
                    style={{ transform: active ? 'scaleX(1)' : 'scaleX(0.4)' }}
                  />
                </button>
              )
            })}
          </div>
          <div className="flex items-center gap-1">
            <span className="sr-only" aria-live="polite" data-testid="hero-deck-live">
              {safeIndex + 1} of {count}: {cards[safeIndex]?.label}
            </span>
            <span aria-hidden="true" className="mr-1.5 text-xs font-semibold tabular-nums text-brand-200/90">
              {safeIndex + 1} / {count}
            </span>
            <button
              type="button"
              onClick={() => step(-1)}
              aria-label="Previous featured pass"
              className="hero-deck-nav tactile-press inline-flex h-11 w-11 items-center justify-center rounded-full border border-white/20 bg-white/5 text-white"
            >
              <ChevronLeft aria-hidden="true" className="h-5 w-5" />
            </button>
            <button
              type="button"
              onClick={() => step(1)}
              aria-label="Next featured pass"
              className="hero-deck-nav tactile-press inline-flex h-11 w-11 items-center justify-center rounded-full border border-white/20 bg-white/5 text-white"
            >
              <ChevronRight aria-hidden="true" className="h-5 w-5" />
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
