import { useState } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ArrowRight, Calendar, MapPin } from 'lucide-react'
import { TicketTop, TicketStub } from './Ticket'
import useTranslatedContent from '../hooks/useTranslatedContent'
import { approvedImageUrl, focalPosition } from '../utils/eventPageDesign'
import { formatEventDate, formatEventTime } from '../utils/eventTime'
import { formatTicketPrice, lowestPurchasablePrice } from '../utils/ticketPricing'

/**
 * The next featured Guam event as a flat, straight perforated pass.
 * Keeps artwork uncropped and unobstructed, honors reduced motion, and opens
 * the event cleanly on tap, click, or keyboard Enter.
 */
export default function FeaturedPassStub({ event }) {
  const { t } = useTranslation()
  const location = useLocation()
  const content = useTranslatedContent(event)
  const [failedArtwork, setFailedArtwork] = useState(null)
  const hasArtwork = approvedImageUrl(event.cover_image_url, event.image_asset_host) && failedArtwork !== event.cover_image_url
  const lowestPrice = lowestPurchasablePrice(event.ticket_types)
  const place = [event.venue_name, event.venue_city].filter(Boolean).join(' · ')

  return (
    <div className="featured-pass-stage">
      <Link
        to={`/events/${event.slug || event.id}`}
        state={{ browseFrom: `${location.pathname}${location.search}` }}
        className="featured-pass block rounded-[1.25rem]"
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
            <div className="px-5 pb-5 pt-4 sm:px-6 sm:pb-6 sm:pt-5">
              <p className="text-xs font-semibold uppercase tracking-[0.1em] text-brand-800">
                {event.is_featured ? t('pass.home.featuredOnGuam') : t('pass.home.nextUpOnGuam')}
              </p>
              <p className="mt-1.5 font-display text-[1.4rem] font-bold leading-[1.15] tracking-[-0.02em] text-neutral-950 [overflow-wrap:anywhere] sm:text-2xl">
                {content.title}
              </p>
            </div>
          </TicketTop>
          <TicketStub>
            <div className="grid gap-2 px-5 pb-5 pt-4 text-[0.95rem] text-neutral-800 sm:px-6 sm:pb-6 sm:pt-5 sm:text-base">
              <p className="flex items-start gap-2.5">
                <Calendar aria-hidden="true" className="mt-1 h-4 w-4 shrink-0 text-brand-700" />
                <span>{formatEventDate(event.starts_at, event.timezone, { weekday: 'short', year: undefined })} · {formatEventTime(event.starts_at, event.timezone)}</span>
              </p>
              {place && (
                <p className="flex items-start gap-2.5">
                  <MapPin aria-hidden="true" className="mt-1 h-4 w-4 shrink-0 text-brand-700" />
                  <span className="min-w-0 [overflow-wrap:anywhere]">{place}</span>
                </p>
              )}
              <div className="mt-2.5 flex flex-wrap items-center justify-between gap-3">
                {lowestPrice === null ? <span /> : (
                  <p className="font-display text-xl font-bold tabular-nums text-neutral-950">
                    {lowestPrice === 0
                      ? <span>{t('events.free')}</span>
                      : <><span className="text-sm font-semibold text-neutral-700">{t('events.from')}</span> <span>{formatTicketPrice(lowestPrice)}</span></>}
                  </p>
                )}
                <span className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-action px-5 text-sm font-semibold text-white sm:min-h-12 sm:text-base">
                  {t('pass.home.seeTickets')}
                  <ArrowRight aria-hidden="true" className="h-4 w-4 shrink-0" />
                </span>
              </div>
            </div>
          </TicketStub>
        </div>
      </Link>
    </div>
  )
}
