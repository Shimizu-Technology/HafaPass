import { Link } from 'react-router-dom'
import { Calendar, MapPin, Clock, ArrowRight } from 'lucide-react'
import { WhosGoingBadge } from './WhosGoing'

export default function EventCard({ event }) {
  const formatDate = (dateStr) => {
    const date = new Date(dateStr)
    return date.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
  }

  const formatTime = (dateStr) => {
    const date = new Date(dateStr)
    return date.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })
  }

  const lowestPrice = event.ticket_types?.reduce((min, tt) => {
    if (tt.price_cents === 0) return min === null ? 0 : Math.min(min, 0)
    return min === null ? tt.price_cents : Math.min(min, tt.price_cents)
  }, null)

  const priceLabel = lowestPrice === null
    ? ''
    : lowestPrice === 0
    ? 'Free'
    : `From $${(lowestPrice / 100).toFixed(2)}`

  // Check ticket availability
  const totalAvailable = event.ticket_types?.reduce((sum, tt) => sum + (tt.quantity_available ?? 0), 0)
  const hasAvailability = totalAvailable === undefined || totalAvailable > 0

  return (
    <Link
      to={`/events/${event.slug}`}
      className="group flex flex-col card card-hover overflow-hidden h-full"
    >
      {/* Image */}
      <div className="aspect-[16/10] overflow-hidden bg-gradient-to-br from-brand-100 to-brand-200 relative rounded-t-2xl">
        {event.cover_image_url ? (
          <img
            src={event.cover_image_url}
            alt={event.title}
            className="w-full h-full object-cover transition-transform duration-700 ease-out group-hover:scale-105"
          />
        ) : (
          <div className="w-full h-full flex items-center justify-center">
            <svg className="w-16 h-16 text-brand-300" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1" strokeLinecap="round" strokeLinejoin="round">
              <path d="M2 9a3 3 0 0 1 0 6v2a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-2a3 3 0 0 1 0-6V7a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2Z" />
              <path d="M13 5v2" /><path d="M13 17v2" /><path d="M13 11v2" />
            </svg>
          </div>
        )}
        {/* Completed overlay */}
        {event.status === 'completed' && (
          <div className="absolute inset-0 bg-black/40 flex items-center justify-center">
            <span className="bg-neutral-900/80 text-white text-sm font-bold px-4 py-1.5 rounded-full backdrop-blur-sm">
              Past Event
            </span>
          </div>
        )}
        {/* Gradient overlay for depth */}
        <div className="absolute inset-0 bg-gradient-to-t from-black/20 via-transparent to-transparent opacity-0 group-hover:opacity-100 transition-opacity duration-500" />

        {/* Price badge */}
        {priceLabel && (
          <div className="absolute top-3 right-3">
            <span className={`inline-flex items-center px-3 py-1 rounded-full text-xs font-bold shadow-lg backdrop-blur-md ${
              lowestPrice === 0
                ? 'bg-emerald-500/90 text-white'
                : 'bg-white/90 text-neutral-900'
            }`}>
              {priceLabel}
            </span>
          </div>
        )}
      </div>

      <div className="p-5 flex flex-col flex-1">
        {/* Category badge */}
        {event.category && event.category !== 'other' && (
          <span className="inline-block text-xs font-semibold text-brand-600 uppercase tracking-wider mb-2">
            {event.category}
          </span>
        )}

        <h3 className="text-lg font-semibold text-neutral-900 mb-3 group-hover:text-brand-600 transition-colors duration-200 line-clamp-2 min-h-[3.5rem]">
          {event.title}
        </h3>

        <div className="space-y-1.5 mb-4 flex-1">
          {event.starts_at && (
            <div className="flex items-center gap-2 text-sm text-neutral-500">
              <Calendar className="w-3.5 h-3.5 text-neutral-400" />
              <span>{formatDate(event.starts_at)}</span>
              <Clock className="w-3.5 h-3.5 text-neutral-400 ml-1" />
              <span>{formatTime(event.starts_at)}</span>
            </div>
          )}
          {event.venue_name && (
            <div className="flex items-center gap-2 text-sm text-neutral-500">
              <MapPin className="w-3.5 h-3.5 text-neutral-400" />
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
                <span className="text-xs font-medium text-neutral-400">Completed</span>
              </>
            ) : (
              <>
                <span className={`w-1.5 h-1.5 rounded-full ${hasAvailability ? 'bg-emerald-400' : 'bg-neutral-300'}`} />
                <span className={`text-xs font-medium ${hasAvailability ? 'text-emerald-600' : 'text-neutral-400'}`}>
                  {hasAvailability ? 'Tickets Available' : 'Sold Out'}
                </span>
              </>
            )}
          </div>
          <span className="inline-flex items-center gap-1 text-sm font-medium text-neutral-400 group-hover:text-brand-500 transition-all duration-200 group-hover:translate-x-0.5">
            View
            <ArrowRight className="w-3.5 h-3.5" />
          </span>
        </div>
      </div>
    </Link>
  )
}
