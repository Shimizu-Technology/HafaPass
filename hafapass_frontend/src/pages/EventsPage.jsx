import { useState, useEffect } from 'react'
import { Link, useSearchParams, useMatch } from 'react-router-dom'
import { Search, Music, UtensilsCrossed, Trophy, Users, Sparkles, Moon, CalendarPlus, Ticket } from 'lucide-react'
import { motion, useReducedMotion } from 'framer-motion'
import apiClient from '../api/client'
import EventCard from '../components/EventCard'
import SEO from '../components/SEO'
import { StaggerContainer, StaggerItem } from '../components/ui/ScrollReveal'
import { EventCardSkeleton } from '../components/ui/Skeleton'
import useEventCategories from '../hooks/useEventCategories'
import { PUBLIC_WEB_URL } from '../utils/site'

const CATEGORY_ICONS = { concert: Music, dining: UtensilsCrossed, sports: Trophy, festival: Users, nightlife: Moon }
const GUAM_VILLAGES = ['Agana Heights','Asan-Maina','Barrigada','Chalan Pago-Ordot','Dededo','Hagåtña','Humåtak','Inalåhan','Mangilao','Malesso’','Mongmong-Toto-Maite','Piti','Sånta Rita-Sumai','Sinajana','Talo’fo’fo','Tamuning-Tumon-Harmon','Yigo','Yona']

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
  const [loadError, setLoadError] = useState(false)
  const [retry, setRetry] = useState(0)
  const [meta, setMeta] = useState({ current_page: 1, total_pages: 1, total_count: 0 })
  const onListingRoute = Boolean(useMatch('/events'))
  const [searchParams, setSearchParams] = useSearchParams()
  const [search, setSearch] = useState(searchParams.get('search') || '')
  const [activeCategory, setActiveCategory] = useState(searchParams.get('category') || 'all')
  const [dateRange, setDateRange] = useState(searchParams.get('date') || 'upcoming')
  const [price, setPrice] = useState(searchParams.get('price') || 'all')
  const [village, setVillage] = useState(searchParams.get('village') || '')
  const [page, setPage] = useState(Number(searchParams.get('page')) || 1)
  const categories = useEventCategories()
  const reducedMotion = useReducedMotion()
  const ResultsContainer = reducedMotion ? 'div' : StaggerContainer
  const ResultItem = reducedMotion ? 'div' : StaggerItem

  useEffect(() => {
    if (!onListingRoute) return undefined
    let active = true
    setLoading(true)
    setLoadError(false)
    const timer = setTimeout(() => {
      const params = { page, per_page: 12 }
      if (search.trim()) params.q = search.trim()
      if (activeCategory !== 'all') params.category = activeCategory
      if (price !== 'all') params.price = price
      if (village) params.village = village
      if (dateRange === 'today') {
        params.date_from = guamDate()
        params.date_to = guamDate()
      } else if (dateRange === 'week') {
        params.date_from = guamDate()
        params.date_to = guamDate(7)
      } else if (dateRange === 'tonight' || dateRange === 'weekend') {
        params.window = dateRange
      }

      apiClient.get('/events', { params })
      .then(res => {
        if (!active) return
        const data = res.data.events || res.data
        setEvents(Array.isArray(data) ? data : [])
        setMeta(res.data.meta || { current_page: 1, total_pages: 1, total_count: data.length })
      })
      .catch(() => {
        if (!active) return
        setEvents([])
        setLoadError(true)
      })
      .finally(() => { if (active) setLoading(false) })

    }, 250)

    return () => { active = false; clearTimeout(timer) }
  }, [search, activeCategory, dateRange, price, village, page, retry, onListingRoute])

  useEffect(() => {
    if (!onListingRoute) return
    const nextParams = {}
    if (search.trim()) nextParams.search = search.trim()
    if (activeCategory !== 'all') nextParams.category = activeCategory
    if (dateRange !== 'upcoming') nextParams.date = dateRange
    if (price !== 'all') nextParams.price = price
    if (village) nextParams.village = village
    if (page > 1) nextParams.page = String(page)
    if (searchParams.toString() !== new URLSearchParams(nextParams).toString()) {
      setSearchParams(nextParams, { replace: true })
    }
  }, [search, activeCategory, dateRange, price, village, page, searchParams, setSearchParams, onListingRoute])

  const changeCategory = (value) => { setActiveCategory(value); setPage(1) }
  const clearFilters = () => { setSearch(''); setActiveCategory('all'); setDateRange('upcoming'); setPrice('all'); setVillage(''); setPage(1) }

  if (!onListingRoute) return null

  return (
    <div className="min-h-screen bg-stone-50">
      <SEO
        title="Browse Events"
        description="Discover what's happening on Guam. Browse concerts, nightlife, festivals, dining, sports, and more."
        url={`${PUBLIC_WEB_URL}/events`}
      />
      {/* Event guide header */}
      <div className="border-b border-neutral-200 bg-stone-50 py-8 sm:py-10">
        <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
          <div className="mb-6 flex flex-wrap items-start justify-between gap-3"><div>
            <h1 className="font-display text-3xl sm:text-4xl font-bold tracking-tight text-neutral-950 mb-2">Events</h1>
            <p className="text-content-muted text-base">Discover what's happening on Guam</p>
          </div><Link to="/dashboard" className="inline-flex min-h-11 items-center rounded text-sm font-semibold text-brand-800 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2">For event organizers</Link></div>

          {/* Search bar */}
          <div className="max-w-2xl">
            <label htmlFor="browse-event-search" className="mb-2 block text-sm font-medium text-neutral-800">Search events and venues</label>
            <div className="relative">
              <Search aria-hidden="true" className="absolute left-4 top-1/2 -translate-y-1/2 w-5 h-5 text-neutral-500" />
              <input
                id="browse-event-search"
                type="text"
                aria-label="Search events and venues"
                value={search}
                onChange={(e) => { setSearch(e.target.value); setPage(1) }}
                placeholder="Search events, venues..."
                className="input min-h-12 !pl-12"
              />
            </div>
          </div>
        </div>
      </div>

      {/* Light content area */}
      <div className="bg-stone-50 min-h-[50vh]">
        <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
          {/* Responsive discovery filters */}
          <div className="flex flex-col gap-4 mb-8">
           <div className="hidden sm:flex sm:flex-wrap gap-2">
            {[{ value: 'all', label: 'All Events' }, ...categories].map(({ value, label }) => {
              const Icon = value === 'all' ? Ticket : (CATEGORY_ICONS[value] || Sparkles)
              return (
              <button
                key={value}
                onClick={() => changeCategory(value)}
                aria-pressed={activeCategory === value}
                className={`inline-flex min-h-11 items-center gap-1.5 px-4 py-2 rounded-lg text-sm font-medium transition-colors duration-150 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2 ${
                  activeCategory === value
                    ? 'bg-brand-700 text-white'
                    : 'bg-white text-neutral-600 border border-neutral-200 hover:border-brand-300 hover:text-brand-600'
                }`}
              >
                <Icon aria-hidden="true" className="w-4 h-4" />
                {label}
              </button>
            )})}
           </div>
           <div className="grid grid-cols-2 gap-2 sm:gap-3 lg:grid-cols-[12rem_10rem_minmax(16rem,1fr)]">
            <div className="col-span-2 min-w-0 sm:hidden">
             <label htmlFor="event-category" className="mb-1 block text-sm font-medium text-neutral-600">Category</label>
             <select id="event-category" value={activeCategory} onChange={event => changeCategory(event.target.value)} className="input min-h-11 !py-2 text-base !px-3">
              <option value="all">All Events</option>
              {categories.map(({ value, label }) => <option key={value} value={value}>{label}</option>)}
             </select>
            </div>
            <div className="min-w-0">
             <label htmlFor="event-date-range" className="mb-1 block text-sm font-medium text-neutral-600">When</label>
             <select id="event-date-range" value={dateRange} onChange={event => { setDateRange(event.target.value); setPage(1) }} className="input min-h-11 !py-2 text-base !px-2 sm:!px-4">
             <option value="upcoming">All upcoming</option>
             <option value="today">Today</option>
             <option value="tonight">Tonight</option>
             <option value="weekend">This weekend</option>
             <option value="week">Next 7 days</option>
             </select>
            </div>
            <div className="min-w-0">
             <label htmlFor="event-price" className="mb-1 block text-sm font-medium text-neutral-600">Price</label>
             <select id="event-price" value={price} onChange={event => { setPrice(event.target.value); setPage(1) }} className="input min-h-11 !py-2 text-base !px-2 sm:!px-4"><option value="all">Any price</option><option value="free">Free</option><option value="under_25">Under $25</option><option value="under_50">Under $50</option></select>
            </div>
            <div className="min-w-0 col-span-2 lg:col-span-1">
             <label htmlFor="event-village" className="mb-1 block text-sm font-medium text-neutral-600">Village</label>
             <select id="event-village" value={village} onChange={event => { setVillage(event.target.value); setPage(1) }} className="input min-h-11 !py-2"><option value="">All villages</option>{GUAM_VILLAGES.map(item => <option key={item}>{item}</option>)}</select>
            </div>
           </div>
           {!loading && !loadError && <span role="status" className="text-sm text-content-muted">{meta.total_count} event{meta.total_count === 1 ? '' : 's'}</span>}
          </div>

          {loading ? (
            <div role="status" aria-label="Loading events"><p className="sr-only">Loading events…</p><div aria-hidden="true" className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6">
              {Array.from({ length: 6 }).map((_, i) => <EventCardSkeleton key={i} />)}
            </div></div>
          ) : loadError ? (
            <div role="alert" className="rounded-2xl border border-neutral-200 bg-white p-6 sm:p-10 text-center">
              <h2 className="text-xl font-bold text-neutral-900 mb-2">Couldn't load events</h2>
              <p className="text-neutral-600 mb-6">Your filters are saved. Try again to see the matching events.</p>
              <button type="button" onClick={() => setRetry(value => value + 1)} className="btn-primary">Try again</button>
            </div>
          ) : events.length === 0 ? (
            <motion.div
              initial={false}
              animate={{ opacity: 1, y: 0 }}
              className="rounded-xl border border-neutral-200 bg-white px-5 py-8 sm:p-10 text-center"
            >
              <Ticket aria-hidden="true" className="mx-auto mb-4 h-8 w-8 text-brand-800" />

              <h2 className="text-xl font-bold text-neutral-900 mb-2">
                {search || activeCategory !== 'all' || dateRange !== 'upcoming' || price !== 'all' || village ? 'No matching events' : 'No events yet'}
              </h2>
              <p className="text-neutral-600 max-w-md mx-auto mb-8">
                {!search && activeCategory === 'all' && dateRange === 'upcoming' && price === 'all' && !village
                  ? "There are no upcoming events listed right now. Check back for new dates, or set up your own event."
                  : "Try adjusting your search or filters to find what you're looking for."
                }
              </p>

              {!search && activeCategory === 'all' && dateRange === 'upcoming' && price === 'all' && !village && (
                <div className="flex flex-col sm:flex-row items-center justify-center gap-3">
                  <Link
                    to="/dashboard"
                    className="inline-flex min-h-11 items-center gap-2 px-5 py-3 bg-action text-white rounded-lg font-semibold hover:bg-action-hover focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2"
                  >
                    <CalendarPlus aria-hidden="true" className="w-4 h-4" />
                    Create an Event
                  </Link>
                  <Link
                    to="/"
                    className="inline-flex min-h-11 items-center rounded text-content-muted hover:text-brand-800 font-medium focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2"
                  >
                    Back to event guide
                  </Link>
                </div>
              )}

              {(search || activeCategory !== 'all' || dateRange !== 'upcoming' || price !== 'all' || village) && (
                <button
                  onClick={clearFilters}
                  className="min-h-11 rounded px-3 text-brand-800 hover:bg-brand-50 font-medium focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2"
                >
                  Clear filters
                </button>
              )}
            </motion.div>
          ) : (
            <ResultsContainer className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6">
              {events.map(event => <ResultItem key={event.id}><EventCard event={event} /></ResultItem>)}
            </ResultsContainer>
          )}
          {!loading && !loadError && meta.total_pages > 1 && (
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
