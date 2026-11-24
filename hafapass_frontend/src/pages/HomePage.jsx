import { useTranslation } from 'react-i18next'
import { useState, useEffect, useMemo, useSyncExternalStore } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { ArrowRight, Search, Ticket as TicketIcon } from 'lucide-react'
import apiClient from '../api/client'
import Footer from '../components/Footer'
import SEO from '../components/SEO'
import Ticket from '../components/Ticket'
import HomeHero from '../components/HomeHero'
import EventCard from '../components/EventCard'
import InstallAppHelp from '../components/InstallAppHelp'
import PerforatedStubStory from '../components/PerforatedStubStory'
import ChipRow, { EventTrack } from '../components/ui/ChipRow'
import useContentLanguage from '../hooks/useContentLanguage'
import { GUAM_VILLAGES, EVENT_DATES } from '../utils/eventFilters'
import { DEFAULT_EVENT_TIME_ZONE } from '../utils/eventTime'

const passStepsFor = t => [
  [t('pass.home.stepFindTitle'), t('pass.home.stepFindBody')],
  [t('pass.home.stepBuyTitle'), t('pass.home.stepBuyBody')],
  [t('pass.home.stepDoorTitle'), t('pass.home.stepDoorBody')],
]

function FindTicketLink() {
  const { t } = useTranslation()
  return (
    <Link to="/orders/recover" className="ticket-link inline-flex min-h-12 items-center gap-2 rounded-lg text-sm font-semibold text-brand-800">
      {t('pass.home.findTicket')}
      <ArrowRight aria-hidden="true" className="h-4 w-4 shrink-0" />
    </Link>
  )
}

const categoriesFor = t => [
  { name: t('buyer.Home.Nightlife'), slug: 'nightlife' },
  { name: t('buyer.Home.FoodDrink'), slug: 'dining' },
  { name: t('buyer.Home.MusicConcerts'), slug: 'concert' },
  { name: t('buyer.Home.Sports'), slug: 'sports' },
  { name: t('buyer.Home.FestivalsCulture'), slug: 'festival' },
  { name: t('buyer.Home.ClassesWorkshops'), slug: 'workshop' },
]

function guamDateParts(value) {
  const date = value instanceof Date ? value : new Date(value)
  if (Number.isNaN(date.valueOf())) return null
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: DEFAULT_EVENT_TIME_ZONE,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    weekday: 'short',
  }).formatToParts(date)
  const get = type => parts.find(part => part.type === type)?.value || ''
  return {
    ymd: `${get('year')}-${get('month')}-${get('day')}`,
    weekday: get('weekday'),
  }
}

function matchesQuickFilter(event, filter) {
  if (!filter || filter.kind === 'all') return true
  if (filter.kind === 'village') {
    return String(event.venue_city || '').toLowerCase() === filter.value.toLowerCase()
  }
  if (!event.starts_at) return false
  const eventParts = guamDateParts(event.starts_at)
  const nowParts = guamDateParts(new Date())
  if (!eventParts || !nowParts) return false
  if (filter.kind === 'tonight') {
    return eventParts.ymd === nowParts.ymd
  }
  if (filter.kind === 'weekend') {
    const startMs = Date.parse(event.starts_at)
    const nowMs = Date.now()
    const withinSevenDays = startMs >= nowMs - 86400_000 && startMs <= nowMs + 7 * 86400_000
    return withinSevenDays && ['Fri', 'Sat', 'Sun'].includes(eventParts.weekday)
  }
  return true
}

// One-tap quick filters that filter the "Coming up on Guam" carousel in place:
// All, Tonight, This weekend, then the busiest villages with upcoming events.
function quickFiltersFor(events, t) {
  const counts = new Map()
  events.forEach(event => {
    if (event.venue_city) counts.set(event.venue_city, (counts.get(event.venue_city) || 0) + 1)
  })
  const villages = [...counts]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, 4)
    .map(([village]) => ({ id: `village:${village}`, kind: 'village', value: village, label: village }))
  return [
    { id: 'all', kind: 'all', value: 'all', label: t('buyer.Events.allUpcoming') },
    { id: 'tonight', kind: 'tonight', value: 'tonight', label: t('buyer.Events.tonight') },
    { id: 'weekend', kind: 'weekend', value: 'weekend', label: t('buyer.Events.thisWeekend') },
    ...villages,
  ]
}

function useMediaMatch(query) {
  const getList = () => (typeof window !== 'undefined' && window.matchMedia ? window.matchMedia(query) : null)
  return useSyncExternalStore(
    callback => {
      const list = getList()
      list?.addEventListener?.('change', callback)
      return () => list?.removeEventListener?.('change', callback)
    },
    () => Boolean(getList()?.matches),
    () => false,
  )
}

export default function HomePage() {
  const { t } = useTranslation()
  const contentLanguage = useContentLanguage()
  const navigate = useNavigate()
  const [events, setEvents] = useState([])
  const [search, setSearch] = useState('')
  const [date, setDate] = useState('upcoming')
  const [village, setVillage] = useState('')
  const [activeFilterId, setActiveFilterId] = useState('all')
  const smUp = useMediaMatch('(min-width: 640px)')
  const lgUp = useMediaMatch('(min-width: 1024px)')
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

  // Featured upcoming events lead, then chronological order.
  const upcoming = useMemo(() => [...events].sort((a, b) => {
    const featured = event => Boolean(event.is_featured && new Date(event.starts_at) > new Date())
    return Number(featured(b)) - Number(featured(a)) || new Date(a.starts_at) - new Date(b.starts_at)
  }).slice(0, 8), [events])

  const quickFilters = useMemo(() => quickFiltersFor(events, t), [events, t])
  const activeFilter = useMemo(
    () => quickFilters.find(item => item.id === activeFilterId) || quickFilters[0],
    [quickFilters, activeFilterId],
  )
  const filteredUpcoming = useMemo(
    () => upcoming.filter(event => matchesQuickFilter(event, activeFilter)),
    [upcoming, activeFilter],
  )

  const inventoryEmpty = !loading && !loadError && events.length === 0
  const discovery = !loading && !loadError && !inventoryEmpty

  const browse = event => {
    event.preventDefault()
    const params = new URLSearchParams()
    if (search.trim()) params.set('search', search.trim())
    if (date !== 'upcoming') params.set('date', date)
    if (village) params.set('village', village)
    navigate(`/events${params.size ? `?${params}` : ''}`)
  }

  const searchForm = (
    <form role="search" onSubmit={browse} className="hero-search rounded-2xl bg-white p-5 text-content shadow-card sm:p-6">
      <label htmlFor="home-event-search" className="mb-2 block text-base font-medium">{t('buyer.Home.eventOrVenue')}</label>
      <div className="flex gap-3">
        <div className="relative min-w-0 flex-1">
          <Search aria-hidden="true" className="absolute left-3 top-1/2 h-5 w-5 -translate-y-1/2 text-content-muted" />
          <input
            id="home-event-search"
            name="search"
            type="search"
            enterKeyHint="search"
            value={search}
            onChange={e => setSearch(e.target.value)}
            placeholder={smUp ? t('buyer.Home.searchEventsAndVenues') : t('nav.searchEvents')}
            className="input min-h-12 !pl-10 text-base border-neutral-500 hover:border-neutral-600"
          />
        </div>
        <button type="submit" className="btn-primary min-h-12 shrink-0 !px-5">{t('buyer.Home.search')}</button>
      </div>
      <div id="home-filters" className="mt-4 hidden grid-cols-1 gap-3 sm:grid sm:grid-cols-2">
        <div className="min-w-0">
          <label htmlFor="home-when" className="mb-2 block text-base font-medium">{t('pass.home.when')}</label>
          <select id="home-when" className="input min-h-12 !pl-3 text-base border-neutral-500 hover:border-neutral-600" value={date} onChange={e => setDate(e.target.value)}>
            {EVENT_DATES.map(([value, key]) => <option key={value} value={value}>{t(key)}</option>)}
          </select>
        </div>
        <div className="min-w-0">
          <label htmlFor="home-where" className="mb-2 block text-base font-medium">{t('pass.home.where')}</label>
          <select id="home-where" className="input min-h-12 !pl-3 text-base border-neutral-500 hover:border-neutral-600" value={village} onChange={e => setVillage(e.target.value)}>
            <option value="">{t('buyer.Events.allVillages')}</option>
            {GUAM_VILLAGES.map(item => <option key={item}>{item}</option>)}
          </select>
        </div>
      </div>
      <div className="mt-3 flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
        <p className="text-sm text-content-muted">{t('pass.home.guamTime')}</p>
        <FindTicketLink />
      </div>
    </form>
  )

  return (
    <div className="public-intros min-h-dvh bg-brand-950 text-content">
      <SEO />
      {/* 1. Hero: headline, subline, desktop search at lg+, and Deck (HåfaPass default pass + featured events). */}
      <HomeHero
        events={discovery ? upcoming.filter(event => new Date(event.starts_at) > new Date()) : []}
        loading={loading}
        searchCard={discovery && lgUp ? searchForm : null}
      />

      <div className="relative -mt-6 min-h-[24rem] rounded-t-[2rem] bg-surface pb-12 pt-7 sm:-mt-8 sm:rounded-t-[2.5rem] sm:pt-10">
        <div className="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8">
          {loading && (
            <div role="status" className="rounded-2xl border border-neutral-200 bg-white px-6 py-6 text-content-muted shadow-card">
              {t('buyer.Home.loadingUpcomingEvents')}
            </div>
          )}

          {loadError && (
            <div role="alert" className="rounded-2xl border border-neutral-200 bg-white p-6 shadow-card sm:p-8">
              <h2 className="font-display text-2xl font-bold text-neutral-950">{t('buyer.Home.eventsCouldntLoad')}</h2>
              <p className="mt-2 text-content-muted">{t('buyer.Home.pleaseTryAgainToSeeWhatsComingUp')}</p>
              <div className="mt-5 flex flex-wrap items-center gap-3">
                <button type="button" onClick={() => setLoadAttempt(attempt => attempt + 1)} className="btn-primary">
                  {t('buyer.Home.retryEvents')}
                </button>
                <FindTicketLink />
              </div>
            </div>
          )}

          {discovery && (
            <>
              {/* 2. Find: search (below lg) + one-line ChipRow quick filters. */}
              <section aria-label={t('buyer.Home.eventOrVenue')}>
                {!lgUp && searchForm}

                <ChipRow role="group" ariaLabel={t('pass.home.quickFilters')} className={lgUp ? '' : 'mt-4'}>
                  {quickFilters.map(item => {
                    const active = item.id === activeFilter.id
                    return (
                      <button
                        key={item.id}
                        type="button"
                        aria-pressed={active}
                        onClick={() => setActiveFilterId(prev => (prev === item.id && item.id !== 'all' ? 'all' : item.id))}
                        className="chip"
                      >
                        {item.label}
                      </button>
                    )
                  })}
                </ChipRow>
              </section>

              {/* 3. One "Coming up on Guam" event carousel filtered in place. */}
              <section aria-labelledby="upcoming-heading" className="pt-9 sm:pt-12">
                <div className="mb-4 flex items-baseline justify-between gap-3">
                  <h2 id="upcoming-heading" className="font-display text-2xl font-bold text-neutral-950 sm:text-3xl">
                    {t('pass.home.comingUpOnGuam')}
                  </h2>
                  <Link
                    to="/events"
                    className="ticket-link inline-flex min-h-11 shrink-0 items-center gap-1.5 whitespace-nowrap rounded-lg text-sm font-semibold text-brand-800"
                  >
                    {t('buyer.Home.seeAll')}
                    <ArrowRight aria-hidden="true" className="h-4 w-4" />
                  </Link>
                </div>
                {filteredUpcoming.length > 0 ? (
                  <EventTrack ariaLabel={t('pass.home.comingUpOnGuam')}>
                    {filteredUpcoming.map(event => (
                      <li key={`${event.id}:${event.cover_image_url || ''}`} className="min-w-0">
                        <EventCard event={event} />
                      </li>
                    ))}
                  </EventTrack>
                ) : (
                  <div
                    role="status"
                    className="flex flex-col items-start justify-between gap-4 rounded-2xl border border-neutral-200 bg-white p-6 shadow-card sm:flex-row sm:items-center"
                  >
                    <div>
                      <p className="font-display text-lg font-bold text-neutral-950">
                        {t('events.noMatchingEvents')}
                      </p>
                      <p className="mt-1 text-sm text-content-muted">
                        {t('buyer.Events.tryAdjustingYourSearchOrFiltersToFind')}
                      </p>
                    </div>
                    <button
                      type="button"
                      onClick={() => setActiveFilterId('all')}
                      className="btn-secondary shrink-0"
                    >
                      {t('buyer.Events.allUpcoming')}
                    </button>
                  </div>
                )}
              </section>

              {/* 4. Explore by category (single-line ChipRow). */}
              <section aria-labelledby="categories-heading" className="pt-9 sm:pt-12">
                <h2 id="categories-heading" className="mb-4 font-display text-2xl font-bold text-neutral-950 sm:text-3xl">
                  {t('buyer.Home.exploreByCategory')}
                </h2>
                <ChipRow role="group" ariaLabel={t('buyer.Home.exploreByCategory')}>
                  {categoriesFor(t).map(({ name, slug }) => (
                    <Link key={slug} to={`/events?category=${slug}`} className="chip">{name}</Link>
                  ))}
                </ChipRow>
              </section>

              {/* 5. "From your phone to the door" QR scan story (neutral example pass). */}
              <PerforatedStubStory />
            </>
          )}

          {inventoryEmpty && (
            <>
              <section aria-labelledby="empty-inventory-heading" className="mb-9 rounded-2xl border border-neutral-200 bg-white p-6 shadow-card sm:mb-12 sm:p-8">
                <TicketIcon aria-hidden="true" className="mb-3 h-7 w-7 text-brand-700" />
                <h2 id="empty-inventory-heading" className="max-w-md font-display text-2xl font-bold leading-tight text-neutral-950 sm:text-3xl">
                  {t('pass.home.firstEvents')}
                </h2>
                <p className="mt-2 max-w-md leading-relaxed text-content-muted">{t('pass.home.checkBack')}</p>
                <div className="mt-4 flex flex-wrap items-center gap-x-5 gap-y-2">
                  <InstallAppHelp variant="action" />
                  <FindTicketLink />
                </div>
              </section>
              <section aria-labelledby="pass-steps-heading">
                <h2 id="pass-steps-heading" className="mb-4 font-display text-2xl font-bold text-neutral-950 sm:text-3xl">
                  {t('pass.home.howItWorks')}
                </h2>
                <ol className="grid gap-3 sm:grid-cols-3">
                  {passStepsFor(t).map(([title, body], index) => (
                    <li key={title} className="pass-step ticket-notch flex items-center gap-4 rounded-2xl bg-white px-6 py-5">
                      <span aria-hidden="true" className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-brand-50 font-display text-sm font-bold text-brand-800">{index + 1}</span>
                      <div className="min-w-0">
                        <h3 className="font-display text-lg font-bold leading-snug">{title}</h3>
                        <p className="mt-1 text-sm leading-relaxed text-content-muted">{body}</p>
                      </div>
                    </li>
                  ))}
                </ol>
              </section>
            </>
          )}

          {/* 6. "Planning an event?" host CTA. */}
          {!loading && (
            <section className={discovery ? 'mt-4 sm:mt-12' : 'mt-9 sm:mt-12'}>
              <Ticket
                className="planning-ticket"
                topClassName="!bg-brand-950 text-white"
                stubClassName="!bg-brand-950 text-white"
                stub={
                  <div className="px-6 py-5 sm:px-8">
                    <Link to="/host" className="btn-secondary gap-2 !border-white !text-brand-950">
                      {t('buyer.Home.startHosting2')}
                      <ArrowRight aria-hidden="true" className="h-4 w-4" />
                    </Link>
                  </div>
                }
              >
                <div className="px-6 py-6 sm:px-8">
                  <h2 className="font-display text-2xl font-bold sm:text-3xl">{t('buyer.Home.planningAnEvent')}</h2>
                  <p className="mt-2 max-w-lg leading-relaxed text-brand-100">{t('buyer.Home.sellTicketsRunTheDoorFromAnyPhone')}</p>
                </div>
              </Ticket>
            </section>
          )}
        </div>
      </div>

      {/* 7. Footer. */}
      <Footer />
    </div>
  )
}
