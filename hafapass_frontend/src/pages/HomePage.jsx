import { useTranslation } from 'react-i18next'
import { useState, useEffect, useMemo } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { ArrowRight, Search, Ticket as TicketIcon } from 'lucide-react'
import apiClient from '../api/client'
import Footer from '../components/Footer'
import SEO from '../components/SEO'
import Ticket from '../components/Ticket'
import EventCard from '../components/EventCard'
import useContentLanguage from '../hooks/useContentLanguage'
import { GUAM_VILLAGES, EVENT_DATES } from '../utils/eventFilters'

const categoriesFor = t => [
  { name: t('buyer.Home.Nightlife'), slug: 'nightlife' },
  { name: t('buyer.Home.FoodDrink'), slug: 'dining' },
  { name: t('buyer.Home.MusicConcerts'), slug: 'concert' },
  { name: t('buyer.Home.Sports'), slug: 'sports' },
  { name: t('buyer.Home.FestivalsCulture'), slug: 'festival' },
  { name: t('buyer.Home.ClassesWorkshops'), slug: 'workshop' },
]

export default function HomePage() {
  const { t } = useTranslation()
  const contentLanguage = useContentLanguage()
  const navigate = useNavigate()
  const [events, setEvents] = useState([])
  const [search, setSearch] = useState('')
  const [date, setDate] = useState('upcoming')
  const [village, setVillage] = useState('')
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
  const browse = event => {
    event.preventDefault()
    const params = new URLSearchParams()
    if (search.trim()) params.set('search', search.trim())
    if (date !== 'upcoming') params.set('date', date)
    if (village) params.set('village', village)
    navigate(`/events${params.size ? `?${params}` : ''}`)
  }
  const hostingStub = <div className="flex flex-wrap items-center justify-between gap-x-3 px-6 py-3 sm:px-8">
    <span className="text-sm text-content-muted">{t('pass.home.hosting')}</span>
    <Link to="/host" className="ticket-link inline-flex min-h-11 items-center gap-2 rounded-lg text-sm font-semibold text-brand-800">{t('pass.home.sellTickets')}<ArrowRight aria-hidden="true" className="h-4 w-4" /></Link>
  </div>
  return (
    <div className="min-h-dvh bg-brand-950 text-content">
      <SEO />
      <section className="bg-brand-950 pb-16 pt-8 text-white sm:pb-20 sm:pt-12 lg:pb-28 lg:pt-20">
        <div className="mx-auto grid max-w-6xl items-center gap-7 px-4 sm:gap-10 sm:px-6 lg:grid-cols-[minmax(0,5fr)_minmax(0,6fr)] lg:gap-16 lg:px-8">
          <div>
            <h1 className="max-w-lg font-display text-[2.5rem] font-bold leading-[1.06] tracking-tight sm:text-5xl lg:text-6xl">{t('pass.home.title')}</h1>
            <p className="mt-4 max-w-md text-base leading-relaxed text-brand-100 sm:text-lg">{t('pass.home.lede')}</p>
          </div>
          <Ticket className="hero-ticket text-content" stub={hostingStub}>
            <div className="home-ticket-content px-6 py-6 sm:px-8 sm:py-7" aria-busy={loading}>
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
              </div> : <form role="search" onSubmit={browse}>
                <div className="grid grid-cols-2 gap-3">
                  <div className="min-w-0"><label htmlFor="home-when" className="mb-2 block text-sm font-medium">{t('pass.home.when')}</label>
                    <select id="home-when" className="input min-h-12 !px-3 text-base" value={date} onChange={e => setDate(e.target.value)}>{EVENT_DATES.map(([value,key]) => <option key={value} value={value}>{t(key)}</option>)}</select></div>
                  <div className="min-w-0"><label htmlFor="home-where" className="mb-2 block text-sm font-medium">{t('pass.home.where')}</label>
                    <select id="home-where" className="input min-h-12 !px-3 text-base" value={village} onChange={e => setVillage(e.target.value)}><option value="">{t('buyer.Events.allVillages')}</option>{GUAM_VILLAGES.map(item => <option key={item}>{item}</option>)}</select></div>
                </div>
                <label htmlFor="home-event-search" className="mb-2 mt-4 block text-sm font-medium">{t('buyer.Home.eventOrVenue')}</label>
                <div className="flex flex-col gap-3 sm:flex-row">
                  <div className="relative min-w-0 flex-1"><Search aria-hidden="true" className="absolute left-3 top-1/2 h-5 w-5 -translate-y-1/2 text-content-muted" /><input id="home-event-search" name="search" type="search" enterKeyHint="search" value={search} onChange={e => setSearch(e.target.value)} placeholder={t('buyer.Home.searchEventsAndVenues')} className="input min-h-12 !pl-10 text-base" /></div>
                  <button type="submit" className="btn-primary min-h-12 !px-5">{t('buyer.Home.search')}</button>
                </div>
                <p className="mt-3 text-xs text-content-muted">{t('pass.home.guamTime')}</p>
              </form>}
            </div>
          </Ticket>
        </div>
      </section>
      <div className="relative -mt-6 min-h-[32rem] rounded-t-[2rem] bg-stone-50 pb-12 pt-8 sm:-mt-8 sm:rounded-t-[2.5rem] sm:pt-12">
        <div className="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8">
          {inventoryEmpty ? <section aria-labelledby="coming-soon-heading" className="py-2 sm:py-4"><h2 id="coming-soon-heading" className="font-display text-2xl font-bold">{t('preInventory.title')}</h2><p className="mt-3 text-content-muted">{t('pass.home.noEvents')}</p></section> : !loading && !loadError ? <>
            <section aria-labelledby="upcoming-heading">
              <div className="mb-5 flex flex-wrap items-center justify-between gap-3"><h2 id="upcoming-heading" className="font-display text-2xl font-bold sm:text-3xl">{t('pass.home.comingUp')}</h2><Link to="/events" className="ticket-link inline-flex min-h-11 items-center gap-2 rounded-lg text-sm font-semibold text-brand-800">{t('buyer.Home.viewAllEvents')}<ArrowRight aria-hidden="true" className="h-4 w-4" /></Link></div>
              <ul className="event-track" aria-label={t('pass.home.comingUp')}>{upcoming.map(event => <li key={`${event.id}:${event.cover_image_url || ''}`} className="min-w-0"><EventCard event={event} /></li>)}</ul>
            </section>
            <section aria-labelledby="categories-heading" className="pt-9"><h2 id="categories-heading" className="mb-4 font-display text-xl font-bold">{t('buyer.Home.exploreByCategory')}</h2><div className="flex flex-wrap gap-2">{categoriesFor(t).map(({name,slug}) => <Link key={slug} to={`/events?category=${slug}`} className="ticket-chip inline-flex min-h-11 items-center rounded-full border border-stone-200 bg-white px-4 text-sm font-medium">{name}</Link>)}</div></section>
          </> : null}
          {!loading && <section className="mt-9">
            <Ticket className="planning-ticket" topClassName="!bg-brand-800 text-white" stubClassName="!bg-brand-800 text-white" stub={<div className="px-6 py-5 sm:px-8"><Link to="/host" className="btn-primary gap-2">{t('buyer.Home.startHosting2')}<ArrowRight aria-hidden="true" className="h-4 w-4" /></Link></div>}>
              <div className="px-6 py-6 sm:px-8"><h2 className="font-display text-2xl font-bold">{t('buyer.Home.planningAnEvent')}</h2><p className="mt-2 max-w-lg leading-relaxed text-brand-100">{t('buyer.Home.sellTicketsRunTheDoorFromAnyPhone')}</p></div>
            </Ticket>
          </section>}
        </div>
      </div>
      <Footer />
    </div>
  )
}
