import { Link } from 'react-router-dom'

export default function EventCard({ event }) {
  const startDate = new Date(event.starts_at)
  const formattedDate = startDate.toLocaleDateString('en-US', {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
  })
  const formattedTime = startDate.toLocaleTimeString('en-US', {
    hour: 'numeric',
    minute: '2-digit',
  })

  const lowestPrice = event.ticket_types && event.ticket_types.length > 0
    ? Math.min(...event.ticket_types.map(tt => tt.price_cents))
    : null

  const formatPrice = (cents) => {
    if (cents === 0) return 'Free'
    return `$${(cents / 100).toFixed(2)}`
  }

  return (
    <Link
      to={`/events/${event.slug}`}
      className="block bg-white rounded-lg shadow-md overflow-hidden hover:shadow-lg transition-shadow duration-200"
    >
      {event.cover_image_url ? (
        <img
          src={event.cover_image_url}
          alt={event.title}
          className="w-full h-48 object-cover"
        />
      ) : (
        <div className="w-full h-48 bg-gradient-to-br from-blue-600 to-teal-500 flex items-center justify-center">
          <span className="text-white text-4xl font-bold opacity-30">HP</span>
        </div>
      )}
      <div className="p-4">
        <h3 className="text-lg font-semibold text-gray-900 truncate">{event.title}</h3>
        <p className="text-sm text-blue-700 font-medium mt-1">
          {formattedDate} &middot; {formattedTime}
        </p>
        <p className="text-sm text-gray-500 mt-1 truncate">{event.venue_name}</p>
        <div className="mt-3 flex items-center justify-between">
          {lowestPrice !== null ? (
            <span className="text-sm font-semibold text-teal-700">
              {lowestPrice === 0 ? 'Free' : `From ${formatPrice(lowestPrice)}`}
            </span>
          ) : (
            <span className="text-sm text-gray-400">No tickets listed</span>
          )}
          {event.is_featured && (
            <span className="text-xs bg-orange-100 text-orange-700 px-2 py-0.5 rounded-full font-medium">
              Featured
            </span>
          )}
        </div>
      </div>
    </Link>
  )
}
