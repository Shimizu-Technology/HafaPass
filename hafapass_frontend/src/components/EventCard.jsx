import { focalPosition, approvedImageUrl } from '../utils/eventPageDesign'
import useTranslatedContent from '../hooks/useTranslatedContent'
import MachineTranslationNotice from './MachineTranslationNotice'
import EventDateTile from './EventDateTile'
import { Link, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Calendar, MapPin, Clock, ArrowRight } from 'lucide-react'
import { WhosGoingBadge } from './WhosGoing'
import { formatEventDate, formatEventTime } from '../utils/eventTime'
import { formatTicketPrice, lowestPurchasablePrice, isTicketPurchasable, remainingTickets, ticketAllInCents, ticketServiceFeeCents } from '../utils/ticketPricing'

export default function EventCard({ event }) {
  const { t } = useTranslation()
  const location = useLocation()
  const content = useTranslatedContent(event)
  const hasArtwork = approvedImageUrl(event.cover_image_url, event.image_asset_host)
  const lowestPrice = lowestPurchasablePrice(event.ticket_types)
  const lowestTicket = event.ticket_types?.find(ticket => isTicketPurchasable(ticket) && ticketAllInCents(ticket) === lowestPrice)
  const priceLabel = lowestPrice === null ? ''
    : lowestPrice === 0 ? t('events.free')
    : `${t('events.from')} ${formatTicketPrice(lowestPrice)}`
  const hasAvailability = !event.ticket_types || event.ticket_types.some(isTicketPurchasable)
  const hasInventory = !event.ticket_types || event.ticket_types.some(ticket => remainingTickets(ticket) === null || remainingTickets(ticket) > 0)

  return (
    <Link
      to={`/events/${event.slug}`}
      state={{ browseFrom: `${location.pathname}${location.search}` }}
      className="group flex flex-col card card-hover overflow-hidden h-full"
    >
      {/* Image */}
      <div className={hasArtwork ? 'aspect-[16/10] overflow-hidden bg-neutral-100 relative rounded-t-2xl' : 'relative px-5 pt-5'}>
        {hasArtwork ? (
          <img
            src={event.cover_image_url}
            alt={content.title}
            width="800" height="500"
            className="w-full h-full object-cover"
            style={{ objectPosition: focalPosition(event.page_customization) }}
          />
        ) : (
          <EventDateTile event={event} />
        )}
        {/* Completed overlay */}
        {event.status === 'completed' && (
          <div className="absolute inset-0 bg-black/40 flex items-center justify-center">
            <span className="bg-neutral-900/80 text-white text-sm font-bold px-4 py-1.5 rounded-full backdrop-blur-sm">
              {t('events.pastEvent')}
            </span>
          </div>
        )}

        {/* Price badge */}
        {priceLabel && (
          <div className="absolute top-3 right-3">
            <span className={`inline-flex flex-col items-center px-3 py-1 rounded-full text-sm font-semibold tabular-nums border border-neutral-200 ${
              lowestPrice === 0
                ? 'bg-emerald-700 text-white'
                : 'bg-white text-neutral-900'
            }`}>
              {priceLabel}
              {lowestTicket && ticketServiceFeeCents(lowestTicket) > 0 && <span className="text-xs font-normal">{t('buyer.SeatSelector.feeIncluded', { fee: formatTicketPrice(ticketServiceFeeCents(lowestTicket)) })}</span>}
            </span>
          </div>
        )}
      </div>

      <div className="p-5 flex flex-col flex-1">
        {/* Category badge */}
        {event.category && event.category !== 'other' && (
          <span className="inline-block text-sm font-semibold text-brand-800 mb-2">
            {t(`buyer.categories.${event.category}`, { defaultValue: event.category_label || event.category })}
          </span>
        )}

        <h3 className="text-lg font-semibold text-neutral-900 mb-3 group-hover:text-brand-600 transition-colors duration-200 line-clamp-2 min-h-[3.5rem]">
          {content.title}
        </h3>
        {/* Cards link to the event, so the "Show original" switch lives on the event page. */}
        {content.notice && <MachineTranslationNotice {...content.notice} labelOnly className="-mt-2 mb-3" />}

        <div className="space-y-1.5 mb-4 flex-1">
          {event.starts_at && (
            <div className="flex items-center gap-2 text-sm text-neutral-600">
              <Calendar className="w-3.5 h-3.5 text-neutral-500" />
              <span>{formatEventDate(event.starts_at, event.timezone)}</span>
              <Clock className="w-3.5 h-3.5 text-neutral-500 ml-1" />
              <span>{formatEventTime(event.starts_at, event.timezone)}</span>
            </div>
          )}
          {event.venue_name && (
            <div className="flex items-center gap-2 text-sm text-neutral-600">
              <MapPin className="w-3.5 h-3.5 text-neutral-500" />
              <span className="truncate">{event.venue_name}</span>
            </div>
          )}
        </div>

        {event.attendee_count > 0 && (
          <div className="mb-3">
            <WhosGoingBadge attendeeCount={event.attendee_count} />
          </div>
        )}

        <div className="flex items-center justify-between pt-3 border-t border-neutral-100">
          {/* Availability indicator */}
          <div className="flex items-center gap-1.5">
            {event.status === 'completed' ? (
              <>
                <span className="w-1.5 h-1.5 rounded-full bg-neutral-300" />
                <span className="text-xs font-medium text-content-muted">{t('events.completed')}</span>
              </>
            ) : (
              <>
                <span className={`w-1.5 h-1.5 rounded-full ${hasAvailability ? 'bg-emerald-400' : 'bg-neutral-300'}`} />
                <span className={`text-xs font-medium ${hasAvailability ? 'text-emerald-700' : 'text-neutral-600'}`}>
                  {hasAvailability ? t('events.ticketsAvailable') : hasInventory
                    ? t('events.salesUnavailable') : t('events.soldOut')}
                </span>
              </>
            )}
          </div>
          <span className="inline-flex items-center gap-1 text-sm font-medium text-neutral-600 group-hover:text-brand-700 transition-colors duration-150">
            {t('common.view')}
            <ArrowRight className="w-3.5 h-3.5" />
          </span>
        </div>
      </div>
    </Link>
  )
}
