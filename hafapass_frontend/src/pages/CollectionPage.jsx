import { useTranslation } from 'react-i18next'
import { useEffect, useState } from 'react'
import { Link, useParams, useSearchParams } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import apiClient from '../api/client'
import EventCard from '../components/EventCard'
import MarketplacePagination from '../components/MarketplacePagination'
import SEO from '../components/SEO'
import BuyerTitleBand from '../components/BuyerTitleBand'
import NotFound from '../components/NotFound'

export default function CollectionPage() {
  const { t } = useTranslation()
  const { slug } = useParams()
  const [searchParams, setSearchParams] = useSearchParams()
  const page = Math.max(Number(searchParams.get('page')) || 1, 1)
  const [data, setData] = useState(null)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    let active = true
    setData(null)
    apiClient.get(`/marketplace_collections/${slug}`, { params: { page } })
      .then(response => { if (active) setData(response.data) })
      .catch(error => { if (active) setData({ error: error.response?.status === 404 ? 'missing' : 'failed' }) })
    return () => { active = false }
  }, [page, slug, attempt])

  if (!data) return <div className="public-listing-min-height bg-stone-50"><BuyerTitleBand title={t('pass.buyer.collection')} description={t('pass.buyer.collectionDescription')} /><div role="status" aria-label={t('pass.buyer.loadingCollection')} className="flex min-h-48 items-center justify-center"><Loader2 aria-hidden="true" className="h-8 w-8 animate-spin text-brand-700" /></div></div>
  if (data.error === 'missing') return <NotFound kind="collection" />
  if (data.error) return <div className="public-listing-min-height bg-stone-50"><BuyerTitleBand title={t('pass.buyer.collection')} description={t('pass.buyer.collectionDescription')} /><div className="px-4 py-8 text-center"><p role="alert" className="text-neutral-700">{t('buyerDiscovery.collection.thisCollectionCouldnTLoadPleaseTry')}</p><button type="button" className="btn-primary mt-4" onClick={() => setAttempt(value => value + 1)}>{t('buyerDiscovery.collection.retry')}</button></div></div>

  return <div className="public-listing-min-height bg-stone-50">
    <SEO title={data.seo_title || data.title} description={data.seo_description || data.description} />
    <BuyerTitleBand title={data.title} description={data.description} />
    <div className="mx-auto max-w-6xl px-4 py-8 sm:px-6 lg:px-8">
    <div className="grid gap-6 sm:grid-cols-2 lg:grid-cols-3">{data.events.map(event => <EventCard key={event.id} event={event} />)}</div>
    {!data.events.length && <div className="mt-5 text-neutral-600"><p>{data.meta?.total_count > 0 ? t('buyerDiscovery.collections.emptyPage') : t('buyerDiscovery.collection.empty')}</p>{data.meta?.total_count > 0 && <button type="button" onClick={() => setSearchParams({})} className="ticket-link mt-3 mr-4 inline-flex min-h-11 items-center rounded-lg px-2 text-brand-800 underline">{t('buyerDiscovery.collections.firstPage')}</button>}<Link to="/events" className="ticket-link mt-3 inline-flex min-h-11 items-center rounded-lg px-2 text-brand-800 underline">{t('buyerDiscovery.collections.browseEvents')}</Link></div>}
    <MarketplacePagination meta={data.meta} page={page} onPage={next => setSearchParams(next > 1 ? { page: next } : {})} />
    </div>
  </div>
}
