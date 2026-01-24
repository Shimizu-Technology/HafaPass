import { useState, useEffect } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import apiClient from '../api/client'

export default function EventDetailPage() {
  const { slug } = useParams()
  const navigate = useNavigate()
  const [event, setEvent] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [quantities, setQuantities] = useState({})

  useEffect(() => {
    setLoading(true)
    setError(null)
    apiClient.get(`/events/${slug}`)
      .then(res => {
        setEvent(res.data)
        setLoading(false)
      })
      .catch(err => {
        if (err.response && err.response.status === 404) {
          setError('Event not found.')
        } else {
          setError('Unable to load event details. Please try again later.')
        }
        setLoading(false)
      })
  }, [slug])

  const updateQuantity = (ticketTypeId, delta) => {
    setQuantities(prev => {
      const current = prev[ticketTypeId] || 0
      const ticketType = event.ticket_types.find(tt => tt.id === ticketTypeId)
      const maxAllowed = Math.min(
        ticketType.max_per_order || 10,
        ticketType.quantity_available - ticketType.quantity_sold
      )
      const newVal = Math.max(0, Math.min(maxAllowed, current + delta))
      return { ...prev, [ticketTypeId]: newVal }
    })
  }

  const totalSelected = Object.values(quantities).reduce((sum, q) => sum + q, 0)

  const handleGetTickets = () => {
    const lineItems = Object.entries(quantities)
      .filter(([, qty]) => qty > 0)
      .map(([ticketTypeId, quantity]) => ({ ticket_type_id: parseInt(ticketTypeId), quantity }))

    navigate(`/checkout/${slug}`, { state: { lineItems, event } })
  }

  const formatPrice = (cents) => {
    if (cents === 0) return 'Free'
    return `$${(cents / 100).toFixed(2)}`
  }

  const formatDate = (dateStr) => {
    const date = new Date(dateStr)
    return date.toLocaleDateString('en-US', {
      weekday: 'long',
      month: 'long',
      day: 'numeric',
      year: 'numeric',
    })
  }

  const formatTime = (dateStr) => {
    const date = new Date(dateStr)
    return date.toLocaleTimeString('en-US', {
      hour: 'numeric',
      minute: '2-digit',
    })
  }

  const ageRestrictionLabel = (restriction) => {
    switch (restriction) {
      case 'eighteen_plus': return '18+'
      case 'twenty_one_plus': return '21+'
      default: return null
    }
  }

  if (loading) {
    return (
      <div className="flex justify-center py-16">
        <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-700"></div>
      </div>
    )
  }

  if (error) {
    return (
      <div className="max-w-3xl mx-auto px-4 py-16">
        <div className="bg-red-50 border border-red-200 rounded-lg p-6 text-center">
          <p className="text-red-700 mb-4">{error}</p>
          <button
            onClick={() => navigate('/events')}
            className="inline-block bg-blue-600 hover:bg-blue-700 text-white font-medium px-6 py-2 rounded-lg transition-colors duration-200"
          >
            Back to Events
          </button>
        </div>
      </div>
    )
  }

  const ageBadge = ageRestrictionLabel(event.age_restriction)

  return (
    <div>
      {/* Cover Image */}
      {event.cover_image_url ? (
        <img
          src={event.cover_image_url}
          alt={event.title}
          className="w-full h-64 sm:h-80 object-cover"
        />
      ) : (
        <div className="w-full h-64 sm:h-80 bg-gradient-to-br from-blue-600 to-teal-500 flex items-center justify-center">
          <span className="text-white text-6xl font-bold opacity-20">HP</span>
        </div>
      )}

      <div className="max-w-3xl mx-auto px-4 sm:px-6 py-8">
        {/* Title and badges */}
        <div className="flex flex-wrap items-start gap-3 mb-4">
          <h1 className="text-3xl sm:text-4xl font-bold text-gray-900">{event.title}</h1>
          {ageBadge && (
            <span className="inline-flex items-center px-3 py-1 rounded-full text-sm font-semibold bg-red-100 text-red-800 mt-1">
              {ageBadge}
            </span>
          )}
        </div>

        {/* Date and time */}
        <div className="text-blue-700 font-medium text-lg mb-1">
          {formatDate(event.starts_at)}
        </div>
        <div className="text-gray-600 mb-4">
          {formatTime(event.starts_at)}
          {event.ends_at && ` – ${formatTime(event.ends_at)}`}
          {event.doors_open_at && (
            <span className="ml-3 text-sm text-gray-400">
              Doors open at {formatTime(event.doors_open_at)}
            </span>
          )}
        </div>

        {/* Venue */}
        <div className="mb-6">
          <p className="text-gray-800 font-medium">{event.venue_name}</p>
          {event.venue_address && (
            <p className="text-gray-500 text-sm">{event.venue_address}{event.venue_city ? `, ${event.venue_city}` : ''}</p>
          )}
        </div>

        {/* Description */}
        {event.description && (
          <div className="mb-8">
            <h2 className="text-xl font-semibold text-gray-900 mb-2">About</h2>
            <p className="text-gray-700 whitespace-pre-line">{event.description}</p>
          </div>
        )}

        {/* Ticket Types */}
        <div className="mb-8">
          <h2 className="text-xl font-semibold text-gray-900 mb-4">Tickets</h2>
          {event.ticket_types && event.ticket_types.length > 0 ? (
            <div className="space-y-4">
              {event.ticket_types.map(tt => {
                const available = tt.quantity_available - tt.quantity_sold
                const soldOut = available <= 0
                const qty = quantities[tt.id] || 0

                return (
                  <div
                    key={tt.id}
                    className={`border rounded-lg p-4 ${soldOut ? 'bg-gray-50 border-gray-200' : 'bg-white border-gray-200'}`}
                  >
                    <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
                      <div className="flex-1">
                        <div className="flex items-center gap-2">
                          <h3 className="font-semibold text-gray-900">{tt.name}</h3>
                          {soldOut && (
                            <span className="text-xs bg-gray-200 text-gray-600 px-2 py-0.5 rounded-full font-medium">
                              Sold Out
                            </span>
                          )}
                        </div>
                        {tt.description && (
                          <p className="text-sm text-gray-500 mt-1">{tt.description}</p>
                        )}
                        <p className="text-lg font-bold text-teal-700 mt-1">
                          {formatPrice(tt.price_cents)}
                        </p>
                        {!soldOut && (
                          <p className="text-xs text-gray-400 mt-0.5">
                            {available} remaining
                          </p>
                        )}
                      </div>

                      {!soldOut && (
                        <div className="flex items-center gap-3">
                          <button
                            onClick={() => updateQuantity(tt.id, -1)}
                            disabled={qty === 0}
                            className="w-10 h-10 flex items-center justify-center rounded-full border border-gray-300 text-gray-700 hover:bg-gray-100 disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
                            aria-label={`Decrease ${tt.name} quantity`}
                          >
                            &minus;
                          </button>
                          <span className="w-8 text-center font-semibold text-gray-900">{qty}</span>
                          <button
                            onClick={() => updateQuantity(tt.id, 1)}
                            disabled={qty >= Math.min(tt.max_per_order || 10, available)}
                            className="w-10 h-10 flex items-center justify-center rounded-full border border-gray-300 text-gray-700 hover:bg-gray-100 disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
                            aria-label={`Increase ${tt.name} quantity`}
                          >
                            +
                          </button>
                        </div>
                      )}
                    </div>
                  </div>
                )
              })}
            </div>
          ) : (
            <p className="text-gray-500">No tickets available for this event.</p>
          )}
        </div>

        {/* Get Tickets Button */}
        <button
          onClick={handleGetTickets}
          disabled={totalSelected === 0}
          className="w-full sm:w-auto bg-orange-500 hover:bg-orange-600 disabled:bg-gray-300 disabled:cursor-not-allowed text-white font-bold py-3 px-8 rounded-lg text-lg transition-colors duration-200"
        >
          {totalSelected === 0 ? 'Select Tickets' : `Get ${totalSelected} Ticket${totalSelected > 1 ? 's' : ''}`}
        </button>
      </div>
    </div>
  )
}
