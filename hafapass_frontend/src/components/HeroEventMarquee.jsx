import { useMemo, useState } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Calendar, MapPin, Pause, Play } from 'lucide-react'
import { TicketTop, TicketStub } from './Ticket'
import usePrefersReducedMotion from '../hooks/usePrefersReducedMotion'
import useTranslatedContent from '../hooks/useTranslatedContent'
import { approvedImageUrl, focalPosition } from '../utils/eventPageDesign'
import { formatEventDate } from '../utils/eventTime'
import { formatTicketPrice, lowestPurchasablePrice, remainingTickets } from '../utils/ticketPricing'

function MarqueeTicketCard({ event, decorative = false }) {
  const { t } = useTranslation()
  const location = useLocation()
  const content = useTranslatedContent(event)
  const [failedArtwork, setFailedArtwork] = useState(null)
  const hasArtwork = approvedImageUrl(event.cover_image_url, event.image_asset_host) && failedArtwork !== event.cover_image_url
  const lowestPrice = lowestPurchasablePrice(event.ticket_types)
  const hasInventory = !event.ticket_types || event.ticket_types.some(ticket => remainingTickets(ticket) === null || remainingTickets(ticket) > 0)
  const place = event.venue_city || event.venue_name || 'Guam'

  return (
    <Link
      to={`/events/${event.slug || event.id}`}
      state={{ browseFrom: `${location.pathname}${location.search}` }}
      tabIndex={decorative ? -1 : 0}
      aria-hidden={decorative || undefined}
      draggable={false}
      className="hero-marquee-card block w-[258px] shrink-0 rounded-[1.25rem] sm:w-[292px]"
    >
      <div className="ticket event-ticket text-content">
        <TicketTop>
          <div className="relative aspect-video overflow-hidden bg-brand-800">
            {hasArtwork ? (
              <img
                src={event.cover_image_url}
                alt=""
                width="1600"
                height="900"
                loading={decorative ? 'lazy' : 'eager'}
                draggable={false}
                onError={() => setFailedArtwork(event.cover_image_url)}
                className="h-full w-full object-cover"
                style={{ objectPosition: focalPosition(event.page_customization) }}
              />
            ) : (
              <div aria-hidden="true" className="flex h-full flex-col items-start justify-end p-4 text-white">
                <span className="font-display text-xs font-semibold uppercase tracking-[0.14em] text-brand-200">
                  {formatEventDate(event.starts_at, event.timezone, { month: 'short', day: undefined, year: undefined })}
                </span>
                <span className="font-display text-4xl font-bold leading-none">
                  {formatEventDate(event.starts_at, event.timezone, { month: undefined, day: 'numeric', year: undefined })}
                </span>
              </div>
            )}
          </div>
        </TicketTop>
        <TicketStub className="flex flex-col px-4 pb-4 pt-3.5">
          <p className="line-clamp-2 min-h-[2.65rem] font-display text-[1.02rem] font-bold leading-snug text-neutral-950 [overflow-wrap:anywhere]">
            {content.title}
          </p>
          <div className="mt-2.5 flex items-center justify-between gap-2 text-xs text-content-muted">
            <span className="inline-flex min-w-0 items-center gap-1.5">
              <Calendar aria-hidden="true" className="h-3.5 w-3.5 shrink-0 text-brand-700" />
              <span className="truncate">{formatEventDate(event.starts_at, event.timezone, { weekday: 'short', year: undefined })}</span>
            </span>
            <span className="inline-flex min-w-0 items-center gap-1">
              <MapPin aria-hidden="true" className="h-3.5 w-3.5 shrink-0 text-brand-700" />
              <span className="truncate">{place}</span>
            </span>
          </div>
          <div className="mt-3 flex items-center justify-between border-t border-neutral-100 pt-2.5">
            <span className="font-display text-sm font-bold tabular-nums text-neutral-950">
              {lowestPrice === null
                ? (hasInventory ? t('events.salesUnavailable') : t('events.soldOut'))
                : lowestPrice === 0
                  ? t('events.free')
                  : `${t('events.from')} ${formatTicketPrice(lowestPrice)}`}
            </span>
            <span className="text-xs font-semibold text-brand-800">{t('pass.home.seeTickets')}</span>
          </div>
        </TicketStub>
      </div>
    </Link>
  )
}

/**
 * Hero 3: Slow, continuous horizontal marquee of upcoming Guam event tickets.
 * Pauses on hover, touch, focus-within, or manual pause toggle. Under
 * prefers-reduced-motion it becomes a clean, static horizontal scroll row.
 */
export default function HeroEventMarquee({ events = [] }) {
  const reducedMotion = usePrefersReducedMotion()
  const [userPaused, setUserPaused] = useState(false)
  const [touchPaused, setTouchPaused] = useState(false)

  const baseEvents = useMemo(() => {
    if (events.length === 0) return []
    // Ensure enough cards so a single half-track is wider than 1440px.
    const list = [...events]
    while (list.length < 5) list.push(...events)
    return list.slice(0, Math.max(5, events.length))
  }, [events])

  if (baseEvents.length === 0) return null

  const paused = reducedMotion || userPaused || touchPaused

  return (
    <div
      className="hero-marquee-section mt-6 sm:mt-10"
      data-testid="hero-event-marquee"
      data-paused={paused ? 'true' : 'false'}
      data-static={reducedMotion ? 'true' : 'false'}
    >
      <div className="mx-auto mb-3 flex max-w-6xl items-center justify-between gap-3 px-4 sm:px-6 lg:px-8">
        <p className="text-xs font-semibold uppercase tracking-[0.14em] text-brand-200/85">
          Upcoming passes across Guam
        </p>
        {!reducedMotion && (
          <button
            type="button"
            onClick={() => {
              if (userPaused || touchPaused) {
                setTouchPaused(false)
                setUserPaused(false)
              } else {
                setUserPaused(true)
              }
            }}
            aria-pressed={userPaused || touchPaused}
            aria-label={userPaused || touchPaused ? 'Resume event marquee' : 'Pause event marquee'}
            className="hero-marquee-toggle inline-flex min-h-11 items-center gap-1.5 rounded-full border border-white/15 bg-white/5 px-3.5 text-xs font-semibold text-brand-100"
          >
            {userPaused || touchPaused ? <Play aria-hidden="true" className="h-3.5 w-3.5" /> : <Pause aria-hidden="true" className="h-3.5 w-3.5" />}
            <span>{userPaused || touchPaused ? 'Play' : 'Pause'}</span>
          </button>
        )}
      </div>

      <div
        className={`hero-marquee-viewport ${reducedMotion ? 'hero-marquee-viewport-static' : ''}`}
        onTouchStart={() => setTouchPaused(true)}
        onPointerDown={event => {
          if (event.pointerType === 'touch') setTouchPaused(true)
        }}
      >
        <div
          className={`hero-marquee-track ${paused ? 'hero-marquee-paused' : ''}`}
        >
          <div className="hero-marquee-group">
            {baseEvents.map((event, idx) => (
              <MarqueeTicketCard key={`a-${event.id}-${idx}`} event={event} />
            ))}
          </div>
          {!reducedMotion && (
            <div className="hero-marquee-group" aria-hidden="true">
              {baseEvents.map((event, idx) => (
                <MarqueeTicketCard key={`b-${event.id}-${idx}`} event={event} decorative />
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
