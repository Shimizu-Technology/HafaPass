import { useState, useEffect } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { Loader2, Search, Music, UtensilsCrossed, Trophy, Users, Sparkles, Moon, CalendarPlus, Ticket } from 'lucide-react'
import { motion } from 'framer-motion'
import apiClient from '../api/client'
import EventCard from '../components/EventCard'
import SEO from '../components/SEO'
import { StaggerContainer, StaggerItem } from '../components/ui/ScrollReveal'
import NoiseOverlay from '../components/ui/NoiseOverlay'
import { EventCardSkeleton } from '../components/ui/Skeleton'
import useEventCategories from '../hooks/useEventCategories'
import { PUBLIC_WEB_URL } from '../utils/site'

const CATEGORY_ICONS = { concert: Music, dining: UtensilsCrossed, sports: Trophy, festival: Users, nightlife: Moon }

function guamDate(offsetDays = 0) {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'Pacific/Guam', year: 'numeric', month: '2-digit', day: '2-digit'
  }).formatToParts(new Date())
  const value = type => Number(parts.find(part => part.type === type)?.value)
  return new Date(Date.UTC(value('year'), value('month') - 1, value('day') + offsetDays)).toISOString().slice(0, 10)
}

export default function EventsPage() {
  const [events, setEvents] = useState([])
  const [loading, setLoading] = useState(true)
  const [meta, setMeta] = useState({ current_page: 1, total_pages: 1, total_count: 0 })
  const [searchParams, setSearchParams] = useSearchParams()
  const [search, setSearch] = useState(searchParams.get('search') || '')
  const [activeCategory, setActiveCategory] = useState(searchParams.get('category') || 'all')
  const [dateRange, setDateRange] = useState(searchParams.get('date') || 'upcoming')
  const [page, setPage] = useState(Number(searchParams.get('page')) || 1)
  const categories = useEventCategories()

  useEffect(() => {
    const timer = setTimeout(() => {
      setLoading(true)
      const params = { page, per_page: 12 }
      if (search.trim()) params.q = search.trim()
      if (activeCategory !== 'all') params.category = activeCategory
      if (dateRange === 'today') {
        params.date_from = guamDate()
        params.date_to = guamDate()
      } else if (dateRange === 'week') {
        params.date_from = guamDate()
        params.date_to = guamDate(7)
      }

      apiClient.get('/events', { params })
      .then(res => {
        const data = res.data.events || res.data
        setEvents(Array.isArray(data) ? data : [])
        setMeta(res.data.meta || { current_page: 1, total_pages: 1, total_count: data.length })
      })
      .catch(() => { setEvents([]); setMeta({ current_page: 1, total_pages: 1, total_count: 0 }) })
      .finally(() => setLoading(false))

      const nextParams = {}
      if (search.trim()) nextParams.search = search.trim()
      if (activeCategory !== 'all') nextParams.category = activeCategory
      if (dateRange !== 'upcoming') nextParams.date = dateRange
      if (page > 1) nextParams.page = String(page)
      setSearchParams(nextParams, { replace: true })
    }, 250)

    return () => clearTimeout(timer)
  }, [search, activeCategory, dateRange, page, setSearchParams])

  const changeCategory = (value) => { setActiveCategory(value); setPage(1) }
  const clearFilters = () => { setSearch(''); setActiveCategory('all'); setDateRange('upcoming'); setPage(1) }

  return (
    <div className="min-h-screen">
      <SEO
        title="Browse Events"
        description="Discover what's happening on Guam. Browse concerts, nightlife, festivals, dining, sports, and more."
        url={`${PUBLIC_WEB_URL}/events`}
      />
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
          <div className="flex flex-col gap-4 mb-8">
           <div className="flex flex-wrap gap-2">
            {[{ value: 'all', label: 'All Events' }, ...categories].map(({ value, label }) => {
              const Icon = value === 'all' ? Ticket : (CATEGORY_ICONS[value] || Sparkles)
              return (
              <button
                key={value}
                onClick={() => changeCategory(value)}
                aria-pressed={activeCategory === value}
                className={`inline-flex items-center gap-1.5 px-4 py-2 rounded-full text-sm font-medium transition-all duration-200 ${
                  activeCategory === value
                    ? 'bg-brand-500 text-white shadow-md shadow-brand-500/20'
                    : 'bg-white text-neutral-600 border border-neutral-200 hover:border-brand-300 hover:text-brand-600'
                }`}
              >
                <Icon className="w-3.5 h-3.5" />
                {label}
              </button>
            )})}
           </div>
           <div className="flex items-center gap-3">
            <label htmlFor="event-date-range" className="text-sm font-medium text-neutral-600">When</label>
            <select id="event-date-range" value={dateRange} onChange={event => { setDateRange(event.target.value); setPage(1) }} className="input max-w-[12rem] !py-2">
             <option value="upcoming">All upcoming</option>
             <option value="today">Today</option>
             <option value="week">Next 7 days</option>
            </select>
            {!loading && <span className="text-sm text-neutral-500">{meta.total_count} event{meta.total_count === 1 ? '' : 's'}</span>}
           </div>
          </div>

          {loading ? (
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6">
              {Array.from({ length: 6 }).map((_, i) => <EventCardSkeleton key={i} />)}
            </div>
          ) : events.length === 0 ? (
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
                {search || activeCategory !== 'all' || dateRange !== 'upcoming' ? 'No matching events' : 'No events yet'}
              </h2>
              <p className="text-neutral-500 max-w-md mx-auto mb-8">
                {!search && activeCategory === 'all' && dateRange === 'upcoming'
                  ? "Events on Guam will show up here. Be the first to create one and get the island buzzing!"
                  : "Try adjusting your search or filters to find what you're looking for."
                }
              </p>

              {!search && activeCategory === 'all' && dateRange === 'upcoming' && (
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

              {(search || activeCategory !== 'all' || dateRange !== 'upcoming') && (
                <button
                  onClick={clearFilters}
                  className="text-brand-500 hover:text-brand-600 font-medium transition-colors"
                >
                  Clear filters
                </button>
              )}
            </motion.div>
          ) : (
            <StaggerContainer className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6">
              {events.map(event => <StaggerItem key={event.id}><EventCard event={event} /></StaggerItem>)}
            </StaggerContainer>
          )}
          {!loading && meta.total_pages > 1 && (
            <nav className="mt-10 flex items-center justify-center gap-3" aria-label="Event results pages">
              <button type="button" className="btn-secondary" disabled={!meta.prev_page} onClick={() => setPage(meta.prev_page)}>Previous</button>
              <span className="text-sm text-neutral-600">Page {meta.current_page} of {meta.total_pages}</span>
              <button type="button" className="btn-secondary" disabled={!meta.next_page} onClick={() => setPage(meta.next_page)}>Next</button>
            </nav>
          )}
        </div>
      </div>
    </div>
  )
}
