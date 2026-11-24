import EventAlertsSignup from '../components/EventAlertsSignup'
import { useTranslation } from 'react-i18next'
import { Fragment, useState, useEffect, useMemo, useSyncExternalStore } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { ArrowRight, ChevronDown, Search, Ticket as TicketIcon } from 'lucide-react'
import apiClient from '../api/client'
import Footer from '../components/Footer'
import SEO from '../components/SEO'
import Ticket from '../components/Ticket'
import { HostingStub } from '../components/EmptyInventory'
import InstallAppHelp from '../components/InstallAppHelp'
import EventCard from '../components/EventCard'
import FeaturedPassStub from '../components/FeaturedPassStub'
import PerforatedStubStory from '../components/PerforatedStubStory'
import useContentLanguage from '../hooks/useContentLanguage'
import { GUAM_VILLAGES, EVENT_DATES } from '../utils/eventFilters'

const passStepsFor = t => [
  [t('pass.home.stepFindTitle'), t('pass.home.stepFindBody')],
  [t('pass.home.stepBuyTitle'), t('pass.home.stepBuyBody')],
  [t('pass.home.stepDoorTitle'), t('pass.home.stepDoorBody')],
]

function FindTicketLink() {
  const { t } = useTranslation()
  return <Link to="/orders/recover" className="ticket-link inline-flex min-h-12 items-center gap-2 rounded-lg text-sm font-semibold text-brand-800">{t('pass.home.findTicket')}<ArrowRight aria-hidden="true" className="h-4 w-4 shrink-0" /></Link>
}

const categoriesFor = t => [
  { name: t('buyer.Home.Nightlife'), slug: 'nightlife' },
  { name: t('buyer.Home.FoodDrink'), slug: 'dining' },
  { name: t('buyer.Home.MusicConcerts'), slug: 'concert' },
  { name: t('buyer.Home.Sports'), slug: 'sports' },
  { name: t('buyer.Home.FestivalsCulture'), slug: 'festival' },
  { name: t('buyer.Home.ClassesWorkshops'), slug: 'workshop' },
]

// The page's one entrance: the headline's words rise into place in CSS, done
// within a second. The full sentence stays in the heading for screen readers,
// and reduced motion shows it still.
function RiseHeadline({ text, className }) {
  const words = text.split(' ')
  return <h1 className={`hero-rise ${className}`}>{words.map((word, index) => <Fragment key={index}>
    <span className="hero-rise-word" style={{ '--word': index }}>{word}</span>{index < words.length - 1 ? ' ' : null}
  </Fragment>)}</h1>
}

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

// Wide screens put search beside the featured pass; narrower ones put it at
// the top of the listing, so the hero keeps the loading ticket's height.
const WIDE = '(min-width: 1024px)'
const wideQuery = () => (typeof window !== 'undefined' && window.matchMedia ? window.matchMedia(WIDE) : null)
function subscribeWide(callback) {
  const list = wideQuery()
  list?.addEventListener?.('change', callback)
  return () => list?.removeEventListener?.('change', callback)
}
const useWideHero = () => useSyncExternalStore(subscribeWide, () => Boolean(wideQuery()?.matches), () => false)

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
  const wide = useWideHero()
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
  const searchCard = <form role="search" onSubmit={browse} className="hero-search rounded-2xl bg-white p-5 text-content shadow-card sm:p-6">
    <label htmlFor="home-event-search" className="mb-2 block text-base font-medium">{t('buyer.Home.eventOrVenue')}</label>
    <div className="flex gap-3">
      <div className="relative min-w-0 flex-1"><Search aria-hidden="true" className="absolute left-3 top-1/2 h-5 w-5 -translate-y-1/2 text-content-muted" /><input id="home-event-search" name="search" type="search" enterKeyHint="search" value={search} onChange={e => setSearch(e.target.value)} placeholder={t('buyer.Home.searchEventsAndVenues')} className="input min-h-12 !pl-10 text-base border-neutral-500 hover:border-neutral-600" /></div>
      <button type="submit" className="btn-primary min-h-12 shrink-0 !px-5">{t('buyer.Home.search')}</button>
    </div>
    <button type="button" aria-expanded={moreFilters} aria-controls="home-filters" onClick={() => setMoreFilters(open => !open)}
      className="mt-3 inline-flex min-h-12 w-full items-center justify-between gap-2 rounded-xl border-2 border-neutral-500 px-4 text-base font-semibold text-neutral-900 sm:hidden">
      {t('pass.home.dateAndVillage')}<ChevronDown aria-hidden="true" className={`h-5 w-5 shrink-0 ${moreFilters ? 'rotate-180' : ''}`} />
    </button>
    <div id="home-filters" className={`${moreFilters ? 'grid' : 'hidden'} mt-3 grid-cols-1 gap-3 sm:mt-4 sm:grid sm:grid-cols-2`}>
      <div className="min-w-0"><label htmlFor="home-when" className="mb-2 block text-base font-medium">{t('pass.home.when')}</label>
        <select id="home-when" className="input min-h-12 !pl-3 text-base border-neutral-500 hover:border-neutral-600" value={date} onChange={e => setDate(e.target.value)}>{EVENT_DATES.map(([value,key]) => <option key={value} value={value}>{t(key)}</option>)}</select></div>
      <div className="min-w-0"><label htmlFor="home-where" className="mb-2 block text-base font-medium">{t('pass.home.where')}</label>
        <select id="home-where" className="input min-h-12 !pl-3 text-base border-neutral-500 hover:border-neutral-600" value={village} onChange={e => setVillage(e.target.value)}><option value="">{t('buyer.Events.allVillages')}</option>{GUAM_VILLAGES.map(item => <option key={item}>{item}</option>)}</select></div>
    </div>
    <div className="mt-3 flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
      <p className="text-sm text-content-muted">{t('pass.home.guamTime')}</p>
      <FindTicketLink />
    </div>
  </form>
  return (
    <div className="public-intros min-h-dvh bg-brand-950 text-content">
      <SEO />
      <section data-header-band="dark" className="bg-brand-950 pb-12 pt-6 text-white sm:pb-20 sm:pt-12 lg:pb-24 lg:pt-16">
        {/* Top-aligned, with the text column holding the loaded height in every
            state, so events arriving (or not) never shift the page. */}
        <div className="mx-auto grid max-w-6xl items-start gap-7 px-4 sm:gap-10 sm:px-6 lg:grid-cols-[minmax(0,6fr)_minmax(0,5fr)] lg:gap-16 lg:px-8">
          <div className="min-w-0 lg:min-h-[31rem]">
            <RiseHeadline text={t('pass.home.title')} className="max-w-lg font-display text-[2.5rem] font-bold leading-[1.06] tracking-tight sm:text-5xl lg:text-6xl" />
            <p className="mt-4 max-w-md text-lg leading-relaxed text-brand-100">{t('pass.home.lede')}</p>
            {discovery && wide && <div className="mt-6">{searchCard}</div>}
          </div>
          {/* Hosting is pitched once: in the hero stub while loading, then by the planning ticket. */}
          {discovery ? <FeaturedPassStub event={upcoming[0]} /> : <Ticket className="hero-ticket text-content" stub={loading ? <HostingStub /> : inventoryEmpty ? <div className="flex flex-col items-start gap-1 px-6 py-5 sm:px-8">
            <InstallAppHelp variant="action" />
            <FindTicketLink />
          </div> : <div className="px-6 py-3 sm:px-8"><FindTicketLink /></div>}>
            <div className={`home-ticket-content px-6 py-6 sm:px-8 sm:py-7 ${inventoryEmpty ? 'home-ticket-empty' : ''}`} aria-busy={loading}>
              {loading ? <div className="flex h-full flex-col items-start justify-center gap-3">
                <p role="status" className="text-content-muted">{t('buyer.Home.loadingUpcomingEvents')}</p>
                <Link to="/events" className="btn-secondary">{t('buyer.Home.browseEvents')}</Link>
              </div> : loadError ? <div role="alert">
                <h2 className="font-display text-2xl font-bold">{t('buyer.Home.eventsCouldntLoad')}</h2>
                <p className="mt-3 text-content-muted">{t('buyer.Home.pleaseTryAgainToSeeWhatsComingUp')}</p>
                <div className="mt-4 flex flex-wrap gap-3"><button type="button" onClick={() => setLoadAttempt(attempt => attempt + 1)} className="btn-primary">{t('buyer.Home.retryEvents')}</button><Link to="/events" className="btn-secondary">{t('buyer.Home.browseEvents')}</Link></div>
              </div> : inventoryEmpty ? <div className="flex h-full flex-col items-start justify-center">
                <TicketIcon aria-hidden="true" className="mb-4 h-8 w-8 text-brand-700" />
                <h2 className="max-w-sm font-display text-2xl font-bold leading-tight sm:text-3xl">{t('pass.home.firstEvents')}</h2>
                <p className="mt-3 max-w-sm leading-relaxed text-content-muted">{t('pass.home.checkBack')}</p>
              </div> : null}
            </div>
          </Ticket>}
        </div>
      </section>
      <div className="relative -mt-6 min-h-[24rem] rounded-t-[2rem] bg-surface pb-12 pt-7 sm:-mt-8 sm:rounded-t-[2.5rem] sm:pt-10">
        <div className="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8">
          {discovery ? <>
            {!wide && <div className="mb-8">{searchCard}</div>}
            <section aria-labelledby="upcoming-heading">
              <div className="mb-4 flex flex-wrap items-center justify-between gap-3"><h2 id="upcoming-heading" className="font-display text-2xl font-bold sm:text-3xl">{t('pass.home.comingUpOnGuam')}</h2><Link to="/events" className="ticket-link inline-flex min-h-12 items-center gap-2 rounded-lg text-base font-semibold text-brand-800">{t('buyer.Home.viewAllEvents')}<ArrowRight aria-hidden="true" className="h-4 w-4" /></Link></div>
              <ul aria-label={t('pass.home.quickFilters')} className="mb-5 flex flex-wrap gap-2">{quickFiltersFor(events, t).map(({ label, to }) => <li key={to}><Link to={to} className="ticket-chip inline-flex min-h-12 items-center rounded-full border border-neutral-300 bg-white px-5 text-base font-medium text-neutral-900">{label}</Link></li>)}</ul>
              <ul className="event-track" aria-label={t('pass.home.comingUpOnGuam')}>{upcoming.map(event => <li key={`${event.id}:${event.cover_image_url || ''}`} className="min-w-0"><EventCard event={event} /></li>)}</ul>
            </section>
            <section aria-labelledby="categories-heading" className="pt-9"><h2 id="categories-heading" className="mb-4 font-display text-xl font-bold">{t('buyer.Home.exploreByCategory')}</h2><div className="flex flex-wrap gap-2">{categoriesFor(t).map(({name,slug}) => <Link key={slug} to={`/events?category=${slug}`} className="ticket-chip inline-flex min-h-12 items-center rounded-full border border-neutral-300 bg-white px-5 text-base font-medium">{name}</Link>)}</div></section>
            <PerforatedStubStory event={upcoming[0]} />
          </> : null}
          {inventoryEmpty && <section aria-labelledby="pass-steps-heading">
            <h2 id="pass-steps-heading" className="mb-4 font-display text-xl font-bold sm:text-2xl">{t('pass.home.howItWorks')}</h2>
            <ol className="grid gap-3 sm:grid-cols-3">{passStepsFor(t).map(([title, body], index) => <li key={title} className="pass-step ticket-notch flex items-center gap-4 rounded-2xl bg-white px-6 py-5">
              <span aria-hidden="true" className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-brand-50 font-display text-sm font-bold text-brand-800">{index + 1}</span>
              <div className="min-w-0"><h3 className="font-display text-lg font-bold leading-snug">{title}</h3><p className="mt-1 text-sm leading-relaxed text-content-muted">{body}</p></div>
            </li>)}</ol>
          </section>}
          <EventAlertsSignup source="home" />
          {!loading && <section className="mt-9">
            <Ticket className="planning-ticket" topClassName="!bg-brand-950 text-white" stubClassName="!bg-brand-950 text-white" stub={<div className="px-6 py-5 sm:px-8"><Link to="/host" className="btn-secondary gap-2 !border-white !text-brand-950">{t('buyer.Home.startHosting2')}<ArrowRight aria-hidden="true" className="h-4 w-4" /></Link></div>}>
              <div className="px-6 py-6 sm:px-8"><h2 className="font-display text-2xl font-bold">{t('buyer.Home.planningAnEvent')}</h2><p className="mt-2 max-w-lg leading-relaxed text-brand-100">{t('buyer.Home.sellTicketsRunTheDoorFromAnyPhone')}</p></div>
            </Ticket>
          </section>}
        </div>
      </div>
      <Footer />
    </div>
  )
}
