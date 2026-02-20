import { useState, useEffect, useMemo } from 'react'
import { Link } from 'react-router-dom'
import { Calendar, MapPin, ArrowRight, Clock, Sparkles } from 'lucide-react'
import apiClient from '../api/client'
import Footer from '../components/Footer'
import { FadeUp } from '../components/ui/ScrollReveal'
import NoiseOverlay from '../components/ui/NoiseOverlay'

const CATEGORY_IMAGES = [
  { name: 'Nightlife', slug: 'nightlife', image: 'https://images.unsplash.com/photo-1519671482749-fd09be7ccebf?w=800' },
  { name: 'Food & Drink', slug: 'food_drink', image: 'https://images.unsplash.com/photo-1555939594-58d7cb561ad1?w=800' },
  { name: 'Music', slug: 'music', image: 'https://images.unsplash.com/photo-1459749411175-04bf5292ceea?w=800' },
  { name: 'Sports', slug: 'sports', image: 'https://images.unsplash.com/photo-1612872087720-bb876e2e67d1?w=800' },
  { name: 'Community', slug: 'community', image: 'https://images.unsplash.com/photo-1529156069898-49953e39b3ac?w=800' },
  { name: 'Festivals', slug: 'festivals', image: 'https://images.unsplash.com/photo-1533174072545-7a4b6ad7a6c3?w=800' },
]

function formatDate(dateStr) {
  const d = new Date(dateStr)
  return d.toLocaleDateString('en-US', { weekday: 'long', month: 'short', day: 'numeric' })
}

function formatTime(dateStr) {
  const d = new Date(dateStr)
  return d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })
}

function getLowestPrice(ticketTypes) {
  if (!ticketTypes?.length) return null
  const prices = ticketTypes.map(t => t.price_cents).filter(p => p != null)
  if (!prices.length) return null
  const min = Math.min(...prices)
  return min === 0 ? 'Free' : `$${(min / 100).toFixed(0)}`
}

function getThisWeekRange() {
  const now = new Date()
  const start = new Date(now)
  start.setHours(0, 0, 0, 0)
  const end = new Date(start)
  end.setDate(end.getDate() + 7)
  return { start, end }
}

export default function HomePage() {
  const [events, setEvents] = useState([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    apiClient.get('/events')
      .then(res => {
        const data = res.data.events || res.data
        setEvents(Array.isArray(data) ? data : [])
      })
      .catch(() => setEvents([]))
      .finally(() => setLoading(false))
  }, [])

  const featuredEvent = useMemo(() => {
    const featured = events
      .filter(e => e.is_featured && new Date(e.starts_at) > new Date())
      .sort((a, b) => new Date(a.starts_at) - new Date(b.starts_at))
    return featured[0] || null
  }, [events])

  const { groupedEvents, sectionTitle } = useMemo(() => {
    const { start, end } = getThisWeekRange()
    const upcoming = events
      .filter(e => new Date(e.starts_at) >= start)
      .sort((a, b) => new Date(a.starts_at) - new Date(b.starts_at))

    let filtered = upcoming.filter(e => new Date(e.starts_at) < end)
    let title = 'This Week on Guam'

    if (!filtered.length) {
      filtered = upcoming.slice(0, 8)
      title = filtered.length ? 'Next Up on Guam' : ''
    }

    const grouped = {}
    filtered.forEach(e => {
      const key = formatDate(e.starts_at)
      if (!grouped[key]) grouped[key] = []
      grouped[key].push(e)
    })

    return { groupedEvents: grouped, sectionTitle: title }
  }, [events])

  const hasEvents = events.length > 0
  const dayKeys = Object.keys(groupedEvents)

  return (
    <div className="min-h-screen bg-neutral-950">
      {/* ── Featured Event Hero ── */}
      <section className="relative h-[85vh] min-h-[560px] max-h-[800px] overflow-hidden">
        <NoiseOverlay />
        {featuredEvent ? (
          <>
            <div
              className="absolute inset-0 bg-cover bg-center transition-transform duration-[8s] ease-out hover:scale-105"
              style={{ backgroundImage: `url(${featuredEvent.cover_image_url})` }}
            />
            <div className="absolute inset-0 bg-gradient-to-t from-neutral-950 via-neutral-950/50 to-neutral-950/20" />
            <div className="relative h-full flex items-end">
              <div className="max-w-6xl mx-auto w-full px-6 lg:px-8 pb-16 lg:pb-20">
                <div className="inline-flex items-center gap-2 px-3 py-1.5 rounded-full bg-white/10 backdrop-blur-sm text-white/80 text-xs font-medium mb-6 border border-white/10">
                  <Sparkles className="w-3.5 h-3.5 text-accent-400" />
                  Featured Event
                </div>
                <h1 className="font-display text-4xl sm:text-5xl lg:text-7xl font-bold text-white tracking-tight leading-[1.05] mb-4 max-w-3xl">
                  {featuredEvent.title}
                </h1>
                <div className="flex flex-wrap items-center gap-x-6 gap-y-2 text-white/70 text-base lg:text-lg mb-8">
                  <span className="flex items-center gap-2">
                    <Calendar className="w-4 h-4" />
                    {formatDate(featuredEvent.starts_at)} · {formatTime(featuredEvent.starts_at)}
                  </span>
                  {featuredEvent.venue_name && (
                    <span className="flex items-center gap-2">
                      <MapPin className="w-4 h-4" />
                      {featuredEvent.venue_name}{featuredEvent.venue_city ? `, ${featuredEvent.venue_city}` : ''}
                    </span>
                  )}
                </div>
                <Link
                  to={`/events/${featuredEvent.slug || featuredEvent.id}`}
                  className="inline-flex items-center gap-2 px-8 py-4 bg-accent-500 hover:bg-accent-600 text-white font-semibold rounded-xl transition-all duration-200 text-lg hover:-translate-y-0.5 hover:shadow-lg hover:shadow-accent-500/25 active:translate-y-0"
                >
                  Get Tickets
                  <ArrowRight className="w-5 h-5" />
                </Link>
              </div>
            </div>
          </>
        ) : (
          <>
            <div className="absolute inset-0 bg-gradient-to-br from-brand-950 via-neutral-950 to-brand-900" />
            <div className="absolute inset-0 bg-[radial-gradient(circle_at_30%_40%,rgba(13,158,150,0.15),transparent_60%)]" />
            <div className="absolute inset-0 bg-[radial-gradient(circle_at_70%_80%,rgba(255,107,107,0.08),transparent_50%)]" />
            <div className="relative h-full flex items-center justify-center text-center px-6">
              <div>
                <h1 className="font-display text-4xl sm:text-5xl lg:text-7xl font-bold text-white tracking-tight leading-[1.05] mb-6 max-w-3xl">
                  {hasEvents ? (
                    <>Discover Events on <span className="bg-gradient-to-r from-brand-400 to-accent-400 bg-clip-text text-transparent">Guam</span></>
                  ) : (
                    <>Guam's Event Scene is About to <span className="bg-gradient-to-r from-brand-400 to-accent-400 bg-clip-text text-transparent">Take Off</span></>
                  )}
                </h1>
                <p className="text-lg lg:text-xl text-white/50 max-w-xl mx-auto mb-10">
                  {hasEvents
                    ? 'Your curated guide to everything happening on the island.'
                    : 'The island\'s modern ticketing platform is here. Events are coming soon.'}
                </p>
                <Link
                  to={hasEvents ? '/events' : '/sign-up'}
                  className="inline-flex items-center gap-2 px-8 py-4 bg-brand-500 hover:bg-brand-600 text-white font-semibold rounded-xl transition-all duration-200 text-lg hover:-translate-y-0.5 hover:shadow-lg hover:shadow-brand-500/25 active:translate-y-0"
                >
                  {hasEvents ? 'Browse Events' : 'Start Hosting'}
                  <ArrowRight className="w-5 h-5" />
                </Link>
              </div>
            </div>
          </>
        )}
      </section>

      {/* ── This Week on Guam ── */}
      <section className="py-16 lg:py-24 bg-neutral-950">
        <div className="max-w-6xl mx-auto px-6 lg:px-8">
          {dayKeys.length > 0 ? (
            <>
              <FadeUp>
              <div className="flex items-end justify-between mb-12">
                <h2 className="font-display text-3xl lg:text-4xl font-bold text-white tracking-tight">
                  {sectionTitle}
                </h2>
                <Link to="/events" className="hidden sm:flex items-center gap-1.5 text-brand-400 hover:text-brand-300 font-medium transition-colors">
                  View all <ArrowRight className="w-4 h-4" />
                </Link>
              </div>
              <div className="space-y-12">
                {dayKeys.map(day => (
                  <div key={day}>
                    <h3 className="text-sm font-semibold uppercase tracking-widest text-brand-400 mb-5 pb-3 border-b border-white/10">
                      {day}
                    </h3>
                    <div className="space-y-4">
                      {groupedEvents[day].map(event => (
                        <Link
                          key={event.id}
                          to={`/events/${event.slug || event.id}`}
                          className="group flex flex-col sm:flex-row gap-4 sm:gap-6 p-3 -mx-3 rounded-xl hover:bg-white/5 transition-colors duration-200"
                        >
                          <div className="sm:w-48 lg:w-56 flex-shrink-0 aspect-[16/10] sm:aspect-[16/11] rounded-lg overflow-hidden bg-neutral-800">
                            {event.cover_image_url ? (
                              <img
                                src={event.cover_image_url}
                                alt={event.title}
                                className="w-full h-full object-cover group-hover:scale-105 transition-transform duration-500"
                              />
                            ) : (
                              <div className="w-full h-full bg-gradient-to-br from-brand-800 to-brand-900 flex items-center justify-center">
                                <Calendar className="w-8 h-8 text-brand-500/50" />
                              </div>
                            )}
                          </div>
                          <div className="flex flex-col justify-center min-w-0 py-1">
                            <div className="flex items-center gap-3 text-sm text-white/40 mb-2">
                              <span className="flex items-center gap-1.5">
                                <Clock className="w-3.5 h-3.5" />
                                {formatTime(event.starts_at)}
                              </span>
                              {event.venue_name && (
                                <span className="flex items-center gap-1.5">
                                  <MapPin className="w-3.5 h-3.5" />
                                  {event.venue_name}
                                </span>
                              )}
                            </div>
                            <h4 className="text-lg lg:text-xl font-semibold text-white group-hover:text-brand-400 transition-colors truncate">
                              {event.title}
                            </h4>
                            {event.short_description && (
                              <p className="text-sm text-white/40 mt-1 line-clamp-1">{event.short_description}</p>
                            )}
                            {getLowestPrice(event.ticket_types) && (
                              <span className="mt-2 text-sm font-medium text-accent-400">
                                {getLowestPrice(event.ticket_types) === 'Free' ? 'Free' : `From ${getLowestPrice(event.ticket_types)}`}
                              </span>
                            )}
                          </div>
                        </Link>
                      ))}
                    </div>
                  </div>
                ))}
              </div>
              <Link to="/events" className="sm:hidden flex items-center justify-center gap-1.5 text-brand-400 hover:text-brand-300 font-medium mt-8 transition-colors">
                View all events <ArrowRight className="w-4 h-4" />
              </Link>
              </FadeUp>
            </>
          ) : (
            !loading && (
              <div className="text-center py-12">
                <h2 className="font-display text-3xl lg:text-4xl font-bold text-white tracking-tight mb-4">This Week on Guam</h2>
                <p className="text-white/40 text-lg">No events yet — check back soon!</p>
              </div>
            )
          )}
        </div>
      </section>

      {/* ── Category Browsing ── */}
      <section className="py-16 lg:py-24 bg-neutral-900/50">
        <div className="max-w-6xl mx-auto px-6 lg:px-8">
          <FadeUp>
          <h2 className="font-display text-3xl lg:text-4xl font-bold text-white tracking-tight mb-12">
            Explore by Category
          </h2>
          <div className="grid grid-cols-2 lg:grid-cols-3 gap-4 lg:gap-5">
            {CATEGORY_IMAGES.map(cat => (
              <Link
                key={cat.slug}
                to={`/events?category=${cat.slug}`}
                className="group relative aspect-[4/3] rounded-xl overflow-hidden"
              >
                <img
                  src={cat.image}
                  alt={cat.name}
                  className="absolute inset-0 w-full h-full object-cover group-hover:scale-110 transition-transform duration-700"
                />
                <div className="absolute inset-0 bg-gradient-to-t from-black/70 via-black/20 to-transparent group-hover:from-black/80 transition-colors duration-300" />
                <div className="absolute bottom-0 left-0 right-0 p-5">
                  <h3 className="text-lg lg:text-xl font-bold text-white">{cat.name}</h3>
                </div>
              </Link>
            ))}
          </div>
          </FadeUp>
        </div>
      </section>

      {/* ── Organizer CTA ── */}
      <section className="py-20 lg:py-28 bg-neutral-950">
        <div className="max-w-3xl mx-auto px-6 lg:px-8 text-center">
          <h2 className="text-3xl lg:text-4xl font-bold text-white tracking-tight mb-4">
            {hasEvents ? 'Want to bring your event to Guam?' : 'Be the first to host an event on Guam'}
          </h2>
          <p className="text-white/40 text-lg mb-8">
            Create your organizer profile and start selling tickets in minutes.
          </p>
          <Link
            to="/sign-up"
            className="inline-flex items-center gap-2 px-8 py-4 bg-brand-500 hover:bg-brand-600 text-white font-semibold rounded-xl transition-all duration-200 text-lg hover:-translate-y-0.5 hover:shadow-lg hover:shadow-brand-500/25 active:translate-y-0"
          >
            Start Hosting
            <ArrowRight className="w-5 h-5" />
          </Link>
        </div>
      </section>

      <Footer />
    </div>
  )
}
