import { useState } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ArrowRight, Calendar, MapPin } from 'lucide-react'
import { TicketTop, TicketStub } from './Ticket'
import useMotionOk from '../hooks/useMotionOk'
import useTilt from '../hooks/useTilt'
import useTranslatedContent from '../hooks/useTranslatedContent'
import { approvedImageUrl, focalPosition } from '../utils/eventPageDesign'
import { formatEventDate, formatEventTime } from '../utils/eventTime'
import { formatTicketPrice, lowestPurchasablePrice } from '../utils/ticketPricing'

// The pass rests a little turned, so it reads as a physical ticket.
const REST = Object.freeze({ x: 4, y: -9 })
const restTransform = `rotateX(${REST.x}deg) rotateY(${REST.y}deg)`

/**
 * The next featured Guam event as a perforated pass. A mouse makes it lean
 * toward the pointer; a sideways finger drag tilts it, and let go it glides
 * back to rest. Up-and-down drags still scroll the page, and a drag never
 * opens the event. Without motion it holds its resting pose. The whole pass is
 * one link, so a tap or Enter opens the event.
 */
export default function FeaturedPassStub({ event }) {
  const { t } = useTranslation()
  const location = useLocation()
  const content = useTranslatedContent(event)
  const motionOk = useMotionOk()
  const { ref, sheenRef, handlers } = useTilt({ enabled: motionOk, max: 9, rest: REST, touch: true })
  const [failedArtwork, setFailedArtwork] = useState(null)
  const hasArtwork = approvedImageUrl(event.cover_image_url, event.image_asset_host) && failedArtwork !== event.cover_image_url
  const lowestPrice = lowestPurchasablePrice(event.ticket_types)
  const place = [event.venue_name, event.venue_city].filter(Boolean).join(' · ')

  return (
    <div className="featured-pass-stage" {...handlers}>
      <Link
        ref={ref}
        to={`/events/${event.slug || event.id}`}
        state={{ browseFrom: `${location.pathname}${location.search}` }}
        className="featured-pass block rounded-[1.25rem]"
        style={{ transform: restTransform }}
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
    </div>
  )
}
