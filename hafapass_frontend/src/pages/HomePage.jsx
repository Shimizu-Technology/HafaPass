import { useState, useEffect } from 'react'
import { Link } from 'react-router-dom'
import { motion } from 'framer-motion'
import { Search, Calendar, MapPin, Sparkles, Music, Moon, UtensilsCrossed, Trophy, Users, PartyPopper, ArrowRight } from 'lucide-react'
import apiClient from '../api/client'
import EventCard from '../components/EventCard'
import Footer from '../components/Footer'

const categories = [
  { label: 'All', value: 'all', icon: Sparkles },
  { label: 'Music', value: 'music', icon: Music },
  { label: 'Nightlife', value: 'nightlife', icon: Moon },
  { label: 'Food & Drink', value: 'food_and_drink', icon: UtensilsCrossed },
  { label: 'Sports', value: 'sports', icon: Trophy },
  { label: 'Community', value: 'community', icon: Users },
  { label: 'Festivals', value: 'festivals', icon: PartyPopper },
]

export default function HomePage() {
  const [events, setEvents] = useState([])
  const [loading, setLoading] = useState(true)
  const [activeCategory, setActiveCategory] = useState('all')
  const [searchQuery, setSearchQuery] = useState('')

  useEffect(() => {
    apiClient.get('/events')
      .then(res => {
        const data = res.data.events || res.data || []
        setEvents(data)
      })
      .catch(() => setEvents([]))
      .finally(() => setLoading(false))
  }, [])

  const filtered = events.filter(e => {
    const matchesCategory = activeCategory === 'all' || e.category === activeCategory
    const matchesSearch = !searchQuery || e.title?.toLowerCase().includes(searchQuery.toLowerCase())
    return matchesCategory && matchesSearch
  })

  const featuredEvents = filtered.filter(e => e.is_featured).slice(0, 2)
  const gridEvents = filtered.filter(e => !e.is_featured || !featuredEvents.includes(e))

  const formatDate = (dateStr) => {
    const d = new Date(dateStr)
    return d.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' })
  }

  const formatTime = (dateStr) => {
    const d = new Date(dateStr)
    return d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })
  }

  const getPrice = (event) => {
    const lowest = event.ticket_types?.reduce((min, tt) => {
      const p = tt.price_cents ?? 0
      return min === null ? p : Math.min(min, p)
    }, null)
    if (lowest === null) return ''
    return lowest === 0 ? 'Free' : `From $${(lowest / 100).toFixed(0)}`
  }

  return (
    <div className="min-h-screen bg-white">
      {/* ── Minimal Hero ── */}
      <section className="relative overflow-hidden">
        <div className="absolute inset-0 bg-gradient-to-b from-brand-50/60 via-white to-white" />
        <div className="absolute inset-0 bg-[radial-gradient(circle_at_1px_1px,rgba(13,158,150,0.04)_1px,transparent_0)] bg-[size:32px_32px]" />

        <div className="relative max-w-3xl mx-auto px-6 pt-24 pb-12 lg:pt-36 lg:pb-16 text-center">
          <motion.div
            initial={{ opacity: 0, y: 16 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.5 }}
            className="mb-8"
          >
            <div className="inline-flex items-center justify-center w-14 h-14 rounded-2xl bg-gradient-to-br from-brand-500 to-brand-600 shadow-lg mb-6">
              <span className="text-white font-bold text-xl">H</span>
            </div>
          </motion.div>

          <motion.h1
            className="text-3xl sm:text-4xl lg:text-5xl font-bold tracking-tight text-neutral-900 mb-10"
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, delay: 0.1 }}
          >
            What's happening on{' '}
            <span className="bg-gradient-to-r from-brand-500 to-brand-600 bg-clip-text text-transparent">Guam</span>
          </motion.h1>

          <motion.div
            className="max-w-lg mx-auto"
            initial={{ opacity: 0, y: 16 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.5, delay: 0.25 }}
          >
            <div className="relative">
              <Search className="absolute left-4 top-1/2 -translate-y-1/2 w-5 h-5 text-neutral-400" />
              <input
                type="text"
                placeholder="Search events..."
                value={searchQuery}
                onChange={e => setSearchQuery(e.target.value)}
                className="w-full pl-12 pr-4 py-4 rounded-2xl bg-white border border-neutral-200 shadow-soft text-neutral-900 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-brand-500/30 focus:border-brand-400 transition-all text-base"
              />
            </div>
          </motion.div>
        </div>
      </section>

      {/* ── Category Pills ── */}
      <section className="sticky top-0 z-20 bg-white/80 backdrop-blur-lg border-b border-neutral-100">
        <div className="max-w-6xl mx-auto px-6">
          <div className="flex gap-2 py-3 overflow-x-auto scrollbar-hide">
            {categories.map(cat => {
              const Icon = cat.icon
              const active = activeCategory === cat.value
              return (
                <button
                  key={cat.value}
                  onClick={() => setActiveCategory(cat.value)}
                  className={`flex-shrink-0 inline-flex items-center gap-1.5 px-4 py-2 rounded-full text-sm font-medium transition-all ${
                    active
                      ? 'bg-brand-500 text-white shadow-sm'
                      : 'bg-neutral-100 text-neutral-600 hover:bg-neutral-200'
                  }`}
                >
                  <Icon className="w-3.5 h-3.5" />
                  {cat.label}
                </button>
              )
            })}
          </div>
        </div>
      </section>

      {/* ── Main Content ── */}
      <div className="max-w-6xl mx-auto px-6 py-10 lg:py-14">
        {loading ? (
          /* Loading skeleton */
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6">
            {[...Array(6)].map((_, i) => (
              <div key={i} className="animate-pulse rounded-2xl bg-neutral-100 h-72" />
            ))}
          </div>
        ) : filtered.length === 0 && events.length === 0 ? (
          /* ── Empty State ── */
          <motion.div
            className="text-center py-24"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.5 }}
          >
            <div className="inline-flex items-center justify-center gap-3 mb-8">
              <div className="w-12 h-12 rounded-2xl bg-brand-50 flex items-center justify-center">
                <Calendar className="w-6 h-6 text-brand-500" />
              </div>
              <div className="w-12 h-12 rounded-2xl bg-accent-50 flex items-center justify-center">
                <Music className="w-6 h-6 text-accent-500" />
              </div>
              <div className="w-12 h-12 rounded-2xl bg-violet-50 flex items-center justify-center">
                <PartyPopper className="w-6 h-6 text-violet-500" />
              </div>
            </div>
            <h2 className="text-2xl font-bold text-neutral-900 mb-3">Events are coming to Guam</h2>
            <p className="text-neutral-500 mb-8 max-w-md mx-auto">
              Be the first to list yours. Create your organizer profile and start selling tickets in minutes.
            </p>
            <Link to="/sign-up" className="btn-primary text-base !px-8 !py-3">
              Get Started Free
            </Link>
          </motion.div>
        ) : (
          <>
            {/* No results for filter */}
            {filtered.length === 0 ? (
              <div className="text-center py-16">
                <p className="text-neutral-500 text-lg">No events found. Try a different search or category.</p>
              </div>
            ) : (
              <>
                {/* ── Featured Events ── */}
                {featuredEvents.length > 0 && (
                  <section className="mb-12">
                    <h2 className="text-sm font-semibold text-neutral-400 uppercase tracking-wider mb-5">Don't Miss</h2>
                    <div className={`grid gap-6 ${featuredEvents.length === 1 ? 'grid-cols-1 max-w-2xl' : 'grid-cols-1 md:grid-cols-2'}`}>
                      {featuredEvents.map((event, i) => (
                        <motion.div
                          key={event.id}
                          initial={{ opacity: 0, y: 20 }}
                          animate={{ opacity: 1, y: 0 }}
                          transition={{ duration: 0.5, delay: i * 0.1 }}
                        >
                          <Link
                            to={`/events/${event.slug || event.id}`}
                            className="group block relative rounded-2xl overflow-hidden h-72 md:h-80 bg-neutral-100"
                          >
                            {event.cover_image_url ? (
                              <img
                                src={event.cover_image_url}
                                alt={event.title}
                                className="absolute inset-0 w-full h-full object-cover transition-transform duration-500 group-hover:scale-105"
                              />
                            ) : (
                              <div className="absolute inset-0 bg-gradient-to-br from-brand-400 to-brand-600" />
                            )}
                            <div className="absolute inset-0 bg-gradient-to-t from-black/70 via-black/20 to-transparent" />
                            <div className="absolute bottom-0 left-0 right-0 p-6">
                              <div className="flex items-center gap-2 text-white/80 text-sm mb-2">
                                <Calendar className="w-3.5 h-3.5" />
                                {formatDate(event.starts_at)} · {formatTime(event.starts_at)}
                              </div>
                              <h3 className="text-xl md:text-2xl font-bold text-white mb-1 group-hover:underline decoration-2 underline-offset-4">
                                {event.title}
                              </h3>
                              <div className="flex items-center gap-3 text-white/70 text-sm">
                                {event.venue_name && (
                                  <span className="flex items-center gap-1">
                                    <MapPin className="w-3.5 h-3.5" />
                                    {event.venue_name}
                                  </span>
                                )}
                                {getPrice(event) && (
                                  <span className="px-2 py-0.5 rounded-full bg-white/20 text-white text-xs font-medium">
                                    {getPrice(event)}
                                  </span>
                                )}
                              </div>
                            </div>
                          </Link>
                        </motion.div>
                      ))}
                    </div>
                  </section>
                )}

                {/* ── Event Grid ── */}
                {gridEvents.length > 0 && (
                  <section>
                    {featuredEvents.length > 0 && (
                      <h2 className="text-sm font-semibold text-neutral-400 uppercase tracking-wider mb-5">All Events</h2>
                    )}
                    <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6">
                      {gridEvents.map((event, i) => (
                        <motion.div
                          key={event.id}
                          initial={{ opacity: 0, y: 16 }}
                          whileInView={{ opacity: 1, y: 0 }}
                          viewport={{ once: true, margin: '-5%' }}
                          transition={{ duration: 0.4, delay: i * 0.05 }}
                        >
                          <EventCard event={event} />
                        </motion.div>
                      ))}
                    </div>
                  </section>
                )}
              </>
            )}
          </>
        )}
      </div>

      {/* ── Organizer CTA ── */}
      <section className="py-16 lg:py-20">
        <div className="max-w-6xl mx-auto px-6 text-center">
          <motion.div
            initial={{ opacity: 0, y: 16 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true }}
            transition={{ duration: 0.5 }}
          >
            <p className="text-lg text-neutral-500 mb-5">Hosting an event on Guam?</p>
            <Link to="/sign-up" className="group inline-flex items-center gap-2 btn-primary text-base !px-8 !py-3">
              Get Started Free
              <ArrowRight className="w-4 h-4 transition-transform group-hover:translate-x-1" />
            </Link>
          </motion.div>
        </div>
      </section>

      <Footer />
    </div>
  )
}
