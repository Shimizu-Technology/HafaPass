import { useState, useEffect } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { Loader2, Search, Music, UtensilsCrossed, Trophy, Users, Sparkles, Moon, CalendarPlus, Ticket } from 'lucide-react'
import { motion } from 'framer-motion'
import apiClient from '../api/client'
import EventCard from '../components/EventCard'
import { StaggerContainer, StaggerItem } from '../components/ui/ScrollReveal'
import NoiseOverlay from '../components/ui/NoiseOverlay'
import { EventCardSkeleton } from '../components/ui/Skeleton'

const categories = [
  { key: 'all', label: 'All Events', icon: Ticket },
  { key: 'concert', label: 'Music', icon: Music },
  { key: 'dining', label: 'Food & Drink', icon: UtensilsCrossed },
  { key: 'sports', label: 'Sports', icon: Trophy },
  { key: 'festival', label: 'Community', icon: Users },
  { key: 'nightlife', label: 'Nightlife', icon: Moon },
  { key: 'other', label: 'Other', icon: Sparkles },
]

export default function EventsPage() {
  const [events, setEvents] = useState([])
  const [loading, setLoading] = useState(true)
  const [searchParams] = useSearchParams()
  const [search, setSearch] = useState(searchParams.get('search') || '')
  const [activeCategory, setActiveCategory] = useState('all')

  useEffect(() => {
    apiClient.get('/events')
      .then(res => {
        const data = res.data.events || res.data
        setEvents(Array.isArray(data) ? data : [])
        setLoading(false)
      })
      .catch(() => setLoading(false))
  }, [])

  const filtered = events.filter(e => {
    const matchesSearch = e.title.toLowerCase().includes(search.toLowerCase()) ||
      e.venue_name?.toLowerCase().includes(search.toLowerCase())
    const matchesCategory = activeCategory === 'all' || e.category === activeCategory
    return matchesSearch && matchesCategory
  })

  return (
    <div className="min-h-screen">
      {/* Dark Header Section */}
      <div className="bg-neutral-950 pt-8 pb-12 sm:pb-16 relative">
        <NoiseOverlay />
        <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 relative z-[2]">
          <div className="text-center mb-8">
            <h1 className="font-display text-3xl sm:text-4xl font-bold tracking-tight text-white mb-2">Events</h1>
            <p className="text-neutral-400 text-lg">Discover what's happening on Guam</p>
          </div>

          {/* Search bar */}
          <div className="max-w-lg mx-auto">
            <div className="relative">
              <Search className="absolute left-4 top-1/2 -translate-y-1/2 w-5 h-5 text-neutral-500" />
              <input
                type="text"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                placeholder="Search events, venues..."
                className="w-full pl-12 pr-4 py-3.5 text-sm rounded-2xl border border-white/10 bg-white/5 backdrop-blur-sm text-white placeholder-neutral-500 focus:outline-none focus:ring-2 focus:ring-brand-500/40 focus:border-brand-500/40 transition-all"
              />
            </div>
          </div>
        </div>
      </div>

      {/* Gradient transition */}
      <div className="h-px bg-gradient-to-r from-transparent via-brand-500/20 to-transparent" />

      {/* Light content area */}
      <div className="bg-neutral-50 min-h-[50vh]">
        <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
          {/* Category Filter Chips */}
          <div className="flex flex-wrap gap-2 mb-8">
            {categories.map(({ key, label, icon: Icon }) => (
              <button
                key={key}
                onClick={() => setActiveCategory(key)}
                className={`inline-flex items-center gap-1.5 px-4 py-2 rounded-full text-sm font-medium transition-all duration-200 ${
                  activeCategory === key
                    ? 'bg-brand-500 text-white shadow-md shadow-brand-500/20'
                    : 'bg-white text-neutral-600 border border-neutral-200 hover:border-brand-300 hover:text-brand-600'
                }`}
              >
                <Icon className="w-3.5 h-3.5" />
                {label}
              </button>
            ))}
          </div>

          {loading ? (
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6">
              {Array.from({ length: 6 }).map((_, i) => <EventCardSkeleton key={i} />)}
            </div>
          ) : filtered.length === 0 ? (
            <motion.div
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              className="rounded-2xl border border-neutral-200 bg-white p-12 sm:p-16 text-center"
            >
              {/* Icon grid */}
              <div className="flex items-center justify-center gap-3 mb-6">
                {[Music, UtensilsCrossed, Trophy, Moon, Sparkles].map((Icon, i) => (
                  <div
                    key={i}
                    className="w-12 h-12 rounded-2xl bg-gradient-to-br from-brand-50 to-brand-100 flex items-center justify-center"
                    style={{ animationDelay: `${i * 0.1}s` }}
                  >
                    <Icon className="w-5 h-5 text-brand-500" />
                  </div>
                ))}
              </div>

              <h2 className="text-xl font-bold text-neutral-900 mb-2">
                {events.length === 0 ? 'No events yet' : 'No matching events'}
              </h2>
              <p className="text-neutral-500 max-w-md mx-auto mb-8">
                {events.length === 0
                  ? "Events on Guam will show up here. Be the first to create one and get the island buzzing!"
                  : "Try adjusting your search or filters to find what you're looking for."
                }
              </p>

              {events.length === 0 && (
                <div className="flex flex-col sm:flex-row items-center justify-center gap-3">
                  <Link
                    to="/sign-up"
                    className="inline-flex items-center gap-2 px-6 py-3 bg-brand-500 text-white rounded-xl font-semibold transition-all hover:bg-brand-600 hover:shadow-lg hover:shadow-brand-500/20"
                  >
                    <CalendarPlus className="w-4 h-4" />
                    Create an Event
                  </Link>
                  <Link
                    to="/"
                    className="text-neutral-500 hover:text-neutral-900 font-medium transition-colors"
                  >
                    Learn More
                  </Link>
                </div>
              )}

              {events.length > 0 && (
                <button
                  onClick={() => { setSearch(''); setActiveCategory('all') }}
                  className="text-brand-500 hover:text-brand-600 font-medium transition-colors"
                >
                  Clear filters
                </button>
              )}
            </motion.div>
          ) : (
            <StaggerContainer className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6">
              {filtered.map(event => <StaggerItem key={event.id}><EventCard event={event} /></StaggerItem>)}
            </StaggerContainer>
          )}
        </div>
      </div>
    </div>
  )
}
