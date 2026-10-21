import { useTranslation } from 'react-i18next'
import useContentLanguage from '../hooks/useContentLanguage'
import { useState, useEffect, useMemo } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Calendar, MapPin, ArrowRight, Clock, Search } from 'lucide-react'
import apiClient from '../api/client'
import Footer from '../components/Footer'
import SEO from '../components/SEO'
import { formatEventDate, formatEventTime } from '../utils/eventTime'
import { formatTicketPrice, lowestPurchasablePrice } from '../utils/ticketPricing'
import { categoryIcon } from '../utils/categoryIcons'

const categories = [
  { name: 'Nightlife', slug: 'nightlife' },
  { name: 'Food & Drink', slug: 'dining' },
  { name: 'Music & Concerts', slug: 'concert' },
  { name: 'Sports', slug: 'sports' },
  { name: 'Festivals & Culture', slug: 'festival' },
  { name: 'Classes & Workshops', slug: 'workshop' },
].map(category => ({ ...category, icon: categoryIcon(category.slug) }))

function priceLabel(ticketTypes, t) {
  const cents = lowestPurchasablePrice(ticketTypes)
  const price = formatTicketPrice(cents, t('events.free'))
  return cents === 0 ? price : price ? `${t('events.from')} ${price}` : ''
}

// Images are absolutely positioned inside the sized frame so they never depend on
// percentage heights resolving against an aspect-ratio box. With `backdrop`, a
// blurred copy fills the frame behind the full poster, so portrait flyers in a
// wide frame fill the card without cropping their dates or text.
function EventArtwork({ event, className, priority = false, backdrop = false }) {
  const [failed, setFailed] = useState(false)
  return (
    <div className={`relative overflow-hidden rounded-lg bg-neutral-100 ${className}`}>
      {event.cover_image_url && !failed ? (
        <>
          {backdrop && <img src={event.cover_image_url} alt="" aria-hidden="true" data-testid="artwork-backdrop"
            className="absolute inset-0 h-full w-full scale-110 object-cover opacity-70 blur-2xl" />}
          <img src={event.cover_image_url} alt={`Artwork for ${event.title}`} loading={priority ? 'eager' : 'lazy'} fetchPriority={priority ? 'high' : undefined}
            onError={() => setFailed(true)} className="absolute inset-0 h-full w-full object-contain" />
        </>
      ) : (
        <div className="absolute inset-0 flex items-center justify-center text-brand-700">
          <Calendar aria-hidden="true" className="h-7 w-7" />
          <span className="sr-only">Event artwork unavailable</span>
        </div>
      )}
    </div>
  )
}

export default function HomePage() {
  const { t } = useTranslation()
  const contentLanguage = useContentLanguage()
  const navigate = useNavigate()
  const [events, setEvents] = useState([])
  const [search, setSearch] = useState('')
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState(false)
  const [loadAttempt, setLoadAttempt] = useState(0)

  useEffect(() => {
    let active = true
    setLoading(true)
    setLoadError(false)
    apiClient.get('/events')
      .then(res => {
        if (!active) return
        const data = res.data.events || res.data
        setEvents(Array.isArray(data) ? data : [])
      })
      .catch(() => { if (active) setLoadError(true) })
      .finally(() => { if (active) setLoading(false) })
    return () => { active = false }
  }, [loadAttempt, contentLanguage])

  const featuredEvent = useMemo(() => events
    .filter(event => event.is_featured && new Date(event.starts_at) > new Date())
    .sort((a, b) => new Date(a.starts_at) - new Date(b.starts_at))[0] || null, [events])

  const groupedEvents = useMemo(() => {
    const grouped = {}
    // Preserve the API's active-event eligibility and do not reorder its data in place.
    ;[...events].sort((a, b) => new Date(a.starts_at) - new Date(b.starts_at)).slice(0, 8).forEach(event => {
      const day = formatEventDate(event.starts_at, event.timezone, { weekday: 'long' })
      if (!grouped[day]) grouped[day] = []
      grouped[day].push(event)
    })
    return grouped
  }, [events])
  const dayKeys = Object.keys(groupedEvents)
  const showFeatured = Boolean(featuredEvent) && !loading && !loadError
  const featuredPrice = featuredEvent ? priceLabel(featuredEvent.ticket_types, t) : ''

  const browse = event => {
    event.preventDefault()
    const query = search.trim()
    navigate(query ? `/events?${new URLSearchParams({ search: query })}` : '/events')
  }

  return (
    <div className="min-h-screen bg-stone-50 text-content">
      <SEO />
      <section className="border-b border-neutral-200 py-8 sm:py-12 lg:py-16">
        <div className={`mx-auto max-w-6xl px-4 sm:px-6 lg:px-8 ${showFeatured ? 'grid items-center gap-8 lg:grid-cols-2 lg:gap-12' : ''}`}>
          <div className="max-w-2xl">
            <p className="mb-3 text-sm font-semibold text-brand-800">Your event guide on Guam</p>
            <h1 className="font-display text-4xl font-bold leading-tight tracking-tight text-neutral-950 sm:text-5xl lg:text-[3.5rem]">Find your next event on Guam</h1>
            <p className="mt-4 max-w-lg text-base leading-relaxed text-content-muted">Browse what's coming up, choose your tickets, and keep them ready for the door.</p>
            <form role="search" onSubmit={browse} className="mt-6">
              <label htmlFor="home-event-search" className="mb-2 block text-sm font-medium text-neutral-800">Event or venue</label>
              <div className="flex flex-col gap-2 sm:flex-row">
                <div className="relative min-w-0 flex-1">
                  <Search aria-hidden="true" className="absolute left-3 top-1/2 h-5 w-5 -translate-y-1/2 text-content-muted" />
                  <input id="home-event-search" name="search" type="search" value={search} onChange={event => setSearch(event.target.value)}
                    placeholder="Search events and venues" className="input min-h-12 !pl-10" />
                </div>
                <button type="submit" className="inline-flex min-h-12 items-center justify-center gap-2 rounded-lg bg-action px-5 font-semibold text-white hover:bg-action-hover focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2">Search <ArrowRight aria-hidden="true" className="h-4 w-4" /></button>
              </div>
            </form>
            <div className="mt-4 flex flex-wrap items-center gap-x-6 gap-y-1">
              <Link to="/events" className="inline-flex min-h-11 items-center rounded text-sm font-semibold text-brand-800 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2">Browse Events <ArrowRight aria-hidden="true" className="ml-2 h-4 w-4" /></Link>
              <Link to="/host" className="inline-flex min-h-11 items-center rounded text-sm font-medium text-content-muted hover:text-brand-800 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2">Start Hosting</Link>
            </div>
          </div>

          {showFeatured && (
            <article aria-label="Featured event" className="min-w-0 overflow-hidden rounded-xl border border-neutral-200 bg-white">
              {featuredEvent.cover_image_url && <EventArtwork key={featuredEvent.cover_image_url} event={featuredEvent} priority backdrop className="aspect-[16/9] w-full !rounded-none" />}
              <div className="p-5 sm:p-6">
                <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-brand-800">Featured event</p>
                <h2 className="break-words font-display text-2xl font-bold text-neutral-950">{featuredEvent.title}</h2>
                <p className="mt-3 flex items-start gap-2 text-sm text-content-muted"><Calendar aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" /><span>{formatEventDate(featuredEvent.starts_at, featuredEvent.timezone, { weekday: 'long' })} · {formatEventTime(featuredEvent.starts_at, featuredEvent.timezone)}</span></p>
                {featuredEvent.venue_name && <p className="mt-2 flex items-start gap-2 text-sm text-content-muted"><MapPin aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" /><span className="break-words">{featuredEvent.venue_name}{featuredEvent.venue_city ? `, ${featuredEvent.venue_city}` : ''}</span></p>}
                {featuredPrice && <p className="mt-3 text-sm font-semibold text-neutral-900">{featuredPrice}</p>}
                <Link to={`/events/${featuredEvent.slug || featuredEvent.id}`} className="mt-4 inline-flex min-h-11 items-center gap-2 rounded-lg bg-action px-4 py-2 text-sm font-semibold text-white hover:bg-action-hover focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2">Get Tickets <ArrowRight aria-hidden="true" className="h-4 w-4" /></Link>
              </div>
            </article>
          )}
        </div>
      </section>

      <section aria-busy={loading} aria-labelledby="upcoming-heading" className="py-8 sm:py-12">
        <div className="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8">
          <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
            <h2 id="upcoming-heading" className="font-display text-2xl font-bold tracking-tight text-neutral-950 sm:text-3xl">Next Up on Guam</h2>
            <Link to="/events" className="inline-flex min-h-11 items-center gap-2 rounded text-sm font-semibold text-brand-800 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2">View all events <ArrowRight aria-hidden="true" className="h-4 w-4" /></Link>
          </div>
          {loading ? <p role="status" className="py-8 text-content-muted">Loading upcoming events…</p> : loadError ? (
            <div role="alert" className="rounded-xl border border-neutral-200 bg-white p-6">
              <h3 className="text-xl font-semibold text-neutral-900">Events couldn’t load</h3>
              <p className="mt-2 text-content-muted">Please try again to see what's coming up.</p>
              <button type="button" onClick={() => setLoadAttempt(attempt => attempt + 1)} className="btn-primary mt-4">Retry events</button>
            </div>
          ) : dayKeys.length ? (
            <div className="space-y-8">
              {dayKeys.map(day => (
                <section key={day} aria-label={`Events on ${day}`}>
                  <h3 className="border-b border-neutral-200 pb-3 text-sm font-semibold text-brand-800">{day}</h3>
                  <div className="divide-y divide-neutral-200">
                    {groupedEvents[day].map(event => {
                      const price = priceLabel(event.ticket_types, t)
                      return (
                        <Link key={event.id} to={`/events/${event.slug || event.id}`} className="group flex min-w-0 items-start gap-4 rounded-lg py-5 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2">
                          <EventArtwork key={event.cover_image_url || event.id} event={event} className="h-20 w-20 shrink-0 sm:h-28 sm:w-40" />
                          <div className="min-w-0 flex-1">
                            <p className="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-content-muted"><span className="inline-flex items-center gap-1.5"><Clock aria-hidden="true" className="h-4 w-4" />{formatEventTime(event.starts_at, event.timezone)}</span>{event.venue_name && <span className="inline-flex min-w-0 items-start gap-1.5"><MapPin aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" /><span className="min-w-0 break-words">{event.venue_name}</span></span>}</p>
                            <h4 className="mt-2 break-words text-base font-semibold text-neutral-950 group-hover:text-brand-800 sm:text-xl">{event.title}</h4>
                            {event.short_description && <p className="mt-1 line-clamp-2 text-sm text-content-muted">{event.short_description}</p>}
                            <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">{price && <span className="font-semibold text-neutral-900">{price}</span>}<span className="inline-flex min-h-8 items-center gap-1 font-medium text-brand-800">View event <ArrowRight aria-hidden="true" className="h-4 w-4" /></span></div>
                          </div>
                        </Link>
                      )
                    })}
                  </div>
                </section>
              ))}
            </div>
          ) : (
            <div className="rounded-xl border border-neutral-200 bg-white p-6 sm:p-8">
              <h3 className="text-xl font-semibold text-neutral-950">No upcoming events listed</h3>
              <p className="mt-2 text-content-muted">Check back for new dates, or start setting up your own event.</p>
            </div>
          )}
        </div>
      </section>

      <section aria-labelledby="categories-heading" className="border-y border-neutral-200 bg-white py-8 sm:py-12">
        <div className="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8">
          <h2 id="categories-heading" className="mb-5 font-display text-2xl font-bold text-neutral-950">Explore by Category</h2>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {categories.map(({ name, slug, icon: Icon }) => <Link key={slug} to={`/events?category=${slug}`} className="flex min-h-14 items-center gap-3 rounded-lg border border-neutral-200 px-4 py-3 text-sm font-medium text-neutral-800 hover:border-brand-600 hover:bg-brand-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2"><Icon aria-hidden="true" className="h-5 w-5 shrink-0 text-brand-800" /><span>{name}</span><ArrowRight aria-hidden="true" className="ml-auto h-4 w-4 shrink-0" /></Link>)}
          </div>
        </div>
      </section>

      <section className="py-10 sm:py-12">
        <div className="mx-auto flex max-w-6xl flex-col items-start gap-5 px-4 sm:flex-row sm:items-center sm:justify-between sm:px-6 lg:px-8">
          <div><h2 className="font-display text-2xl font-bold text-neutral-950">Planning an event?</h2><p className="mt-2 max-w-xl text-content-muted">Sell tickets, run the door from any phone and get paid after your event. See how it works and what it costs.</p></div>
          <Link to="/host" className="inline-flex min-h-11 shrink-0 items-center gap-2 rounded-lg bg-action px-5 py-3 font-semibold text-white hover:bg-action-hover focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2">Start Hosting <ArrowRight aria-hidden="true" className="h-4 w-4" /></Link>
        </div>
      </section>
      <Footer />
    </div>
  )
}
