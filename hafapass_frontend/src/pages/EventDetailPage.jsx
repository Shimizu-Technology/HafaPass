import { useState, useEffect } from 'react'
import { useParams, useNavigate, useSearchParams, Link } from 'react-router-dom'
import { Calendar, Clock, MapPin, Users, ArrowLeft, Share2, Loader2, CalendarPlus, ExternalLink, Check, Copy } from 'lucide-react'
import { motion } from 'framer-motion'
import apiClient from '../api/client'
import WhosGoing from '../components/WhosGoing'
import TicketTypesSection from '../components/TicketTypesSection'
import WaitlistForm from '../components/WaitlistForm'
import SEO from '../components/SEO'
import { FadeUp } from '../components/ui/ScrollReveal'

export default function EventDetailPage() {
  const { slug } = useParams()
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()
  const isPreview = searchParams.get('preview') === 'true'
  const [event, setEvent] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    const url = isPreview ? `/events/${slug}?preview=true` : `/events/${slug}`
    apiClient.get(url)
      .then(res => { setEvent(res.data); setLoading(false) })
      .catch(() => { setError('Event not found.'); setLoading(false) })
  }, [slug, isPreview])

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

  const truncatedDescription = (event.short_description || event.description || '').slice(0, 160)
  const eventUrl = `https://hafapass.netlify.app/events/${event.slug}`

  // Build JSON-LD structured data for the event
  const ticketTypes = event.ticket_types || []
  const prices = ticketTypes.map(t => parseFloat(t.price)).filter(p => !isNaN(p) && p > 0)
  const eventJsonLd = {
    '@context': 'https://schema.org',
    '@type': 'Event',
    name: event.title,
    startDate: event.starts_at,
    ...(event.ends_at && { endDate: event.ends_at }),
    description: truncatedDescription,
    ...(event.cover_image_url && { image: event.cover_image_url }),
    url: eventUrl,
    ...(event.venue_name && {
      location: {
        '@type': 'Place',
        name: event.venue_name,
        ...(event.venue_address && { address: event.venue_address }),
      },
    }),
    ...(prices.length > 0 && {
      offers: {
        '@type': 'AggregateOffer',
        lowPrice: Math.min(...prices).toFixed(2),
        highPrice: Math.max(...prices).toFixed(2),
        priceCurrency: 'USD',
        availability: ticketTypes.some(tt => (tt.quantity_available - tt.quantity_sold) > 0) ? 'https://schema.org/InStock' : 'https://schema.org/SoldOut',
        url: eventUrl,
      },
    }),
    ...(event.organizer_name && {
      organizer: {
        '@type': 'Organization',
        name: event.organizer_name,
      },
    }),
  }

  return (
    <div>
      <SEO
        title={event.title}
        description={truncatedDescription}
        image={event.cover_image_url || undefined}
        url={eventUrl}
        jsonLd={eventJsonLd}
      />
      {/* Hero Section — full-width cover image with dark overlay */}
      <div className="relative w-full h-[50vh] sm:h-[55vh] lg:h-[60vh] min-h-[340px] max-h-[600px] overflow-hidden bg-neutral-950">
        {event.cover_image_url ? (
          <img
            src={event.cover_image_url}
            alt={event.title}
            className="absolute inset-0 w-full h-full object-cover"
          />
        ) : (
          <div className="absolute inset-0 bg-gradient-to-br from-brand-900 to-neutral-950" />
        )}
        {/* Dark gradient overlay */}
        <div className="absolute inset-0 bg-gradient-to-t from-neutral-950 via-neutral-950/60 to-neutral-950/30" />

        {/* Content overlaid on hero */}
        <div className="absolute inset-0 flex flex-col justify-end">
          <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 pb-8 sm:pb-10 w-full">
            {/* Back link */}
            <Link to="/events" className="inline-flex items-center gap-1.5 text-neutral-400 hover:text-white mb-4 text-sm font-medium transition-colors">
              <ArrowLeft className="w-4 h-4" /> All Events
            </Link>

            {event.category && event.category !== 'other' && (
              <span className="inline-block text-xs font-medium text-brand-400 uppercase tracking-wider mb-2">
                {event.category}
              </span>
            )}
            <h1 className="font-display text-3xl sm:text-4xl lg:text-5xl font-bold tracking-tight text-white mb-3">{event.title}</h1>

            {/* Date & Venue on hero */}
            <div className="flex flex-wrap items-center gap-4 text-neutral-300 text-sm">
              {event.starts_at && (
                <div className="flex items-center gap-2">
                  <Calendar className="w-4 h-4 text-brand-400" />
                  <span>{formatDate(event.starts_at)}</span>
                  <span className="text-neutral-500">·</span>
                  <span>{formatTime(event.starts_at)}{event.ends_at && ` – ${formatTime(event.ends_at)}`}</span>
                </div>
              )}
              {event.venue_name && (
                <div className="flex items-center gap-2">
                  <MapPin className="w-4 h-4 text-brand-400" />
                  <span>{event.venue_name}</span>
                </div>
              )}
            </div>
          </div>
        </div>
      </div>

      {/* Gradient transition */}
      <div className="h-px bg-gradient-to-r from-transparent via-brand-500/20 to-transparent" />

      {/* Light content area */}
      <div className="bg-white">
        <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
          <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
            {/* Main content */}
            <motion.div
              className="lg:col-span-2"
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.5 }}
            >
              {/* Action buttons */}
              <div className="flex items-center gap-2 mb-6">
                {event.starts_at && (
                  <a
                    href={buildGoogleCalendarUrl(event)}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex items-center gap-2 px-4 py-2.5 rounded-xl border border-neutral-200 text-neutral-600 hover:text-brand-600 hover:border-brand-300 transition-colors text-sm font-medium"
                  >
                    <CalendarPlus className="w-4 h-4" />
                    Add to Calendar
                  </a>
                )}
                <button
                  onClick={handleShare}
                  className="inline-flex items-center gap-2 px-4 py-2.5 rounded-xl border border-neutral-200 text-neutral-600 hover:text-neutral-700 hover:border-neutral-300 transition-colors text-sm font-medium"
                >
                  {copied ? <Check className="w-4 h-4 text-emerald-500" /> : <Share2 className="w-4 h-4" />}
                  {copied ? 'Copied!' : 'Share'}
                </button>
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

              {/* Who's Going */}
              <WhosGoing
                attendeeCount={event.attendee_count}
                attendeesPreview={event.attendees_preview}
                showAttendees={event.show_attendees}
              />

              {/* Description */}
              {event.description && (
                <FadeUp><div className="prose prose-neutral max-w-none mb-8">
                  <h2 className="text-lg font-semibold text-neutral-900 mb-3">About</h2>
                  <p className="text-neutral-600 leading-relaxed whitespace-pre-wrap">{event.description}</p>
                </div></FadeUp>
              )}

              {/* Venue Location Section */}
              {event.venue_address && (
                <FadeUp delay={0.1}><div className="mb-8">
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
                </div></FadeUp>
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
                {/* Waitlist form when all ticket types are sold out */}
                {event.ticket_types?.length > 0 &&
                  event.ticket_types.every(tt => (tt.quantity_available - tt.quantity_sold) <= 0) && (
                  <div className="mt-4">
                    <WaitlistForm event={event} ticketTypes={event.ticket_types} />
                  </div>
                )}
              </div>
            </motion.div>
          </div>
        </div>
      </div>
    </div>
  )
}
