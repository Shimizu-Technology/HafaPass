import { useCallback, useEffect, useRef, useState } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ArrowRight, Calendar, MapPin, RotateCw } from 'lucide-react'
import { TicketTop, TicketStub } from './Ticket'
import useMotionOk from '../hooks/useMotionOk'
import useTranslatedContent from '../hooks/useTranslatedContent'
import { approvedImageUrl, focalPosition } from '../utils/eventPageDesign'
import { formatEventDate, formatEventTime } from '../utils/eventTime'
import { formatTicketPrice, lowestPurchasablePrice } from '../utils/ticketPricing'

// Non-scannable illustrative 21x21 QR pattern for the back of the hero pass.
const BACK_QR_PATH = (() => {
  const finder = (x, y) => [[0, 0], [14, 0], [0, 14]].find(([fx, fy]) => x >= fx && x < fx + 7 && y >= fy && y < fy + 7)
  let path = ''
  for (let y = 0; y < 21; y += 1) {
    for (let x = 0; x < 21; x += 1) {
      const c = finder(x, y)
      const on = c
        ? (x - c[0] === 0 || y - c[1] === 0 || x - c[0] === 6 || y - c[1] === 6 || (x - c[0] >= 2 && x - c[0] <= 4 && y - c[1] >= 2 && y - c[1] <= 4))
        : ((x * 7 + y * 13 + x * y) % 5 < 2)
      if (on) path += `M${x} ${y}h1v1h-1z`
    }
  }
  return path
})()

// Resting 3D turn so the pass reads immediately as physical ticket stock.
const REST_X = 4
const REST_Y = -9
const GLIDE_MS = 320
const EDGE_GUARD_DEG = 22
const DRAG_SLOP = 6
const DRAG_CLICK_MS = 80
const restTransform = `rotateX(${REST_X}deg) rotateY(${REST_Y}deg)`

const showsBackFace = deg => Math.cos((deg * Math.PI) / 180) < 0

function safeRestingAngle(deg) {
  const within = ((deg % 180) + 180) % 180
  if (Math.abs(within - 90) >= EDGE_GUARD_DEG) return deg
  return deg - within + (within < 90 ? 90 - EDGE_GUARD_DEG : 90 + EDGE_GUARD_DEG)
}

/**
 * Interactive 3D double-sided perforated hero pass (modelled on Tåno + Tåsi's
 * SpinBox). Supports mouse lean, sideways drag with 320ms exponential momentum
 * glide, 22-degree edge-avoidance, and a keyboard-accessible Flip button.
 * Works for both live events and the pre-launch empty state (`frontContent`).
 * Under reduced motion, swaps cleanly front/back with zero 3D glide.
 */
export default function FeaturedPassStub({ event = null, frontContent = null, showFlipControls = true }) {
  const { t } = useTranslation()
  const location = useLocation()
  const content = useTranslatedContent(event)
  const motionOk = useMotionOk()

  const stageRef = useRef(null)
  const bodyRef = useRef(null)
  const sheenRef = useRef(null)
  const stateRef = useRef({ angle: REST_Y, tiltX: REST_X, mode: null })
  const rafRef = useRef(0)
  const dragRef = useRef(null)
  const draggedRef = useRef(null)
  const forgetRef = useRef(0)
  const [flipped, setFlipped] = useState(false)
  const [failedArtwork, setFailedArtwork] = useState(null)

  const clearDragged = useCallback(() => {
    clearTimeout(forgetRef.current)
    draggedRef.current = null
  }, [])

  const stop = useCallback(() => {
    cancelAnimationFrame(rafRef.current)
    rafRef.current = 0
    stateRef.current.mode = null
  }, [])

  const paint = useCallback((animate = false) => {
    const { angle, tiltX } = stateRef.current
    const el = bodyRef.current
    if (el) {
      el.style.transition = animate && motionOk ? 'transform 520ms cubic-bezier(0.23, 1, 0.32, 1)' : 'none'
      el.style.transform = `rotateX(${Number(tiltX.toFixed(2))}deg) rotateY(${Number(angle.toFixed(2))}deg)`
    }
    if (sheenRef.current) {
      const norm = Math.sin((angle * Math.PI) / 180)
      sheenRef.current.style.transform = `translateX(${(-norm * 45).toFixed(1)}%)`
    }
    const back = showsBackFace(angle)
    setFlipped(prev => (prev === back ? prev : back))
  }, [motionOk])

  const settleOffEdge = useCallback(() => {
    stop()
    const target = safeRestingAngle(stateRef.current.angle)
    if (Math.abs(target - stateRef.current.angle) > 0.1) {
      stateRef.current.angle = target
      paint(true)
    }
  }, [paint, stop])

  const glide = useCallback(initialSpeed => {
    stop()
    if (!motionOk || Math.abs(initialSpeed) < 0.008) {
      settleOffEdge()
      return
    }
    stateRef.current.mode = 'glide'
    let speed = initialSpeed
    let last = performance.now()
    const tick = now => {
      const dt = Math.min(now - last, 64)
      last = now
      speed *= Math.exp(-dt / GLIDE_MS)
      stateRef.current.angle += speed * dt
      stateRef.current.tiltX += (REST_X - stateRef.current.tiltX) * (1 - Math.exp(-dt / 140))
      paint(false)
      if (Math.abs(speed) < 0.008) {
        settleOffEdge()
        return
      }
      rafRef.current = requestAnimationFrame(tick)
    }
    rafRef.current = requestAnimationFrame(tick)
  }, [motionOk, paint, settleOffEdge, stop])

  // Snap to clean resting pose when reduced motion toggles off.
  useEffect(() => {
    if (motionOk) return undefined
    stop()
    dragRef.current = null
    const back = showsBackFace(stateRef.current.angle)
    stateRef.current.angle = back ? 180 + REST_Y : REST_Y
    stateRef.current.tiltX = REST_X
    paint(false)
    return undefined
  }, [motionOk, paint, stop])

  useEffect(() => () => { stop(); clearTimeout(forgetRef.current) }, [stop])

  const handleFlip = useCallback(() => {
    stop()
    const cur = stateRef.current.angle
    const back = showsBackFace(cur)
    if (!motionOk) {
      stateRef.current.angle = back ? REST_Y : 180 + REST_Y
      stateRef.current.tiltX = REST_X
      paint(false)
      return
    }
    const base = Math.round((cur - REST_Y) / 180) * 180 + REST_Y
    stateRef.current.angle = showsBackFace(base) === back ? base + 180 : base
    stateRef.current.tiltX = REST_X
    paint(true)
  }, [motionOk, paint, stop])

  const endDrag = useCallback((e, cancelled = false) => {
    const d0 = dragRef.current
    if (!d0 || d0.id !== e.pointerId) return
    dragRef.current = null
    if (d0.moved) {
      const speed = cancelled || (e.timeStamp - d0.at) > 90
        ? 0
        : Math.max(-0.9, Math.min(0.9, d0.speed))
      glide(speed)
      clearTimeout(forgetRef.current)
      if (!cancelled && draggedRef.current?.id === e.pointerId) {
        forgetRef.current = window.setTimeout(() => { draggedRef.current = null }, DRAG_CLICK_MS)
      } else {
        draggedRef.current = null
      }
    }
  }, [glide])

  const stageHandlers = !motionOk ? {} : {
    onPointerDown: e => {
      if (!dragRef.current) clearDragged()
      if (e.pointerType === 'mouse' && e.button !== 0) return
      if (dragRef.current) return
      dragRef.current = { id: e.pointerId, type: e.pointerType, x: e.clientX, y: e.clientY, from: stateRef.current.angle, moved: false, at: e.timeStamp, speed: 0 }
      if (stateRef.current.mode === 'glide') stop()
    },
    onPointerMove: e => {
      const d = dragRef.current
      if (d && d.id === e.pointerId) {
        const dx = e.clientX - d.x
        const dy = e.clientY - d.y
        if (!d.moved) {
          if (Math.abs(dx) < DRAG_SLOP) return
          if (Math.abs(dy) > Math.abs(dx)) { dragRef.current = null; return }
          d.moved = true
          stop()
          d.from = stateRef.current.angle
          d.x = e.clientX
          d.at = e.timeStamp
          draggedRef.current = { id: d.id, type: d.type }
          e.currentTarget.setPointerCapture?.(e.pointerId)
          return
        }
        const next = d.from + dx * 0.55
        const dt = Math.max(1, e.timeStamp - d.at)
        d.speed = d.speed * 0.4 + ((next - stateRef.current.angle) / dt) * 0.6
        d.at = e.timeStamp
        stateRef.current.angle = next
        paint(false)
        return
      }
      if (e.pointerType === 'mouse' && !dragRef.current && !stateRef.current.mode && !showsBackFace(stateRef.current.angle)) {
        const rect = e.currentTarget.getBoundingClientRect()
        if (!rect.width || !rect.height) return
        const px = ((e.clientX - rect.left) / rect.width) * 2 - 1
        const py = ((e.clientY - rect.top) / rect.height) * 2 - 1
        stateRef.current.angle = REST_Y + Math.max(-1, Math.min(1, px)) * 11
        stateRef.current.tiltX = REST_X - Math.max(-1, Math.min(1, py)) * 6
        paint(false)
      }
    },
    onPointerLeave: e => {
      if (e.pointerType === 'mouse' && !dragRef.current && !stateRef.current.mode && !showsBackFace(stateRef.current.angle)) {
        stateRef.current.angle = REST_Y
        stateRef.current.tiltX = REST_X
        paint(true)
      }
    },
    onPointerUp: e => endDrag(e, false),
    onPointerCancel: e => endDrag(e, true),
    onLostPointerCapture: e => endDrag(e, true),
    onClickCapture: e => {
      const by = draggedRef.current
      const { pointerId, pointerType } = e.nativeEvent
      const samePointer = Boolean(by) && pointerId === by.id && pointerType === by.type
      const swallow = Boolean(samePointer) && e.detail !== 0
      clearDragged()
      if (!swallow) return
      e.preventDefault()
      e.stopPropagation()
    },
    style: { touchAction: 'pan-y pinch-zoom' },
  }

  const hasArtwork = Boolean(event) && approvedImageUrl(event.cover_image_url, event.image_asset_host) && failedArtwork !== event.cover_image_url
  const lowestPrice = event ? lowestPurchasablePrice(event.ticket_types) : null
  const place = event ? [event.venue_name, event.venue_city].filter(Boolean).join(' · ') : ''

  return (
    <div className="flex flex-col items-center gap-3.5" data-testid="featured-pass-3d">
      <div ref={stageRef} className="featured-pass-stage" {...stageHandlers}>
        <div
          ref={bodyRef}
          className="featured-pass-body"
          data-flipped={flipped ? 'true' : 'false'}
          style={{ transform: restTransform }}
        >
          {/* FRONT FACE */}
          <div className={`featured-pass-face featured-pass-front${flipped ? ' pointer-events-none' : ''}`} aria-hidden={flipped || undefined}>
            {frontContent || (event && (
              <Link
                to={`/events/${event.slug || event.id}`}
                state={{ browseFrom: `${location.pathname}${location.search}` }}
                className="featured-pass block rounded-[1.25rem]"
                tabIndex={flipped ? -1 : undefined}
                draggable={false}
              >
                <div className="ticket featured-ticket text-content">
                  <TicketTop>
                    <div className="relative aspect-[5/2] overflow-hidden bg-brand-800">
                      {hasArtwork ? <img
                        src={event.cover_image_url}
                        alt=""
                        width="800" height="450"
                        fetchpriority="high"
                        draggable={false}
                        onError={() => setFailedArtwork(event.cover_image_url)}
                        className="h-full w-full object-cover"
                        style={{ objectPosition: focalPosition(event.page_customization) }}
                      /> : <div aria-hidden="true" className="flex h-full flex-col items-start justify-end p-6 text-white">
                        <span className="font-display text-sm font-semibold uppercase tracking-[0.16em] text-brand-200">{formatEventDate(event.starts_at, event.timezone, { month: 'short', day: undefined, year: undefined })}</span>
                        <span className="font-display text-6xl font-bold leading-none">{formatEventDate(event.starts_at, event.timezone, { month: undefined, day: 'numeric', year: undefined })}</span>
                      </div>}
                      <span ref={sheenRef} aria-hidden="true" className="featured-pass-sheen" />
                    </div>
                    <div className="px-6 pb-6 pt-5">
                      <p className="text-sm font-semibold text-brand-800">{event.is_featured ? t('pass.home.featuredOnGuam') : t('pass.home.nextUpOnGuam')}</p>
                      <p className="mt-1 font-display text-2xl font-bold leading-tight text-neutral-950 [overflow-wrap:anywhere]">{content.title}</p>
                    </div>
                  </TicketTop>
                  <TicketStub>
                    <div className="grid gap-2 px-6 pb-6 pt-5 text-base text-neutral-800">
                      <p className="flex items-start gap-2"><Calendar aria-hidden="true" className="mt-1 h-4 w-4 shrink-0 text-brand-700" /><span>{formatEventDate(event.starts_at, event.timezone, { weekday: 'short', year: undefined })} · {formatEventTime(event.starts_at, event.timezone)}</span></p>
                      {place && <p className="flex items-start gap-2"><MapPin aria-hidden="true" className="mt-1 h-4 w-4 shrink-0 text-brand-700" /><span className="min-w-0 [overflow-wrap:anywhere]">{place}</span></p>}
                      <div className="mt-2 flex flex-wrap items-center justify-between gap-3">
                        {lowestPrice === null ? <span /> : <p className="font-display text-xl font-bold text-neutral-950">
                          {lowestPrice === 0 ? <span>{t('events.free')}</span> : <><span className="text-base font-semibold text-neutral-700">{t('events.from')}</span> <span>{formatTicketPrice(lowestPrice)}</span></>}
                        </p>}
                        <span className="inline-flex min-h-12 items-center gap-2 rounded-xl bg-action px-5 font-semibold text-white">{t('pass.home.seeTickets')}<ArrowRight aria-hidden="true" className="h-4 w-4" /></span>
                      </div>
                    </div>
                  </TicketStub>
                </div>
              </Link>
            ))}
          </div>

          {/* BACK FACE — Instant Phone Ticket QR guarantee */}
          <div className={`featured-pass-face featured-pass-back${flipped ? '' : ' pointer-events-none'}`} aria-hidden={!flipped || undefined}>
            <div className="ticket featured-ticket flex h-full flex-col text-content">
              <TicketTop className="flex flex-1 flex-col items-center justify-center px-6 py-6 text-center">
                <span className="inline-flex items-center gap-1.5 rounded-full bg-emerald-100 px-3 py-1 text-xs font-bold text-emerald-900">
                  <span aria-hidden="true" className="h-2 w-2 rounded-full bg-emerald-600" />
                  Ready for door scan
                </span>
                <div className="my-3.5 h-36 w-36 rounded-2xl border border-neutral-300 bg-white p-2.5" aria-hidden="true">
                  <svg viewBox="-1 -1 23 23" className="h-full w-full" shapeRendering="crispEdges">
                    <path d={BACK_QR_PATH} fill="#0f172a" />
                  </svg>
                </div>
                <p className="font-display text-base font-bold text-neutral-950">Instant phone ticket · No app required</p>
                <p className="mt-1 max-w-[26ch] text-xs leading-relaxed text-content-muted">Arrives by email and Apple Wallet. Works even when venue signal drops.</p>
              </TicketTop>
              <TicketStub className="!bg-brand-50 px-6 py-4 text-center">
                <p className="text-[11px] font-bold uppercase tracking-[0.08em] text-brand-800">Sample pass · Illustrative</p>
                <p className="mt-1 text-xs font-medium text-neutral-700">Buyer: Avery Lindqvist · Order HP-DEMO</p>
              </TicketStub>
            </div>
          </div>
        </div>
      </div>

      {showFlipControls && (
        <div className="flex flex-wrap items-center justify-center gap-3 text-xs text-brand-100">
          <button
            type="button"
            onClick={handleFlip}
            aria-pressed={flipped}
            className="tactile-press inline-flex min-h-11 items-center gap-2 rounded-full border border-brand-100/35 bg-white/10 px-4 text-xs font-semibold text-white hover:bg-white/15 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-on-dark focus-visible:ring-offset-2 focus-visible:ring-offset-brand-950"
          >
            <RotateCw aria-hidden="true" className="h-3.5 w-3.5" />
            {flipped ? 'Flip to event front' : 'Flip to QR back'}
          </button>
          <span className="hidden text-brand-100/80 sm:inline">Drag sideways to turn</span>
        </div>
      )}
    </div>
  )
}
