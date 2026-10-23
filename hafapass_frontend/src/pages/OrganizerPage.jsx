import { useTranslation } from 'react-i18next'
import { useEffect, useState } from 'react'
import { Link, useParams, useSearchParams } from 'react-router-dom'
import { BadgeCheck, Loader2 } from 'lucide-react'
import apiClient from '../api/client'
import EventCard from '../components/EventCard'
import MarketplacePagination from '../components/MarketplacePagination'
import SEO from '../components/SEO'
import NotFound from '../components/NotFound'
import { approvedImageUrl } from '../utils/eventPageDesign'

export default function OrganizerPage() {
  const { t } = useTranslation()
  const { slug } = useParams()
  const [searchParams, setSearchParams] = useSearchParams()
  const page = Math.max(Number(searchParams.get('page')) || 1, 1)
  const [data, setData] = useState(null)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    setData(null)
    apiClient.get(`/organizers/${slug}`, { params: { page } }).then(response => setData(response.data)).catch(error => setData({ error: error.response?.status === 404 ? 'missing' : 'failed' }))
  }, [page, slug, attempt])

  if (!data) return <Loader2 className="mx-auto mt-24 h-8 w-8 animate-spin text-brand-500" />
  if (data.error === 'missing') return <NotFound kind="organizer" />
  if (data.error) return <div className="py-24 text-center"><p role="alert" className="text-neutral-700">{t('buyerDiscovery.organizer.thisOrganizerCouldnTLoadPleaseTry')}</p><button type="button" className="btn-primary mt-4" onClick={() => setAttempt(value => value + 1)}>{t('buyerDiscovery.organizer.retry')}</button></div>

  return <div className="mx-auto max-w-6xl px-4 py-10"><SEO title={t('buyerDiscovery.organizer.eventTitle', { name: data.name })} description={data.description || t('buyerDiscovery.organizer.eventsFromOnGuam', { name: data.name })} />
    <div className="flex flex-col gap-6 rounded-3xl border border-neutral-200 bg-white p-8 sm:flex-row sm:items-center">{approvedImageUrl(data.logo_url, data.image_asset_host) && <img src={data.logo_url} alt="" className="h-24 w-24 rounded-2xl object-cover" />}<div><div className="flex items-center gap-2"><h1 className="font-display text-4xl font-bold">{data.name}</h1>{data.verified && <BadgeCheck className="text-brand-500" aria-label={t('buyerDiscovery.organizer.verifiedOrganizer')} />}</div><p className="mt-2 text-neutral-500">{t('buyerDiscovery.organizer.completedEvents', { count: data.completed_events })} · {t('buyerDiscovery.organizer.ticketsIssued', { count: data.tickets_issued })} · {t('buyerDiscovery.organizer.followers', { count: data.followers })}</p>{data.ambros_partner && <span className="mt-3 inline-flex rounded-full bg-brand-50 px-3 py-1 text-xs font-semibold text-brand-700">{t('buyerDiscovery.organizer.ambrosPartner')}</span>}{data.description && <p className="mt-4 max-w-2xl text-neutral-600">{data.description}</p>}</div></div>
    <h2 className="mt-10 text-2xl font-bold">{t('buyerDiscovery.organizer.upcomingEvents')}</h2><div className="mt-5 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">{data.events.map(event => <EventCard key={event.id} event={event} />)}</div>
    {!data.events.length && <div className="mt-5 text-neutral-600"><p>{data.meta?.total_count > 0 ? t('buyerDiscovery.collections.emptyPage') : t('buyerDiscovery.organizer.empty')}</p>{data.meta?.total_count > 0 && <button type="button" onClick={() => setSearchParams({})} className="mt-3 mr-4 text-brand-700 underline">{t('buyerDiscovery.collections.firstPage')}</button>}<Link to="/events" className="mt-3 inline-flex text-brand-700 underline">{t('buyerDiscovery.collections.browseEvents')}</Link></div>}
    <MarketplacePagination meta={data.meta} page={page} onPage={next => setSearchParams(next > 1 ? { page: next } : {})} />
  </div>
}
