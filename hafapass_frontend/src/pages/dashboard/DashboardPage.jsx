import { useState, useEffect } from 'react'
import { Link } from 'react-router-dom'
import apiClient from '../../api/client'

function OrganizerProfileForm({ onSuccess }) {
  const [businessName, setBusinessName] = useState('')
  const [businessDescription, setBusinessDescription] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState(null)

  const handleSubmit = async (e) => {
    e.preventDefault()
    if (!businessName.trim()) {
      setError('Business name is required')
      return
    }
    setSubmitting(true)
    setError(null)
    try {
      await apiClient.post('/organizer_profile', {
        business_name: businessName.trim(),
        business_description: businessDescription.trim()
      })
      onSuccess()
    } catch (err) {
      const msg = err.response?.data?.errors?.[0] || err.response?.data?.error || 'Failed to create profile'
      setError(msg)
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div className="max-w-lg mx-auto">
      <div className="bg-white rounded-lg shadow-md p-6">
        <h2 className="text-2xl font-bold text-gray-900 mb-2">Create Your Organizer Profile</h2>
        <p className="text-gray-600 mb-6">Set up your organizer profile to start creating and managing events on HafaPass.</p>

        {error && (
          <div className="mb-4 p-3 bg-red-50 border border-red-200 rounded-md text-red-700 text-sm">
            {error}
          </div>
        )}

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label htmlFor="business_name" className="block text-sm font-medium text-gray-700 mb-1">
              Business Name <span className="text-red-500">*</span>
            </label>
            <input
              id="business_name"
              type="text"
              value={businessName}
              onChange={(e) => setBusinessName(e.target.value)}
              className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
              placeholder="e.g., Island Nights Promotions"
              disabled={submitting}
            />
          </div>

          <div>
            <label htmlFor="business_description" className="block text-sm font-medium text-gray-700 mb-1">
              Description
            </label>
            <textarea
              id="business_description"
              value={businessDescription}
              onChange={(e) => setBusinessDescription(e.target.value)}
              rows={3}
              className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
              placeholder="Tell attendees about your business..."
              disabled={submitting}
            />
          </div>

          <button
            type="submit"
            disabled={submitting}
            className="w-full bg-blue-900 text-white py-2.5 px-4 rounded-md font-medium hover:bg-blue-800 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {submitting ? 'Creating Profile...' : 'Create Organizer Profile'}
          </button>
        </form>
      </div>
    </div>
  )
}

function StatusBadge({ status }) {
  const styles = {
    draft: 'bg-yellow-100 text-yellow-800',
    published: 'bg-green-100 text-green-800',
    cancelled: 'bg-red-100 text-red-800',
    completed: 'bg-gray-100 text-gray-800'
  }
  return (
    <span className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-medium ${styles[status] || 'bg-gray-100 text-gray-800'}`}>
      {status.charAt(0).toUpperCase() + status.slice(1)}
    </span>
  )
}

function EventListCard({ event }) {
  const ticketsSold = event.ticket_types
    ? event.ticket_types.reduce((sum, tt) => sum + (tt.quantity_sold || 0), 0)
    : 0

  const formatDate = (dateStr) => {
    if (!dateStr) return ''
    const date = new Date(dateStr)
    return date.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
  }

  return (
    <Link
      to={`/dashboard/events/${event.id}/edit`}
      className="block bg-white rounded-lg shadow-sm border border-gray-200 hover:shadow-md hover:border-blue-200 transition-all p-4"
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <h3 className="text-lg font-semibold text-gray-900 truncate">{event.title}</h3>
          <p className="text-sm text-gray-500 mt-0.5">
            {formatDate(event.starts_at)} {event.venue_name && `· ${event.venue_name}`}
          </p>
        </div>
        <StatusBadge status={event.status} />
      </div>
      <div className="mt-3 flex items-center gap-4 text-sm text-gray-600">
        <span className="flex items-center gap-1">
          <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 5v2m0 4v2m0 4v2M5 5a2 2 0 00-2 2v3a2 2 0 110 4v3a2 2 0 002 2h14a2 2 0 002-2v-3a2 2 0 110-4V7a2 2 0 00-2-2H5z" />
          </svg>
          {ticketsSold} sold
        </span>
        {event.category && (
          <span className="text-gray-400 capitalize">{event.category.replace('_', ' ')}</span>
        )}
      </div>
    </Link>
  )
}

export default function DashboardPage() {
  const [profile, setProfile] = useState(null)
  const [events, setEvents] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  const fetchDashboard = async () => {
    setLoading(true)
    setError(null)
    try {
      const profileRes = await apiClient.get('/organizer_profile')
      setProfile(profileRes.data)

      const eventsRes = await apiClient.get('/organizer/events')
      setEvents(eventsRes.data)
    } catch (err) {
      if (err.response?.status === 404) {
        // No organizer profile — show create form
        setProfile(null)
      } else if (err.response?.status === 401) {
        setError('Please sign in to access the dashboard.')
      } else {
        setError('Failed to load dashboard. Please try again.')
      }
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    fetchDashboard()
  }, [])

  if (loading) {
    return (
      <div className="min-h-[60vh] flex items-center justify-center">
        <div className="animate-spin rounded-full h-10 w-10 border-b-2 border-blue-900"></div>
      </div>
    )
  }

  if (error) {
    return (
      <div className="max-w-2xl mx-auto px-4 py-12">
        <div className="bg-red-50 border border-red-200 rounded-lg p-6 text-center">
          <p className="text-red-700">{error}</p>
          <button
            onClick={fetchDashboard}
            className="mt-4 text-red-600 hover:text-red-800 font-medium underline"
          >
            Try Again
          </button>
        </div>
      </div>
    )
  }

  if (!profile) {
    return (
      <div className="px-4 py-12">
        <OrganizerProfileForm onSuccess={fetchDashboard} />
      </div>
    )
  }

  return (
    <div className="max-w-4xl mx-auto px-4 py-8">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-8">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Welcome, {profile.business_name}</h1>
          <p className="text-gray-600 mt-1">Manage your events and track ticket sales</p>
        </div>
        <div className="flex items-center gap-3">
          <Link
            to="/dashboard/scanner"
            className="inline-flex items-center justify-center gap-2 bg-blue-600 text-white px-4 py-2.5 min-h-[44px] rounded-md font-medium hover:bg-blue-700 transition-colors text-sm"
          >
            <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 4v1m6 11h2m-6 0h-2v4m0-11v3m0 0h.01M12 12h4.01M16 20h4M4 12h4m12 0h.01M5 8h2a1 1 0 001-1V5a1 1 0 00-1-1H5a1 1 0 00-1 1v2a1 1 0 001 1zm12 0h2a1 1 0 001-1V5a1 1 0 00-1-1h-2a1 1 0 00-1 1v2a1 1 0 001 1zM5 20h2a1 1 0 001-1v-2a1 1 0 00-1-1H5a1 1 0 00-1 1v2a1 1 0 001 1z" />
            </svg>
            Scan Tickets
          </Link>
          <Link
            to="/dashboard/events/new"
            className="inline-flex items-center justify-center gap-2 bg-orange-500 text-white px-4 py-2.5 min-h-[44px] rounded-md font-medium hover:bg-orange-600 transition-colors text-sm"
          >
            <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 4v16m8-8H4" />
            </svg>
            Create Event
          </Link>
        </div>
      </div>

      {events.length === 0 ? (
        <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-12 text-center">
          <svg className="mx-auto h-12 w-12 text-gray-400 mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z" />
          </svg>
          <h3 className="text-lg font-medium text-gray-900 mb-1">No events yet</h3>
          <p className="text-gray-500 mb-4">Get started by creating your first event</p>
          <Link
            to="/dashboard/events/new"
            className="inline-flex items-center gap-2 bg-blue-900 text-white px-4 py-2 rounded-md font-medium hover:bg-blue-800 transition-colors"
          >
            <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 4v16m8-8H4" />
            </svg>
            Create Your First Event
          </Link>
        </div>
      ) : (
        <div className="space-y-3">
          {events.map((event) => (
            <EventListCard key={event.id} event={event} />
          ))}
        </div>
      )}
    </div>
  )
}
