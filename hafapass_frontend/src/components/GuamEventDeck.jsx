import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { ArrowRight } from 'lucide-react'
import { TicketTop, TicketStub } from './Ticket'
import usePrefersReducedMotion from '../hooks/usePrefersReducedMotion'
import { approvedImageUrl, focalPosition } from '../utils/eventPageDesign'
import { formatEventDate, formatEventTime } from '../utils/eventTime'
import { formatTicketPrice, lowestPurchasablePrice } from '../utils/ticketPricing'

const PIN_MAP = [
  { id: 'tamuning', match: /tamuning|tumon/i, cx: 53, cy: 48, label: 'Tamuning / Tumon' },
  { id: 'mangilao', match: /mangilao|barrigada|dededo|yigo/i, cx: 55, cy: 58, label: 'Mangilao' },
  { id: 'hagatna', match: /hag[aå]t[nñ]a|asana|piti|ag[aå]na/i, cx: 42, cy: 56, label: 'Hagåtña' },
]

function pinForEvent(event) {
  const city = `${event?.venue_city || ''} ${event?.venue_name || ''}`
  return PIN_MAP.find(p => p.match.test(city)) || PIN_MAP[1]
}

const GRADIENTS = [
  'linear-gradient(135deg, #043635, #0b6563)',
  'linear-gradient(135deg, #4c1d24, #c9362e)',
  'linear-gradient(135deg, #102a43, #0e504f)',
  'linear-gradient(135deg, #0b3b3a, #087e7a)',
]

function restTransform(depth) {
  const rot = depth === 0 ? 0 : depth % 2 ? 3.5 : -3
  return `translate3d(0, ${depth * 14}px, 0) scale(${(1 - depth * 0.05).toFixed(3)}) rotate(${rot}deg)`
}

/**
 * Option C bold spotlight: Guåhan island silhouette with live village pins
 * paired with a pointer-capture flickable event stub deck (CSG StoryDeck
 * velocity > 0.11 physics). Always paired with the normal scannable grid
 * below so repeat buyers never lose fast access.
 */
export default function GuamEventDeck({ events = [] }) {
  const location = useLocation()
  const reducedMotion = usePrefersReducedMotion()
  const items = useMemo(() => events.slice(0, 4), [events])
  const count = items.length

  const [order, setOrder] = useState(() => items.map((_, i) => i))
  const [shownCount, setShownCount] = useState(0)
  const [flying, setFlying] = useState(null) // { idx, dir }
  const [returning, setReturning] = useState(null)
  const [draggingIdx, setDraggingIdx] = useState(null)
  const busyRef = useRef(false)
  const dragRef = useRef(null)
  const cardRefs = useRef([])
  const timersRef = useRef([])

  useEffect(() => {
    setOrder(items.map((_, i) => i))
    setShownCount(0)
    setFlying(null)
    setReturning(null)
    busyRef.current = false
  }, [items])

  useEffect(() => () => {
    timersRef.current.forEach(clearTimeout)
  }, [])

  const sendBack = useCallback(dir => {
    if (busyRef.current || count < 2) return
    const topIdx = order[0]
    const rotate = () => {
      setOrder(prev => [...prev.slice(1), prev[0]])
      setShownCount(c => c + 1)
    }
    if (reducedMotion) {
      rotate()
      return
    }
    busyRef.current = true
    setFlying({ idx: topIdx, dir })
    const t = window.setTimeout(() => {
      setFlying(null)
      setReturning(topIdx)
      rotate()
      requestAnimationFrame(() => requestAnimationFrame(() => {
        setReturning(null)
        busyRef.current = false
      }))
    }, 250)
    timersRef.current.push(t)
  }, [count, order, reducedMotion])

  if (count < 2) return null

  const topEvent = items[order[0]] || items[0]
  const activePin = pinForEvent(topEvent)

  return (
    <section
      data-testid="guam-stub-deck"
      aria-labelledby="guam-deck-heading"
      className="border-t border-white/10 bg-brand-950 pb-14 pt-10 text-white sm:pb-16 sm:pt-12"
    >
      <div className="mx-auto grid max-w-6xl items-center gap-9 px-4 sm:px-6 lg:grid-cols-[minmax(0,0.95fr)_minmax(0,1.05fr)] lg:gap-14 lg:px-8">
        <div>
          <p className="text-xs font-bold uppercase tracking-[0.1em] text-brand-300">Around the island</p>
          <h2 id="guam-deck-heading" className="mt-2 font-display text-3xl font-bold leading-tight tracking-tight sm:text-4xl">
            Flick through what’s on across Guam.
          </h2>
          <p className="mt-3 max-w-[42ch] text-base leading-relaxed text-brand-100">
            Drag a ticket stub sideways or tap Next event to deal through featured passes while the active village lights up.
          </p>

          <div className="mt-6 flex items-center gap-4 rounded-2xl border border-brand-100/15 bg-white/5 px-4 py-4" aria-live="polite">
            <svg className="h-[92px] w-[66px] shrink-0 overflow-visible" viewBox="0 0 90 130" aria-hidden="true">
              <path
                className="guam-outline"
                d="M56 6 C68 12 76 26 70 42 C63 54 53 60 49 71 C46 80 51 95 45 109 C40 120 27 124 21 116 C15 108 18 93 24 81 C29 72 24 63 31 53 C38 43 44 26 48 14 C50 8 53 5 56 6 Z"
              />
              {PIN_MAP.map(pin => {
                const isActive = pin.id === activePin.id
                return (
                  <g key={pin.id}>
                    <circle
                      className="guam-pin-ring"
                      data-active={String(isActive)}
                      cx={pin.cx}
                      cy={pin.cy}
                      r="5"
                    />
                    <circle
                      className="guam-pin"
                      data-active={String(isActive)}
                      data-pin={pin.id}
                      cx={pin.cx}
                      cy={pin.cy}
                      r="4"
                    />
                  </g>
                )
              })}
            </svg>
            <div className="min-w-0">
              <p data-testid="deck-active-village" className="text-xs font-bold uppercase tracking-[0.08em] text-brand-300">
                {topEvent.venue_city || activePin.label} · Guam
              </p>
              <p className="mt-1 truncate font-display text-lg font-bold text-white">{topEvent.venue_name || topEvent.title}</p>
              {topEvent.starts_at && (
                <p className="mt-1 text-xs text-brand-100/85">
                  {formatEventDate(topEvent.starts_at, topEvent.timezone, { weekday: 'short', year: undefined })} · {formatEventTime(topEvent.starts_at, topEvent.timezone)}
                </p>
              )}
            </div>
          </div>

          <div className="mt-5 flex flex-wrap items-center gap-3">
            <button
              type="button"
              onClick={() => sendBack(-1)}
              className="tactile-press inline-flex min-h-11 items-center gap-2 rounded-xl border border-brand-100/35 bg-white/10 px-4 text-sm font-semibold text-white hover:bg-white/15 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-on-dark focus-visible:ring-offset-2 focus-visible:ring-offset-brand-950"
            >
              Next event stub
              <ArrowRight aria-hidden="true" className="h-4 w-4" />
            </button>
            <span data-testid="deck-counter" className="text-xs font-medium tabular-nums text-brand-100">
              Event {(shownCount % count) + 1} of {count}
            </span>
          </div>
        </div>

        <div className="stub-deck mx-auto grid w-full max-w-[24rem] pb-9">
          {items.map((ev, idx) => {
            const depth = order.indexOf(idx)
            const isTop = depth === 0
            const isFlying = flying?.idx === idx
            const isReturning = returning === idx
            const isDragging = draggingIdx === idx
            const hasArt = approvedImageUrl(ev.cover_image_url, ev.image_asset_host)
            const lowest = lowestPurchasablePrice(ev.ticket_types)
            const priceText = lowest === null ? 'See tickets' : lowest === 0 ? 'Free entry' : `From ${formatTicketPrice(lowest)}`

            const style = {
              zIndex: count - depth,
              ...(isDragging
                ? {}
                : isFlying
                  ? {
                      transform: `translate3d(${flying.dir * 120}%, -18px, 0) rotate(${flying.dir * 16}deg)`,
                      opacity: 0,
                    }
                  : {
                      transform: restTransform(depth),
                      opacity: isReturning ? 0 : 1,
                    }),
            }

            return (
              <article
                key={ev.id}
                ref={el => { cardRefs.current[idx] = el }}
                data-top={String(isTop)}
                data-dragging={isDragging ? 'true' : undefined}
                data-instant={isReturning ? 'true' : undefined}
                className="stub-deck-card text-content"
                style={style}
                onPointerDown={e => {
                  if (!isTop || dragRef.current || busyRef.current || e.target.closest('a, button')) return
                  if (e.pointerType === 'mouse' && e.button !== 0) return
                  dragRef.current = { idx, x0: e.clientX, t0: performance.now(), dx: 0, id: e.pointerId }
                  e.currentTarget.setPointerCapture?.(e.pointerId)
                  setDraggingIdx(idx)
                }}
                onPointerMove={e => {
                  const d = dragRef.current
                  if (!d || d.id !== e.pointerId || d.idx !== idx) return
                  d.dx = e.clientX - d.x0
                  const cardEl = cardRefs.current[idx]
                  if (cardEl) cardEl.style.transform = `translate3d(${d.dx}px, 0, 0) rotate(${(d.dx * 0.055).toFixed(2)}deg)`
                }}
                onPointerUp={e => {
                  const d = dragRef.current
                  if (!d || d.id !== e.pointerId) return
                  dragRef.current = null
                  setDraggingIdx(null)
                  const cardEl = cardRefs.current[idx]
                  if (cardEl) cardEl.style.transform = restTransform(0)
                  const vel = Math.abs(d.dx) / Math.max(1, performance.now() - d.t0)
                  if (Math.abs(d.dx) > 95 || (vel > 0.11 && Math.abs(d.dx) > 14)) {
                    sendBack(d.dx > 0 ? 1 : -1)
                  }
                }}
                onPointerCancel={e => {
                  const d = dragRef.current
                  if (!d || d.id !== e.pointerId) return
                  dragRef.current = null
                  setDraggingIdx(null)
                  const cardEl = cardRefs.current[idx]
                  if (cardEl) cardEl.style.transform = restTransform(0)
                }}
              >
                <div className="ticket featured-ticket">
                  <TicketTop>
                    <div
                      className="relative h-36 overflow-hidden p-4 text-white flex flex-col justify-between"
                      style={{ background: GRADIENTS[idx % GRADIENTS.length] }}
                    >
                      {hasArt && (
                        <img
                          src={ev.cover_image_url}
                          alt=""
                          loading="lazy"
                          draggable={false}
                          className="absolute inset-0 h-full w-full object-cover opacity-55"
                          style={{ objectPosition: focalPosition(ev.page_customization) }}
                        />
                      )}
                      <span className="relative z-[1] self-start rounded-full bg-brand-950/75 px-2.5 py-1 text-[11px] font-bold uppercase tracking-[0.08em] text-brand-100">
                        {ev.category_label || ev.category || 'Guam event'}
                      </span>
                      {ev.starts_at && (
                        <div className="relative z-[1]">
                          <span className="block text-[11px] font-bold uppercase tracking-[0.14em] text-brand-300">
                            {formatEventDate(ev.starts_at, ev.timezone, { month: 'short', day: undefined, year: undefined })}
                          </span>
                          <strong className="font-display text-4xl font-bold leading-none">
                            {formatEventDate(ev.starts_at, ev.timezone, { month: undefined, day: 'numeric', year: undefined })}
                          </strong>
                        </div>
                      )}
                    </div>
                    <div className="px-5 pb-5 pt-4">
                      <h3 className="font-display text-lg font-bold leading-snug text-neutral-950 line-clamp-2">{ev.title}</h3>
                      <p className="mt-1.5 text-xs text-content-muted">{[ev.venue_name, ev.venue_city].filter(Boolean).join(' · ')}</p>
                    </div>
                  </TicketTop>
                  <TicketStub className="flex items-center justify-between gap-3 px-5 py-4">
                    <strong className="font-display text-lg font-bold tabular-nums text-neutral-950">{priceText}</strong>
                    <Link
                      to={`/events/${ev.slug || ev.id}`}
                      state={{ browseFrom: `${location.pathname}${location.search}` }}
                      tabIndex={isTop ? undefined : -1}
                      className="btn-primary !min-h-11 !px-4 !py-2 text-sm gap-1.5"
                    >
                      See tickets
                      <ArrowRight aria-hidden="true" className="h-3.5 w-3.5" />
                    </Link>
                  </TicketStub>
                </div>
              </article>
            )
          })}
        </div>
      </div>
    </section>
  )
}
