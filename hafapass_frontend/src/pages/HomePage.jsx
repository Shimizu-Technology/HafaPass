import { useTranslation } from 'react-i18next'
import { useState, useEffect, useMemo, useSyncExternalStore } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { ArrowRight, ChevronDown, Search } from 'lucide-react'
import apiClient from '../api/client'
import Footer from '../components/Footer'
import SEO from '../components/SEO'
import Ticket from '../components/Ticket'
import HomeHero from '../components/HomeHero'
import EventCard from '../components/EventCard'
import EventStubDeck from '../components/EventStubDeck'
import PerforatedStubStory from '../components/PerforatedStubStory'
import ChipRow, { EventTrack } from '../components/ui/ChipRow'
import useContentLanguage from '../hooks/useContentLanguage'
import { GUAM_VILLAGES, EVENT_DATES } from '../utils/eventFilters'

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

// One-tap shortcuts into Events: two common times, then the villages that
// have upcoming events, busiest first.
function quickFiltersFor(events, t) {
  const counts = new Map()
  events.forEach(event => { if (event.venue_city) counts.set(event.venue_city, (counts.get(event.venue_city) || 0) + 1) })
  const villages = [...counts].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, 4)
    .map(([village]) => ({ label: village, to: `/events?village=${encodeURIComponent(village)}` }))
  return [
    { label: t('buyer.Events.tonight'), to: '/events?date=tonight' },
    { label: t('buyer.Events.thisWeekend'), to: '/events?date=weekend' },
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
  // Phones open the date and village selects on request; chips cover the common picks.
  const [moreFilters, setMoreFilters] = useState(false)
  const wide = useMediaMatch('(min-width: 1024px)')
  const smUp = useMediaMatch('(min-width: 640px)')
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

  // One browsing section: upcoming featured events lead, then date order.
  const upcoming = useMemo(() => [...events].sort((a, b) => {
    const featured = event => Boolean(event.is_featured && new Date(event.starts_at) > new Date())
    return Number(featured(b)) - Number(featured(a)) || new Date(a.starts_at) - new Date(b.starts_at)
  }).slice(0, 8), [events])

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

  const searchCard = (
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
      <button
        type="button"
        aria-expanded={moreFilters}
        aria-controls="home-filters"
        onClick={() => setMoreFilters(open => !open)}
        className="mt-3 inline-flex min-h-12 w-full items-center justify-between gap-2 rounded-xl border-2 border-neutral-500 px-4 text-base font-semibold text-neutral-900 sm:hidden"
      >
        {t('pass.home.dateAndVillage')}
        <ChevronDown aria-hidden="true" className={`h-5 w-5 shrink-0 ${moreFilters ? 'rotate-180' : ''}`} />
      </button>
      <div id="home-filters" className={`${moreFilters ? 'grid' : 'hidden'} mt-3 grid-cols-1 gap-3 sm:mt-4 sm:grid sm:grid-cols-2`}>
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
      <HomeHero
        discovery={discovery}
        wide={wide}
        loading={loading}
        loadError={loadError}
        inventoryEmpty={inventoryEmpty}
        featuredEvent={upcoming[0]}
        searchCard={searchCard}
        findTicketLink={<FindTicketLink />}
        onRetry={() => setLoadAttempt(attempt => attempt + 1)}
      />
      <div className="relative -mt-6 min-h-[24rem] rounded-t-[2rem] bg-surface pb-12 pt-7 sm:-mt-8 sm:rounded-t-[2.5rem] sm:pt-10">
        <div className="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8">
          {discovery ? (
            <>
              {!wide && <div className="mb-8">{searchCard}</div>}
              <section aria-labelledby="upcoming-heading">
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
                <ChipRow as="ul" ariaLabel={t('pass.home.quickFilters')} className="mb-5">
                  {quickFiltersFor(events, t).map(({ label, to }) => (
                    <li key={to}>
                      <Link to={to} className="chip">{label}</Link>
                    </li>
                  ))}
                </ChipRow>
                <EventTrack ariaLabel={t('pass.home.comingUpOnGuam')}>
                  {upcoming.map(event => (
                    <li key={`${event.id}:${event.cover_image_url || ''}`} className="min-w-0">
                      <EventCard event={event} />
                    </li>
                  ))}
                </EventTrack>
              </section>
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
              <EventStubDeck events={upcoming} />
              <PerforatedStubStory event={upcoming[0]} />
            </>
          ) : null}
          {inventoryEmpty && (
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
          )}
          {!loading && (
            <section className="mt-9 sm:mt-12">
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
      <Footer />
    </div>
  )
}
