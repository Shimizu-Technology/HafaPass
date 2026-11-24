import { useCallback, useEffect, useMemo, useRef, useState, version as reactVersion } from 'react'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ArrowRight, ChevronLeft, ChevronRight } from 'lucide-react'
import { TicketTop, TicketStub } from './Ticket'
import EventDateTile from './EventDateTile'
import usePrefersReducedMotion from '../hooks/usePrefersReducedMotion'
import { approvedImageUrl, focalPosition } from '../utils/eventPageDesign'
import { formatEventDate } from '../utils/eventTime'
import { formatTicketPrice, priceSummary } from '../utils/ticketPricing'

const INERT_VALUE = Number(reactVersion.split('.')[0]) >= 19 ? true : ''

function stackTransform(depth) {
  if (depth === 0) return 'none'
  if (depth === 1) return 'translate3d(0, 10px, 0) scale(0.96)'
  if (depth === 2) return 'translate3d(0, 20px, 0) scale(0.92)'
  return 'translate3d(0, 20px, 0) scale(0.92)'
}

/**
 * Swipeable stack of featured Guam event ticket stubs on the light sheet.
 * Cover art stays completely unobstructed (no text overlays). Back cards are
 * stacked straight with blank ticket stock (aria-hidden + inert).
 */
export default function EventStubDeck({ events = [] }) {
  const { t } = useTranslation()
  const location = useLocation()
  const navigate = useNavigate()
  const reducedMotion = usePrefersReducedMotion()
  const items = useMemo(() => events.slice(0, 4), [events])
  const count = items.length

  const [activeIndex, setActiveIndex] = useState(0)
  const [flying, setFlying] = useState(null) // { idx, dir }
  const [draggingIdx, setDraggingIdx] = useState(null)
  const [failedArt, setFailedArt] = useState({})
  const busyRef = useRef(false)
  const dragRef = useRef(null)
  const cardRefs = useRef([])
  const timersRef = useRef([])

  useEffect(() => {
    setActiveIndex(0)
    setFlying(null)
    setDraggingIdx(null)
    busyRef.current = false
  }, [items])

  useEffect(() => () => {
    timersRef.current.forEach(clearTimeout)
  }, [])

  const stepDeck = useCallback((delta, flingDir) => {
    if (busyRef.current || count < 2) return
    const currentIdx = activeIndex
    const nextIdx = (activeIndex + delta + count) % count
    if (reducedMotion) {
      setActiveIndex(nextIdx)
      return
    }
    busyRef.current = true
    setFlying({ idx: currentIdx, dir: flingDir })
    const timer = window.setTimeout(() => {
      setFlying(null)
      setActiveIndex(nextIdx)
      busyRef.current = false
    }, 280)
    timersRef.current.push(timer)
  }, [activeIndex, count, reducedMotion])

  const goNext = useCallback((dir = -1) => stepDeck(1, dir), [stepDeck])
  const goPrev = useCallback((dir = 1) => stepDeck(-1, dir), [stepDeck])

  if (count < 2) return null

  const topEvent = items[activeIndex] || items[0]
  const onKeyDown = event => {
    if (event.key === 'ArrowRight') {
      event.preventDefault()
      goNext(-1)
    } else if (event.key === 'ArrowLeft') {
      event.preventDefault()
      goPrev(1)
    }
  }

  return (
    <section
      data-testid="event-stub-deck"
      role="region"
      aria-roledescription="carousel"
      aria-labelledby="featured-deck-heading"
      tabIndex={0}
      onKeyDown={onKeyDown}
      className="pt-9 sm:pt-12 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-4 rounded-2xl"
    >
      <div className="mb-4 flex items-baseline justify-between gap-3">
        <h2 id="featured-deck-heading" className="font-display text-2xl font-bold text-neutral-950 sm:text-3xl">
          {t('pass.home.featuredOnGuam')}
        </h2>
        <span className="text-sm font-medium tabular-nums text-content-muted" aria-hidden="true">
          {activeIndex + 1} / {count}
        </span>
      </div>

      <p className="sr-only" aria-live="polite" data-testid="deck-live-status">
        {activeIndex + 1} of {count}: {topEvent.title}
      </p>

      <div className="stub-deck mx-auto grid w-full max-w-[22rem] pb-6">
        {items.map((ev, idx) => {
          const depth = (idx - activeIndex + count) % count
          const isTop = depth === 0
          const isFlying = flying?.idx === idx
          const isDragging = draggingIdx === idx
          const hasArt = approvedImageUrl(ev.cover_image_url, ev.image_asset_host) && !failedArt[ev.id]
          const summary = priceSummary(ev.ticket_types)
          const categoryText = ev.category && ev.category !== 'other'
            ? t(`buyer.categories.${ev.category}`, { defaultValue: ev.category_label || ev.category })
            : t('pass.home.featuredOnGuam')
          const place = [ev.venue_name, ev.venue_city].filter(Boolean).join(' · ')
          const eventPath = `/events/${ev.slug || ev.id}`

          const style = {
            zIndex: count - depth,
            ...(isDragging
              ? {}
              : isFlying
                ? {
                    transform: `translate3d(${flying.dir * 115}%, 0, 0) rotate(${flying.dir * 8}deg)`,
                    opacity: 0,
                  }
                : {
                    transform: stackTransform(depth),
                    opacity: depth > 2 ? 0 : 1,
                  }),
          }

          return (
            <article
              key={ev.id}
              ref={el => { cardRefs.current[idx] = el }}
              data-deck-card={idx}
              data-top={String(isTop)}
              data-depth={depth}
              data-dragging={isDragging ? 'true' : undefined}
              aria-hidden={isTop ? undefined : true}
              inert={isTop ? undefined : INERT_VALUE}
              className="stub-deck-card text-content"
              style={style}
              onPointerDown={e => {
                if (!isTop || dragRef.current || busyRef.current || e.target.closest('a, button')) return
                if (e.pointerType === 'mouse' && e.button !== 0) return
                dragRef.current = {
                  idx,
                  x0: e.clientX,
                  y0: e.clientY,
                  t0: performance.now(),
                  dx: 0,
                  dy: 0,
                  moved: 0,
                  locked: null,
                  id: e.pointerId,
                }
                e.currentTarget.setPointerCapture?.(e.pointerId)
              }}
              onPointerMove={e => {
                const d = dragRef.current
                if (!d || d.id !== e.pointerId || d.idx !== idx) return
                d.dx = e.clientX - d.x0
                d.dy = e.clientY - d.y0
                d.moved = Math.max(d.moved, Math.hypot(d.dx, d.dy))
                if (!d.locked) {
                  if (d.moved < 8) return
                  if (Math.abs(d.dy) > Math.abs(d.dx)) {
                    // Vertical scroll wins: release capture so the page scrolls naturally.
                    e.currentTarget.releasePointerCapture?.(e.pointerId)
                    dragRef.current = null
                    setDraggingIdx(null)
                    return
                  }
                  d.locked = 'x'
                  if (!reducedMotion) setDraggingIdx(idx)
                }
                if (d.locked === 'x' && !reducedMotion) {
                  const cardEl = cardRefs.current[idx]
                  const tilt = Math.max(-6, Math.min(6, d.dx * 0.04))
                  if (cardEl) cardEl.style.transform = `translate3d(${d.dx.toFixed(1)}px, 0, 0) rotate(${tilt.toFixed(2)}deg)`
                }
              }}
              onPointerUp={e => {
                const d = dragRef.current
                if (!d || d.id !== e.pointerId) return
                dragRef.current = null
                setDraggingIdx(null)
                const cardEl = cardRefs.current[idx]
                const elapsed = Math.max(1, performance.now() - d.t0)
                const velocity = Math.abs(d.dx) / elapsed
                if (d.moved < 6) {
                  if (cardEl) cardEl.style.transform = 'none'
                  navigate(eventPath, { state: { browseFrom: `${location.pathname}${location.search}` } })
                  return
                }
                if (d.locked === 'x' && (Math.abs(d.dx) > 80 || (velocity > 0.5 && Math.abs(d.dx) > 24))) {
                  if (d.dx > 0) goPrev(1)
                  else goNext(-1)
                } else if (cardEl) {
                  cardEl.style.transform = 'none'
                }
              }}
              onPointerCancel={e => {
                const d = dragRef.current
                if (!d || d.id !== e.pointerId) return
                dragRef.current = null
                setDraggingIdx(null)
                const cardEl = cardRefs.current[idx]
                if (cardEl) cardEl.style.transform = 'none'
              }}
            >
              {isTop ? (
                <div className="ticket featured-ticket ticket-shadow-light">
                  <TicketTop>
                    <div className="relative aspect-video overflow-hidden bg-brand-800">
                      {hasArt ? (
                        <img
                          src={ev.cover_image_url}
                          alt=""
                          width="800"
                          height="450"
                          loading="lazy"
                          draggable={false}
                          onError={() => setFailedArt(prev => ({ ...prev, [ev.id]: true }))}
                          className="h-full w-full object-cover"
                          style={{ objectPosition: focalPosition(ev.page_customization) }}
                        />
                      ) : (
                        <div aria-hidden="true" className="flex h-full flex-col items-start justify-end p-5 text-white">
                          <span className="font-display text-xs font-semibold uppercase tracking-[0.14em] text-brand-200">
                            {formatEventDate(ev.starts_at, ev.timezone, { month: 'short', day: undefined, year: undefined })}
                          </span>
                          <span className="font-display text-5xl font-bold leading-none">
                            {formatEventDate(ev.starts_at, ev.timezone, { month: undefined, day: 'numeric', year: undefined })}
                          </span>
                        </div>
                      )}
                    </div>
                    <div className="px-5 pb-5 pt-4">
                      <p className="text-xs font-semibold uppercase tracking-[0.08em] text-brand-700">{categoryText}</p>
                      <div className="mt-2.5 flex items-start gap-3">
                        <EventDateTile event={ev} compact />
                        <div className="min-w-0 flex-1">
                          <h3 className="font-display text-lg font-bold leading-snug text-neutral-950 line-clamp-2">
                            {ev.title}
                          </h3>
                          {place && <p className="mt-1 truncate text-sm text-content-muted">{place}</p>}
                        </div>
                      </div>
                    </div>
                  </TicketTop>
                  <TicketStub className="flex items-center justify-between gap-3 px-5 py-4">
                    <div className="min-w-0">
                      {summary ? (
                        <>
                          <strong className="block font-display text-lg font-bold tabular-nums text-neutral-950">
                            {summary.kind === 'free'
                              ? t('events.free')
                              : `${t('events.from')} ${formatTicketPrice(summary.cents)}`}
                          </strong>
                          {summary.kind === 'from' && summary.hasFree && (
                            <span className="block text-xs text-content-muted">{t('events.freeTicketsAvailable')}</span>
                          )}
                        </>
                      ) : (
                        <span className="text-sm font-medium text-content-muted">{t('events.ticketsAvailable')}</span>
                      )}
                    </div>
                    <Link
                      to={eventPath}
                      state={{ browseFrom: `${location.pathname}${location.search}` }}
                      className="btn-primary !min-h-11 shrink-0 whitespace-nowrap !px-4 !py-2 text-sm gap-1.5"
                    >
                      {t('pass.home.seeTickets')}
                      <ArrowRight aria-hidden="true" className="h-4 w-4" />
                    </Link>
                  </TicketStub>
                </div>
              ) : (
                /* Back cards render as blank white ticket stock so nothing peeks under the top card. */
                <div className="ticket featured-ticket ticket-shadow-light h-full flex flex-col">
                  <TicketTop className="flex-1 bg-white" />
                  <TicketStub className="h-[4.75rem] bg-white" />
                </div>
              )}
            </article>
          )
        })}
      </div>

      <div className="mt-4 flex items-center justify-center gap-4">
        <button
          type="button"
          onClick={() => goPrev(1)}
          aria-label="Previous featured event"
          className="tactile-press inline-flex h-11 w-11 items-center justify-center rounded-full border border-neutral-300 bg-white text-neutral-900 hover:border-brand-300 hover:bg-brand-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2"
        >
          <ChevronLeft aria-hidden="true" className="h-5 w-5" />
        </button>

        <div className="flex items-center gap-2" aria-hidden="true">
          {items.map((ev, idx) => (
            <span
              key={ev.id}
              data-active={String(idx === activeIndex)}
              className={`h-2 rounded-full transition-[width,background-color] duration-200 ease-out-strong ${
                idx === activeIndex ? 'w-5 bg-brand-700' : 'w-2 bg-neutral-300'
              }`}
            />
          ))}
        </div>

        <button
          type="button"
          onClick={() => goNext(-1)}
          aria-label="Next featured event"
          className="tactile-press inline-flex h-11 w-11 items-center justify-center rounded-full border border-neutral-300 bg-white text-neutral-900 hover:border-brand-300 hover:bg-brand-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2"
        >
          <ChevronRight aria-hidden="true" className="h-5 w-5" />
        </button>
      </div>
    </section>
  )
}
