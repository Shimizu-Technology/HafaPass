import { useState, useEffect } from 'react'
import { useParams, useNavigate, Link } from 'react-router-dom'
import { Calendar, Clock, MapPin, Users, ArrowLeft, Share2, Loader2, CalendarPlus, ExternalLink, Check, Copy } from 'lucide-react'
import { motion } from 'framer-motion'
import apiClient from '../api/client'
import TicketTypesSection from '../components/TicketTypesSection'

export default function EventDetailPage() {
  const { slug } = useParams()
  const navigate = useNavigate()
  const [event, setEvent] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    apiClient.get(`/events/${slug}`)
      .then(res => { setEvent(res.data); setLoading(false) })
      .catch(() => { setError('Event not found.'); setLoading(false) })
  }, [slug])

  const handleCheckout = (lineItems) => {
    navigate(`/checkout/${slug}`, { state: { event, lineItems } })
  }

  const formatDate = (dateStr) => new Date(dateStr).toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' })
  const formatTime = (dateStr) => new Date(dateStr).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })

  const ageLabels = { all_ages: 'All Ages', eighteen_plus: '18+', twenty_one_plus: '21+' }

  const buildGoogleCalendarUrl = (evt) => {
    const toGCalDate = (d) => new Date(d).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '')
    const start = toGCalDate(evt.starts_at)
    const end = evt.ends_at ? toGCalDate(evt.ends_at) : toGCalDate(new Date(new Date(evt.starts_at).getTime() + 2 * 3600000))
    const params = new URLSearchParams({
      action: 'TEMPLATE',
      text: evt.title,
      dates: `${start}/${end}`,
      details: evt.description || '',
      location: [evt.venue_name, evt.venue_address].filter(Boolean).join(', '),
    })
    return `https://calendar.google.com/calendar/render?${params.toString()}`
  }

  const handleShare = async () => {
    const url = window.location.href
    if (navigator.share) {
      try {
        await navigator.share({ title: event.title, text: event.short_description || event.description?.slice(0, 120), url })
      } catch {}
    } else {
      await navigator.clipboard.writeText(url)
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    }
  }

  const buildMapsUrl = (evt) => {
    const q = encodeURIComponent([evt.venue_name, evt.venue_address].filter(Boolean).join(', '))
    return `https://www.google.com/maps/search/?api=1&query=${q}`
  }

  if (loading) return <div className="flex justify-center py-20"><Loader2 className="w-8 h-8 text-brand-500 animate-spin" /></div>
  if (error) return (
    <div className="max-w-2xl mx-auto px-4 py-16 text-center">
      <p className="text-neutral-500 text-lg mb-4">{error}</p>
      <Link to="/events" className="btn-primary">Browse Events</Link>
    </div>
  )
  if (!event) return null

  return (
    <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <Link to="/events" className="inline-flex items-center gap-1.5 text-neutral-500 hover:text-neutral-900 mb-6 text-sm font-medium transition-colors">
        <ArrowLeft className="w-4 h-4" /> All Events
      </Link>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
        {/* Main content */}
        <motion.div
          className="lg:col-span-2"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5 }}
        >
          {/* Cover image */}
          <div className="aspect-[2/1] rounded-2xl overflow-hidden bg-gradient-to-br from-brand-100 to-brand-200 mb-6">
            {event.cover_image_url ? (
              <img src={event.cover_image_url} alt={event.title} className="w-full h-full object-cover" />
            ) : (
              <div className="w-full h-full flex items-center justify-center">
                <svg className="w-24 h-24 text-brand-300" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M2 9a3 3 0 0 1 0 6v2a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-2a3 3 0 0 1 0-6V7a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2Z" />
                </svg>
              </div>
            )}
          </div>

          {/* Event info */}
          <div className="flex items-start justify-between gap-4 mb-4">
            <div>
              {event.category && event.category !== 'other' && (
                <span className="inline-block text-xs font-medium text-brand-500 uppercase tracking-wider mb-2">
                  {event.category}
                </span>
              )}
              <h1 className="text-2xl sm:text-3xl font-bold tracking-tight text-neutral-900">{event.title}</h1>
            </div>
            <div className="flex items-center gap-2 shrink-0">
              {event.starts_at && (
                <a
                  href={buildGoogleCalendarUrl(event)}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="p-2.5 rounded-xl border border-neutral-200 text-neutral-500 hover:text-brand-600 hover:border-brand-300 transition-colors"
                  title="Add to Calendar"
                >
                  <CalendarPlus className="w-4 h-4" />
                </a>
              )}
              <button
                onClick={handleShare}
                className="p-2.5 rounded-xl border border-neutral-200 text-neutral-500 hover:text-neutral-700 hover:border-neutral-300 transition-colors"
                title={copied ? 'Copied!' : 'Share'}
              >
                {copied ? <Check className="w-4 h-4 text-emerald-500" /> : <Share2 className="w-4 h-4" />}
              </button>
            </div>
          </div>

          {/* Meta */}
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 mb-8">
            {event.starts_at && (
              <div className="flex items-center gap-3 p-3 rounded-xl bg-neutral-50">
                <div className="w-10 h-10 rounded-xl bg-brand-50 flex items-center justify-center">
                  <Calendar className="w-5 h-5 text-brand-500" />
                </div>
                <div>
                  <p className="text-sm font-medium text-neutral-900">{formatDate(event.starts_at)}</p>
                  <p className="text-xs text-neutral-500">{formatTime(event.starts_at)}{event.ends_at && ` - ${formatTime(event.ends_at)}`}</p>
                </div>
              </div>
            )}
            {event.venue_name && (
              <a
                href={buildMapsUrl(event)}
                target="_blank"
                rel="noopener noreferrer"
                className="flex items-center gap-3 p-3 rounded-xl bg-neutral-50 hover:bg-brand-50/50 transition-colors group"
              >
                <div className="w-10 h-10 rounded-xl bg-brand-50 flex items-center justify-center">
                  <MapPin className="w-5 h-5 text-brand-500" />
                </div>
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-medium text-neutral-900 group-hover:text-brand-600 transition-colors">{event.venue_name}</p>
                  {event.venue_address && <p className="text-xs text-neutral-500 truncate">{event.venue_address}</p>}
                </div>
                <ExternalLink className="w-3.5 h-3.5 text-neutral-400 group-hover:text-brand-500 transition-colors shrink-0" />
              </a>
            )}
          </div>

          {/* Badges */}
          <div className="flex flex-wrap gap-2 mb-6">
            {event.age_restriction && event.age_restriction !== 'all_ages' && (
              <span className="inline-flex items-center gap-1.5 text-xs font-medium bg-neutral-100 text-neutral-700 px-3 py-1.5 rounded-full">
                <Users className="w-3 h-3" />
                {ageLabels[event.age_restriction] || event.age_restriction}
              </span>
            )}
            {event.doors_open_at && (
              <span className="inline-flex items-center gap-1.5 text-xs font-medium bg-neutral-100 text-neutral-700 px-3 py-1.5 rounded-full">
                <Clock className="w-3 h-3" />
                Doors {formatTime(event.doors_open_at)}
              </span>
            )}
          </div>

          {/* Description */}
          {event.description && (
            <div className="prose prose-neutral max-w-none mb-8">
              <h2 className="text-lg font-semibold text-neutral-900 mb-3">About</h2>
              <p className="text-neutral-600 leading-relaxed whitespace-pre-wrap">{event.description}</p>
            </div>
          )}

          {/* Venue Location Section */}
          {event.venue_address && (
            <div className="mb-8">
              <h2 className="text-lg font-semibold text-neutral-900 mb-3">Location</h2>
              <a
                href={buildMapsUrl(event)}
                target="_blank"
                rel="noopener noreferrer"
                className="block rounded-2xl overflow-hidden border border-neutral-200 hover:border-brand-300 transition-colors group"
              >
                <div className="aspect-[3/1] bg-gradient-to-br from-brand-50 to-brand-100 flex items-center justify-center">
                  <div className="text-center">
                    <MapPin className="w-8 h-8 text-brand-400 mx-auto mb-2" />
                    <p className="text-sm font-medium text-brand-700">{event.venue_name}</p>
                    <p className="text-xs text-brand-500 mt-0.5">{event.venue_address}</p>
                    <p className="text-xs text-brand-400 mt-2 group-hover:underline">Open in Google Maps</p>
                  </div>
                </div>
              </a>
            </div>
          )}
        </motion.div>

        {/* Sidebar - Tickets */}
        <motion.div
          className="lg:col-span-1"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.15 }}
        >
          <div className="lg:sticky lg:top-24">
            <div className="card p-5">
              {event.ticket_types && event.ticket_types.length > 0 ? (
                <TicketTypesSection ticketTypes={event.ticket_types} onCheckout={handleCheckout} />
              ) : (
                <p className="text-neutral-500 text-center py-4">No tickets available</p>
              )}
            </div>
          </div>
        </motion.div>
      </div>
    </div>
  )
}
