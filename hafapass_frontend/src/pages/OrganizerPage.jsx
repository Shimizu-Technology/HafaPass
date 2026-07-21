import { useEffect, useState } from 'react'
import { useParams, useSearchParams } from 'react-router-dom'
import { BadgeCheck, Loader2 } from 'lucide-react'
import apiClient from '../api/client'
import EventCard from '../components/EventCard'
import MarketplacePagination from '../components/MarketplacePagination'
import SEO from '../components/SEO'

export default function OrganizerPage() {
  const { slug } = useParams()
  const [searchParams, setSearchParams] = useSearchParams()
  const page = Math.max(Number(searchParams.get('page')) || 1, 1)
  const [data, setData] = useState(null)

  useEffect(() => {
    setData(null)
    apiClient.get(`/organizers/${slug}`, { params: { page } }).then(response => setData(response.data)).catch(() => setData({ error: true }))
  }, [page, slug])

  if (!data) return <Loader2 className="mx-auto mt-24 h-8 w-8 animate-spin text-brand-500" />
  if (data.error) return <p className="py-24 text-center">Organizer not found.</p>

  return <div className="mx-auto max-w-6xl px-4 py-10"><SEO title={`${data.name} Events`} description={data.description || `Events from ${data.name} on Guam.`} />
    <div className="flex flex-col gap-6 rounded-3xl border border-neutral-200 bg-white p-8 sm:flex-row sm:items-center">{data.logo_url && <img src={data.logo_url} alt="" className="h-24 w-24 rounded-2xl object-cover" />}<div><div className="flex items-center gap-2"><h1 className="font-display text-4xl font-bold">{data.name}</h1>{data.verified && <BadgeCheck className="text-brand-500" aria-label="Verified organizer" />}</div><p className="mt-2 text-neutral-500">{data.completed_events} completed events · {data.tickets_issued} tickets issued · {data.followers} followers</p>{data.ambros_partner && <span className="mt-3 inline-flex rounded-full bg-brand-50 px-3 py-1 text-xs font-semibold text-brand-700">Ambros partner</span>}{data.description && <p className="mt-4 max-w-2xl text-neutral-600">{data.description}</p>}</div></div>
    <h2 className="mt-10 text-2xl font-bold">Upcoming events</h2><div className="mt-5 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">{data.events.map(event => <EventCard key={event.id} event={event} />)}</div>
    <MarketplacePagination meta={data.meta} page={page} onPage={next => setSearchParams(next > 1 ? { page: next } : {})} />
  </div>
}
