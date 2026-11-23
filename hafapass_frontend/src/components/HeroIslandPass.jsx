import { useEffect, useRef, useState } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ArrowRight, Calendar, CheckCircle2, MapPin } from 'lucide-react'
import { TicketTop, TicketStub } from './Ticket'
import usePrefersReducedMotion from '../hooks/usePrefersReducedMotion'
import useTranslatedContent from '../hooks/useTranslatedContent'
import { approvedImageUrl, focalPosition } from '../utils/eventPageDesign'
import { formatEventDate, formatEventTime } from '../utils/eventTime'
import { formatTicketPrice, lowestPurchasablePrice } from '../utils/ticketPricing'

// Non-scannable 21x21 decorative QR mosaic split into 9 tile clusters so WAAPI
// can quietly assemble the pass once on load using composite-only transform +
// opacity (no main-thread rAF loop, zero third-party animation library).
const QR_CLUSTERS = (() => {
  const groups = [
    { id: 'finder-tl', dx: -9, dy: -8, delay: 40, duration: 420, path: '' },
    { id: 'finder-tr', dx: 9, dy: -8, delay: 90, duration: 420, path: '' },
    { id: 'finder-bl', dx: -9, dy: 8, delay: 140, duration: 420, path: '' },
    { id: 'band-0', dx: -6, dy: -5, delay: 200, duration: 460, path: '' },
    { id: 'band-1', dx: 6, dy: -6, delay: 250, duration: 460, path: '' },
    { id: 'band-2', dx: -7, dy: 4, delay: 300, duration: 480, path: '' },
    { id: 'band-3', dx: 7, dy: 5, delay: 350, duration: 480, path: '' },
    { id: 'band-4', dx: 4, dy: 8, delay: 400, duration: 480, path: '' },
    { id: 'band-5', dx: 8, dy: 7, delay: 450, duration: 480, path: '' },
  ]

  const finderIndex = (x, y) => {
    if (x < 7 && y < 7) return 0
    if (x >= 14 && y < 7) return 1
    if (x < 7 && y >= 14) return 2
    return -1
  }

  for (let y = 0; y < 21; y += 1) {
    for (let x = 0; x < 21; x += 1) {
      const f = finderIndex(x, y)
      let on = false
      if (f >= 0) {
        const fx = f === 1 ? 14 : 0
        const fy = f === 2 ? 14 : 0
        const dx = x - fx
        const dy = y - fy
        on = dx === 0 || dy === 0 || dx === 6 || dy === 6 || (dx >= 2 && dx <= 4 && dy >= 2 && dy <= 4)
      } else {
        on = (x * 7 + y * 13 + x * y) % 5 < 2
      }
      if (!on) continue
      const target = f >= 0 ? f : 3 + (Math.floor((x + y) / 7) % 6)
      groups[target].path += `M${x} ${y}h1v1h-1z`
    }
  }
  return groups
})()

/**
 * Hero 4 ("puzzle-site" signature): A flat, straight featured HåfaPass ticket
 * framed by a calm static Guåhan lagoon glow. On initial load (when motion is
 * allowed), the stub's decorative QR clusters quietly assemble once via WAAPI,
 * a single hairline scan passes over, and the badge settles into "Door ready".
 * Under prefers-reduced-motion it renders directly in its finished still state.
 */
export default function HeroIslandPass({ event }) {
  const { t } = useTranslation()
  const location = useLocation()
  const content = useTranslatedContent(event)
  const reducedMotion = usePrefersReducedMotion()
  const [failedArtwork, setFailedArtwork] = useState(null)
  const [settled, setSettled] = useState(reducedMotion)
  const clusterRefs = useRef([])
  const beamRef = useRef(null)
  const hasPlayedRef = useRef(false)

  const hasArtwork = approvedImageUrl(event.cover_image_url, event.image_asset_host) && failedArtwork !== event.cover_image_url
  const lowestPrice = lowestPurchasablePrice(event.ticket_types)
  const place = [event.venue_name, event.venue_city].filter(Boolean).join(' · ')

  useEffect(() => {
    if (reducedMotion) {
      setSettled(true)
      return undefined
    }
    if (hasPlayedRef.current) return undefined
    hasPlayedRef.current = true
    setSettled(false)

    const animations = []
    const canAnimate = typeof Element !== 'undefined' && typeof Element.prototype.animate === 'function'

    if (canAnimate) {
      QR_CLUSTERS.forEach((cluster, idx) => {
        const node = clusterRefs.current[idx]
        if (!node) return
        const anim = node.animate(
          [
            { transform: `translate3d(${cluster.dx}px, ${cluster.dy}px, 0) scale(0.9)`, opacity: 0.25 },
            { transform: 'translate3d(0px, 0px, 0) scale(1)', opacity: 1 },
          ],
          {
            duration: cluster.duration,
            delay: cluster.delay,
            easing: 'cubic-bezier(0.23, 1, 0.32, 1)',
            fill: 'backwards',
          },
        )
        animations.push(anim)
      })

      if (beamRef.current) {
        const beamAnim = beamRef.current.animate(
          [
            { transform: 'translate3d(0, -10%, 0)', opacity: 0 },
            { transform: 'translate3d(0, 15%, 0)', opacity: 0.9, offset: 0.2 },
            { transform: 'translate3d(0, 88%, 0)', opacity: 0.85, offset: 0.8 },
            { transform: 'translate3d(0, 105%, 0)', opacity: 0 },
          ],
          {
            duration: 420,
            delay: 760,
            easing: 'cubic-bezier(0.23, 1, 0.32, 1)',
            fill: 'both',
          },
        )
        animations.push(beamAnim)
      }
    }

    const settleTimer = window.setTimeout(() => setSettled(true), canAnimate ? 1120 : 0)
    return () => {
      window.clearTimeout(settleTimer)
      animations.forEach(anim => anim.cancel?.())
    }
  }, [reducedMotion])

  return (
    <div className="hero-island-stage relative mx-auto w-full max-w-[26.5rem]" data-testid="hero-island-pass" data-qr-settled={settled ? 'true' : 'false'}>
      <div aria-hidden="true" className="hero-island-glow" />
      <Link
        to={`/events/${event.slug || event.id}`}
        state={{ browseFrom: `${location.pathname}${location.search}` }}
        className="featured-pass relative block rounded-[1.25rem]"
        draggable={false}
      >
        <div className="ticket featured-ticket text-content">
          <TicketTop>
            <div className="relative aspect-video overflow-hidden bg-brand-800">
              {hasArtwork ? (
                <img
                  src={event.cover_image_url}
                  alt=""
                  width="1600"
                  height="900"
                  fetchpriority="high"
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
                  <span className="font-display text-6xl font-bold leading-none">
                    {formatEventDate(event.starts_at, event.timezone, { month: undefined, day: 'numeric', year: undefined })}
                  </span>
                </div>
              )}
            </div>
            <div className="px-5 pb-4 pt-4 sm:px-6 sm:pb-5 sm:pt-5">
              <p className="text-xs font-semibold uppercase tracking-[0.1em] text-brand-800">
                {event.is_featured ? t('pass.home.featuredOnGuam') : t('pass.home.nextUpOnGuam')}
              </p>
              <p className="mt-1 font-display text-[1.35rem] font-bold leading-[1.15] tracking-[-0.02em] text-neutral-950 [overflow-wrap:anywhere] sm:text-2xl">
                {content.title}
              </p>
              <div className="mt-2.5 grid gap-1 text-sm text-neutral-700">
                <p className="flex items-start gap-2">
                  <Calendar aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-brand-700" />
                  <span>{formatEventDate(event.starts_at, event.timezone, { weekday: 'short', year: undefined })} · {formatEventTime(event.starts_at, event.timezone)}</span>
                </p>
                {place && (
                  <p className="flex items-start gap-2">
                    <MapPin aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-brand-700" />
                    <span className="min-w-0 [overflow-wrap:anywhere]">{place}</span>
                  </p>
                )}
              </div>
            </div>
          </TicketTop>
          <TicketStub>
            <div className="flex items-center justify-between gap-4 px-5 pb-5 pt-4 sm:px-6 sm:pb-6 sm:pt-5">
              <div className="min-w-0 flex-1">
                <span
                  className={`hero-island-status inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-semibold ${settled ? 'bg-emerald-50 text-emerald-800' : 'bg-brand-50 text-brand-800'}`}
                >
                  <CheckCircle2 aria-hidden="true" className={`h-3.5 w-3.5 shrink-0 ${settled ? 'text-emerald-700' : 'text-brand-600'}`} />
                  <span>{settled ? 'Instant QR · Ready' : 'Building pass'}</span>
                </span>
                {lowestPrice !== null && (
                  <p className="mt-2.5 font-display text-xl font-bold tabular-nums text-neutral-950">
                    {lowestPrice === 0
                      ? <span>{t('events.free')}</span>
                      : <><span className="text-sm font-semibold text-neutral-700">{t('events.from')}</span> <span>{formatTicketPrice(lowestPrice)}</span></>}
                  </p>
                )}
                <span className="mt-3 inline-flex min-h-11 items-center gap-1.5 rounded-xl bg-action px-4 text-sm font-semibold text-white">
                  {t('pass.home.seeTickets')}
                  <ArrowRight aria-hidden="true" className="h-4 w-4 shrink-0" />
                </span>
              </div>

              <div
                aria-hidden="true"
                className="relative flex h-[86px] w-[86px] shrink-0 items-center justify-center overflow-hidden rounded-xl border border-neutral-200/90 bg-neutral-50 p-2 sm:h-[96px] sm:w-[96px]"
              >
                <svg viewBox="-1 -1 23 23" className="h-full w-full" shapeRendering="crispEdges">
                  {QR_CLUSTERS.map((cluster, idx) => (
                    <g
                      key={cluster.id}
                      ref={el => { clusterRefs.current[idx] = el }}
                      className="hero-island-qr-cluster"
                    >
                      <path d={cluster.path} fill="#0f172a" />
                    </g>
                  ))}
                </svg>
                <span ref={beamRef} className="hero-island-scan-beam" />
              </div>
            </div>
          </TicketStub>
        </div>
      </Link>
    </div>
  )
}
