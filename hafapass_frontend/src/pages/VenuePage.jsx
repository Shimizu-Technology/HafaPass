import { useTranslation } from 'react-i18next'
import { useEffect, useRef, useState } from 'react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { BadgeCheck, Loader2, MapPin } from 'lucide-react'
import apiClient from '../api/client'
import EventCard from '../components/EventCard'
import MarketplacePagination from '../components/MarketplacePagination'
import SEO from '../components/SEO'
import NotFound from '../components/NotFound'

export default function VenuePage() {
  const { t } = useTranslation()
  const { slug } = useParams()
  const [searchParams, setSearchParams] = useSearchParams()
  const page = Math.max(Number(searchParams.get('page')) || 1, 1)
  const navigate = useNavigate()
  const [data, setData] = useState(null)
  const [attempt, setAttempt] = useState(0)
  // Set when an old venue link resolved, so the swap to the current link
  // reuses the loaded venue instead of fetching it again.
  const resolved = useRef(null)

  useEffect(() => {
    if (resolved.current === slug) {
      resolved.current = null
      return undefined
    }
    let active = true
    setData(null)
    apiClient.get(`/venues/${slug}`, { params: { page } })
      .then(response => {
        if (!active) return
        const venue = response.data
        if (venue.redirected_from === slug && venue.slug && venue.slug !== slug) {
          resolved.current = venue.slug
          navigate(`/venues/${encodeURIComponent(venue.slug)}${window.location.search}`, { replace: true })
        }
        setData(venue)
      })
      .catch(error => { if (active) setData({ error: error.response?.status === 404 ? 'missing' : 'failed' }) })
    return () => { active = false }
  }, [page, slug, attempt, navigate])

  if (!data) return <Loader2 className="mx-auto mt-24 h-8 w-8 animate-spin text-brand-500" />
  if (data.error === 'missing') return <NotFound kind="venue" />
  if (data.error) return <div className="py-24 text-center"><p role="alert" className="text-neutral-700">{t('buyerDiscovery.venue.thisVenueCouldnTLoadPleaseTry')}</p><button type="button" className="btn-primary mt-4" onClick={() => setAttempt(value => value + 1)}>{t('buyerDiscovery.venue.retry')}</button></div>

  return <div className="mx-auto max-w-6xl px-4 py-10"><SEO title={t('buyerDiscovery.venue.eventTitle', { name: data.name })} description={data.description || t('buyerDiscovery.venue.upcomingEventsAtGuam', { name: data.name, village: data.village })} />
    <div className="rounded-3xl bg-neutral-950 p-8 text-white"><div className="flex items-center gap-2"><h1 className="font-display text-4xl font-bold">{data.name}</h1>{data.verified && <BadgeCheck className="text-brand-400" aria-label={t('buyerDiscovery.venue.verifiedVenue')} />}</div><p className="mt-3 flex items-center gap-2 text-neutral-300"><MapPin className="h-4 w-4" />{data.address}, {data.village}</p>{data.description && <p className="mt-5 max-w-2xl text-neutral-300">{data.description}</p>}{data.accessibility_notes && <p className="mt-4 rounded-xl bg-white/10 p-4 text-sm"><strong>{t('buyerDiscovery.venue.accessibility')}</strong> {data.accessibility_notes}</p>}</div>
    <h2 className="mt-10 text-2xl font-bold">{t('buyerDiscovery.venue.upcomingEvents')}</h2><div className="mt-5 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">{data.events.map(event => <EventCard key={event.id} event={event} />)}</div>
    {!data.events.length && <div className="mt-5 text-neutral-600"><p>{data.meta?.total_count > 0 ? t('buyerDiscovery.collections.emptyPage') : t('buyerDiscovery.venue.empty')}</p>{data.meta?.total_count > 0 && <button type="button" onClick={() => setSearchParams({})} className="mt-3 mr-4 text-brand-700 underline">{t('buyerDiscovery.collections.firstPage')}</button>}<Link to="/events" className="mt-3 inline-flex text-brand-700 underline">{t('buyerDiscovery.collections.browseEvents')}</Link></div>}
    <MarketplacePagination meta={data.meta} page={page} onPage={next => setSearchParams(next > 1 ? { page: next } : {})} />
  </div>
}
