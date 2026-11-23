import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ArrowRight, Calendar, ChevronLeft, ChevronRight, MapPin } from 'lucide-react'
import { TicketTop, TicketStub } from './Ticket'
import usePrefersReducedMotion from '../hooks/usePrefersReducedMotion'
import useTranslatedContent from '../hooks/useTranslatedContent'
import { approvedImageUrl, focalPosition } from '../utils/eventPageDesign'
import { formatEventDate, formatEventTime } from '../utils/eventTime'
import { formatTicketPrice, lowestPurchasablePrice, remainingTickets } from '../utils/ticketPricing'

const AUTO_ADVANCE_MS = 5000
const SWIPE_DISTANCE_PX = 52
const SWIPE_VELOCITY = 0.11

function DeckTicketFace({ event, isFront }) {
  const { t } = useTranslation()
  const content = useTranslatedContent(event)
  const [failedArtwork, setFailedArtwork] = useState(null)
  const hasArtwork = approvedImageUrl(event.cover_image_url, event.image_asset_host) && failedArtwork !== event.cover_image_url
  const lowestPrice = lowestPurchasablePrice(event.ticket_types)
  const hasInventory = !event.ticket_types || event.ticket_types.some(ticket => remainingTickets(ticket) === null || remainingTickets(ticket) > 0)
  const place = [event.venue_name, event.venue_city].filter(Boolean).join(' · ')

  return (
    <div className="ticket featured-ticket text-content">
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
        <div className="px-5 pb-3.5 pt-3.5 sm:px-6 sm:pb-4 sm:pt-4">
          <p className="text-xs font-semibold uppercase tracking-[0.1em] text-brand-800">
            {event.is_featured ? t('pass.home.featuredOnGuam') : t('pass.home.nextUpOnGuam')}
          </p>
          <p className="mt-1 line-clamp-2 min-h-[2.65rem] font-display text-[1.22rem] font-bold leading-[1.18] tracking-[-0.02em] text-neutral-950 [overflow-wrap:anywhere] sm:min-h-[3.1rem] sm:text-[1.4rem]">
            {content.title}
          </p>
        </div>
      </TicketTop>
      <TicketStub>
        <div className="grid gap-1.5 px-5 pb-4 pt-3.5 text-sm text-neutral-800 sm:px-6 sm:pb-5 sm:pt-4 sm:text-[0.95rem]">
          <p className="flex items-start gap-2">
            <Calendar aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-brand-700" />
            <span className="truncate">{formatEventDate(event.starts_at, event.timezone, { weekday: 'short', year: undefined })} · {formatEventTime(event.starts_at, event.timezone)}</span>
          </p>
          <p className="flex items-start gap-2">
            <MapPin aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-brand-700" />
            <span className="min-w-0 truncate">{place || 'Guam'}</span>
          </p>
          <div className="mt-1.5 flex flex-wrap items-center justify-between gap-2.5">
            {lowestPrice === null ? (
              <span className="text-sm font-semibold text-neutral-600">
                {hasInventory ? t('events.salesUnavailable') : t('events.soldOut')}
              </span>
            ) : (
              <p className="font-display text-lg font-bold tabular-nums text-neutral-950 sm:text-xl">
                {lowestPrice === 0
                  ? <span>{t('events.free')}</span>
                  : <><span className="text-xs font-semibold text-neutral-700 sm:text-sm">{t('events.from')}</span> <span>{formatTicketPrice(lowestPrice)}</span></>}
              </p>
            )}
            <span className="inline-flex min-h-11 items-center gap-1.5 rounded-xl bg-action px-4 text-sm font-semibold text-white">
              {t('pass.home.seeTickets')}
              <ArrowRight aria-hidden="true" className="h-4 w-4 shrink-0" />
            </span>
          </div>
        </div>
      </TicketStub>
    </div>
  )
}

function stackTransform(depth) {
  if (depth === 0) return 'translate3d(0px, 0px, 0px) scale(1)'
  if (depth === 1) return 'translate3d(0px, 14px, 0px) scale(0.95)'
  return 'translate3d(0px, 28px, 0px) scale(0.90)'
}

/**
 * Hero 2: Flat 2D fanned deck of up to 3 upcoming Guam event tickets.
 * Zero 3D rotation. Supports swipe/drag with direct transform writes (no
 * per-frame React state), gentle 5s auto-advance that pauses on touch, hover,
 * or focus, and stops completely under prefers-reduced-motion.
 */
export default function HeroFannedDeck({ events = [] }) {
  const location = useLocation()
  const reducedMotion = usePrefersReducedMotion()
  const cards = useMemo(() => events.slice(0, 3), [events])
  const count = cards.length

  const [activeIndex, setActiveIndex] = useState(0)
  const [paused, setPaused] = useState(false)
  const [dragging, setDragging] = useState(false)

  const frontRef = useRef(null)
  const dragState = useRef(null)
  const swallowClickRef = useRef(false)

  const safeIndex = count > 0 ? activeIndex % count : 0

  const goTo = useCallback(index => {
    if (count < 2) return
    setActiveIndex(((index % count) + count) % count)
  }, [count])

  const step = useCallback(delta => {
    if (count < 2) return
    setActiveIndex(prev => (((prev + delta) % count) + count) % count)
  }, [count])

  useEffect(() => {
    if (reducedMotion || paused || dragging || count < 2) return undefined
    const timer = window.setInterval(() => {
      if (document.hidden) return
      setActiveIndex(prev => (prev + 1) % count)
    }, AUTO_ADVANCE_MS)
    return () => window.clearInterval(timer)
  }, [reducedMotion, paused, dragging, count])

  const handlePointerDown = event => {
    if (count < 2) return
    if (event.pointerType === 'mouse' && event.button !== 0) return
    setPaused(true)
    dragState.current = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      startTime: performance.now(),
      dx: 0,
      locked: null,
    }
  }

  const handlePointerMove = event => {
    const state = dragState.current
    if (!state || state.pointerId !== event.pointerId) return
    const dx = event.clientX - state.startX
    const dy = event.clientY - state.startY
    if (!state.locked) {
      if (Math.abs(dx) < 8 && Math.abs(dy) < 8) return
      if (Math.abs(dy) > Math.abs(dx)) {
        dragState.current = null
        return
      }
      state.locked = 'x'
      setDragging(true)
      try { event.currentTarget.setPointerCapture?.(event.pointerId) } catch { /* ignore */ }
    }
    state.dx = dx
    const node = frontRef.current
    if (node) {
      const clamped = Math.max(-140, Math.min(140, dx))
      node.style.transition = 'none'
      node.style.transform = `translate3d(${clamped}px, 0px, 0px) scale(1)`
    }
  }

  const finishDrag = (event, cancelled = false) => {
    const state = dragState.current
    if (!state || state.pointerId !== event.pointerId) return
    const wasLocked = state.locked === 'x'
    const dx = state.dx
    const elapsed = Math.max(1, performance.now() - state.startTime)
    const velocity = Math.abs(dx) / elapsed
    dragState.current = null

    const node = frontRef.current
    if (node) {
      node.style.transition = ''
      node.style.transform = stackTransform(0)
    }
    if (wasLocked) {
      setDragging(false)
      swallowClickRef.current = true
      window.setTimeout(() => { swallowClickRef.current = false }, 350)
      if (!cancelled && (Math.abs(dx) >= SWIPE_DISTANCE_PX || velocity > SWIPE_VELOCITY)) {
        step(dx < 0 ? 1 : -1)
      }
    }
    if (event.pointerType === 'touch') {
      // Keep paused briefly after touch so the user can inspect the chosen card.
      window.setTimeout(() => setPaused(false), AUTO_ADVANCE_MS)
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

  if (count === 0) return null

  return (
    <div
      className="hero-deck-root mx-auto w-full max-w-[26.5rem]"
      role="region"
      aria-roledescription="carousel"
      aria-label="Featured upcoming events deck"
      data-testid="hero-fanned-deck"
      data-active-index={safeIndex}
      data-paused={paused || reducedMotion ? 'true' : 'false'}
      onMouseEnter={() => setPaused(true)}
      onMouseLeave={() => setPaused(false)}
      onFocus={() => setPaused(true)}
      onBlur={event => {
        if (!event.currentTarget.contains(event.relatedTarget)) setPaused(false)
      }}
      onKeyDown={handleKeyDown}
    >
      <div
        className="hero-deck-stage relative grid pb-8"
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={event => finishDrag(event, false)}
        onPointerCancel={event => finishDrag(event, true)}
      >
        {cards.map((event, index) => {
          const depth = (index - safeIndex + count) % count
          const isFront = depth === 0
          const zIndex = count - depth
          const opacity = depth === 0 ? 1 : depth === 1 ? 0.9 : 0.72
          return (
            <div
              key={event.id}
              ref={isFront ? frontRef : undefined}
              className={`hero-deck-card col-start-1 row-start-1 ${isFront ? 'hero-deck-card-front' : 'hero-deck-card-back'}`}
              data-depth={depth}
              aria-hidden={!isFront}
              style={{
                zIndex,
                opacity,
                transform: stackTransform(depth),
                pointerEvents: isFront ? 'auto' : 'none',
              }}
            >
              <Link
                to={`/events/${event.slug || event.id}`}
                state={{ browseFrom: `${location.pathname}${location.search}` }}
                tabIndex={isFront ? 0 : -1}
                draggable={false}
                className="hero-deck-link block rounded-[1.25rem]"
                onClick={clickEvent => {
                  if (swallowClickRef.current && clickEvent.detail !== 0) {
                    clickEvent.preventDefault()
                    swallowClickRef.current = false
                  }
                }}
              >
                <DeckTicketFace event={event} isFront={isFront} />
              </Link>
            </div>
          )
        })}
      </div>

      {count > 1 && (
        <div className="mt-1 flex items-center justify-between gap-2">
          <div className="flex items-center gap-0.5" role="tablist" aria-label="Choose featured event">
            {cards.map((event, index) => {
              const active = index === safeIndex
              return (
                <button
                  key={event.id}
                  type="button"
                  role="tab"
                  aria-selected={active}
                  aria-label={`Show ${event.title} (${index + 1} of ${count})`}
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
            <span className="mr-1.5 text-xs font-semibold tabular-nums text-brand-200/85" aria-live="polite">
              {safeIndex + 1} / {count}
            </span>
            <button
              type="button"
              onClick={() => step(-1)}
              aria-label="Previous featured event"
              className="hero-deck-nav inline-flex h-11 w-11 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white"
            >
              <ChevronLeft aria-hidden="true" className="h-5 w-5" />
            </button>
            <button
              type="button"
              onClick={() => step(1)}
              aria-label="Next featured event"
              className="hero-deck-nav inline-flex h-11 w-11 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white"
            >
              <ChevronRight aria-hidden="true" className="h-5 w-5" />
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
