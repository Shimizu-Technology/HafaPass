import { useState, useEffect } from 'react'
import { Link } from 'react-router-dom'
import { Loader2, Search, Music, UtensilsCrossed, Trophy, Users, Sparkles, Moon, CalendarPlus, Ticket } from 'lucide-react'
import { motion } from 'framer-motion'
import apiClient from '../api/client'
import EventCard from '../components/EventCard'

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
  const [search, setSearch] = useState('')
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
    <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-10">
      <div className="flex flex-col sm:flex-row sm:items-end justify-between gap-4 mb-8">
        <div>
          <h1 className="text-3xl font-bold tracking-tight text-neutral-900">Events</h1>
          <p className="text-neutral-500 mt-1">Discover what's happening on Guam</p>
        </div>
        <div className="relative max-w-xs w-full">
          <Search className="absolute left-3.5 top-1/2 -translate-y-1/2 w-4 h-4 text-neutral-400" />
          <input
            type="text" value={search} onChange={(e) => setSearch(e.target.value)}
            placeholder="Search events..." className="input !pl-10 !py-2.5 text-sm"
          />
        </div>
      </div>

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
        <div className="flex justify-center py-20">
          <Loader2 className="w-8 h-8 text-brand-500 animate-spin" />
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
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6">
          {filtered.map(event => <EventCard key={event.id} event={event} />)}
        </div>
      )}
    </div>
  )
}
