import { useEffect, useState } from 'react'
import { useParams, useSearchParams } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import apiClient from '../api/client'
import EventCard from '../components/EventCard'
import MarketplacePagination from '../components/MarketplacePagination'
import SEO from '../components/SEO'

export default function CollectionPage() {
  const { slug } = useParams()
  const [searchParams, setSearchParams] = useSearchParams()
  const page = Math.max(Number(searchParams.get('page')) || 1, 1)
  const [data, setData] = useState(null)

  useEffect(() => {
    setData(null)
    apiClient.get(`/marketplace_collections/${slug}`, { params: { page } })
      .then(response => setData(response.data))
      .catch(() => setData({ error: true }))
  }, [page, slug])

  if (!data) return <Loader2 className="mx-auto mt-24 h-8 w-8 animate-spin text-brand-500" />
  if (data.error) return <p className="py-24 text-center text-neutral-500">Collection not found.</p>

  return <div className="mx-auto max-w-6xl px-4 py-10">
    <SEO title={data.seo_title || data.title} description={data.seo_description || data.description} />
    <h1 className="font-display text-4xl font-bold">{data.title}</h1>
    <p className="mt-2 max-w-2xl text-neutral-500">{data.description}</p>
    <div className="mt-8 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">{data.events.map(event => <EventCard key={event.id} event={event} />)}</div>
    <MarketplacePagination meta={data.meta} page={page} onPage={next => setSearchParams(next > 1 ? { page: next } : {})} />
  </div>
}
