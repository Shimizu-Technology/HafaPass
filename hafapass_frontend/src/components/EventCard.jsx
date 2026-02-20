import { Link } from 'react-router-dom'
import { Calendar, MapPin, Clock, ArrowRight } from 'lucide-react'

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

  return (
    <Link
      to={`/events/${event.slug}`}
      className="group block card overflow-hidden hover:shadow-xl hover:shadow-neutral-200/50 hover:border-neutral-300 transition-all duration-300"
    >
      {/* Image */}
      <div className="aspect-[16/10] overflow-hidden bg-gradient-to-br from-brand-100 to-brand-200">
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
      </div>

      <div className="p-5">
        {/* Category badge */}
        {event.category && event.category !== 'other' && (
          <span className="inline-block text-xs font-medium text-brand-500 uppercase tracking-wider mb-2">
            {event.category}
          </span>
        )}

        <h3 className="text-lg font-semibold text-neutral-900 mb-3 group-hover:text-brand-500 transition-colors duration-200 line-clamp-2">
          {event.title}
        </h3>

        <div className="space-y-1.5 mb-4">
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

        <div className="flex items-center justify-between">
          {priceLabel && (
            <span className="text-sm font-semibold text-accent-600">{priceLabel}</span>
          )}
          <span className="inline-flex items-center gap-1 text-sm font-medium text-neutral-900 opacity-0 group-hover:opacity-100 transition-opacity duration-200">
            View
            <ArrowRight className="w-3.5 h-3.5 transition-transform group-hover:translate-x-0.5" />
          </span>
        </div>
      </div>
    </Link>
  )
}
