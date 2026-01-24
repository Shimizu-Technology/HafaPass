import { useState, useEffect } from 'react'
import { Link } from 'react-router-dom'
import apiClient from '../api/client'
import EventCard from '../components/EventCard'

export default function HomePage() {
  const [events, setEvents] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  useEffect(() => {
    apiClient.get('/events')
      .then(res => {
        setEvents(res.data.slice(0, 4))
        setLoading(false)
      })
      .catch(() => {
        setError('Unable to load events. Please try again later.')
        setLoading(false)
      })
  }, [])

  return (
    <div>
      {/* Hero Section */}
      <section className="bg-gradient-to-br from-blue-900 via-blue-800 to-teal-600 text-white py-20 px-4">
        <div className="max-w-4xl mx-auto text-center">
          <h1 className="text-4xl sm:text-5xl md:text-6xl font-bold mb-4">
            Your Island. Your Events. Your Pass.
          </h1>
          <p className="text-lg sm:text-xl text-blue-100 mb-8 max-w-2xl mx-auto">
            Discover and purchase tickets for the best events across Guam — concerts, nightlife, festivals, and more.
          </p>
          <Link
            to="/events"
            className="inline-block bg-orange-500 hover:bg-orange-600 text-white font-semibold px-8 py-3 rounded-lg text-lg transition-colors duration-200 shadow-lg"
          >
            Browse Events
          </Link>
        </div>
      </section>

      {/* Featured Events Section */}
      <section className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
        <div className="flex items-center justify-between mb-8">
          <h2 className="text-2xl sm:text-3xl font-bold text-gray-900">Upcoming Events</h2>
          <Link
            to="/events"
            className="text-blue-700 hover:text-blue-900 font-medium text-sm sm:text-base"
          >
            View All &rarr;
          </Link>
        </div>

        {loading && (
          <div className="flex justify-center py-12">
            <div className="animate-spin rounded-full h-10 w-10 border-b-2 border-blue-700"></div>
          </div>
        )}

        {error && (
          <div className="bg-red-50 border border-red-200 rounded-lg p-4 text-center">
            <p className="text-red-700">{error}</p>
          </div>
        )}

        {!loading && !error && events.length === 0 && (
          <div className="text-center py-12">
            <p className="text-gray-500 text-lg">No events available right now. Check back soon!</p>
          </div>
        )}

        {!loading && !error && events.length > 0 && (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-6">
            {events.map(event => (
              <EventCard key={event.id} event={event} />
            ))}
          </div>
        )}
      </section>

      {/* For Organizers CTA */}
      <section className="bg-blue-50 py-16 px-4">
        <div className="max-w-4xl mx-auto text-center">
          <h2 className="text-2xl sm:text-3xl font-bold text-gray-900 mb-4">
            Are You an Event Organizer?
          </h2>
          <p className="text-gray-600 text-lg mb-8 max-w-2xl mx-auto">
            List your events on HafaPass and reach thousands of attendees across Guam. Lower fees than the competition, and powered by Ambros Inc.&apos;s island-wide venue network.
          </p>
          <Link
            to="/dashboard"
            className="inline-block bg-blue-900 hover:bg-blue-800 text-white font-semibold px-8 py-3 rounded-lg text-lg transition-colors duration-200"
          >
            Get Started
          </Link>
        </div>
      </section>
    </div>
  )
}
