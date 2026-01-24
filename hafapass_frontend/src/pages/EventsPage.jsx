import { useState, useEffect } from 'react'
import apiClient from '../api/client'
import EventCard from '../components/EventCard'

export default function EventsPage() {
  const [events, setEvents] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  const fetchEvents = () => {
    setLoading(true)
    setError(null)
    apiClient.get('/events')
      .then(res => {
        setEvents(res.data)
        setLoading(false)
      })
      .catch(() => {
        setError('Unable to load events. Please try again later.')
        setLoading(false)
      })
  }

  useEffect(() => {
    fetchEvents()
  }, [])

  return (
    <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <h1 className="text-3xl sm:text-4xl font-bold text-gray-900 mb-8">Upcoming Events</h1>

      {loading && (
        <div className="flex justify-center py-16">
          <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-700"></div>
        </div>
      )}

      {error && (
        <div className="bg-red-50 border border-red-200 rounded-lg p-6 text-center">
          <p className="text-red-700 mb-4">{error}</p>
          <button
            onClick={fetchEvents}
            className="inline-block bg-red-600 hover:bg-red-700 text-white font-medium px-6 py-2 rounded-lg transition-colors duration-200"
          >
            Try Again
          </button>
        </div>
      )}

      {!loading && !error && events.length === 0 && (
        <div className="text-center py-16">
          <div className="text-gray-400 text-5xl mb-4">🎉</div>
          <p className="text-gray-500 text-lg">No events available right now. Check back soon!</p>
        </div>
      )}

      {!loading && !error && events.length > 0 && (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6">
          {events.map(event => (
            <EventCard key={event.id} event={event} />
          ))}
        </div>
      )}
    </div>
  )
}
