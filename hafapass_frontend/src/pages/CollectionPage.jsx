import { useTranslation } from 'react-i18next'
import { useEffect, useState } from 'react'
import { Link, useParams, useSearchParams } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import apiClient from '../api/client'
import EventCard from '../components/EventCard'
import MarketplacePagination from '../components/MarketplacePagination'
import SEO from '../components/SEO'
import NotFound from '../components/NotFound'

export default function CollectionPage() {
  const { t } = useTranslation()
  const { slug } = useParams()
  const [searchParams, setSearchParams] = useSearchParams()
  const page = Math.max(Number(searchParams.get('page')) || 1, 1)
  const [data, setData] = useState(null)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    setData(null)
    apiClient.get(`/marketplace_collections/${slug}`, { params: { page } })
      .then(response => setData(response.data))
      .catch(error => setData({ error: error.response?.status === 404 ? 'missing' : 'failed' }))
  }, [page, slug, attempt])

  if (!data) return <Loader2 className="mx-auto mt-24 h-8 w-8 animate-spin text-brand-500" />
  if (data.error === 'missing') return <NotFound kind="collection" />
  if (data.error) return <div className="py-24 text-center"><p role="alert" className="text-neutral-700">{t('buyerDiscovery.collection.thisCollectionCouldnTLoadPleaseTry')}</p><button type="button" className="btn-primary mt-4" onClick={() => setAttempt(value => value + 1)}>{t('buyerDiscovery.collection.retry')}</button></div>

  return <div className="mx-auto max-w-6xl px-4 py-10">
    <SEO title={data.seo_title || data.title} description={data.seo_description || data.description} />
    <h1 className="font-display text-4xl font-bold">{data.title}</h1>
    <p className="mt-2 max-w-2xl text-neutral-500">{data.description}</p>
    <div className="mt-8 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">{data.events.map(event => <EventCard key={event.id} event={event} />)}</div>
    {!data.events.length && <div className="mt-5 text-neutral-600"><p>{t('buyerDiscovery.collection.empty')}</p><Link to="/events" className="mt-3 inline-flex text-brand-700 underline">{t('buyerDiscovery.collections.browseEvents')}</Link></div>}
    <MarketplacePagination meta={data.meta} page={page} onPage={next => setSearchParams(next > 1 ? { page: next } : {})} />
  </div>
}
