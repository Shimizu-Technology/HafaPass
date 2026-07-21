import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { Loader2, ArrowRight } from 'lucide-react'
import apiClient from '../api/client'
import EventCard from '../components/EventCard'
import SEO from '../components/SEO'

export default function CollectionsPage() {
  const [collections, setCollections] = useState(null)
  useEffect(() => { apiClient.get('/marketplace_collections').then(res => setCollections(res.data.collections)).catch(() => setCollections([])) }, [])
  return <div className="mx-auto max-w-6xl px-4 py-10 sm:px-6">
    <SEO title="Discover Guam" description="Curated events for tonight, this weekend, families, visitors, and every village on Guam." />
    <h1 className="font-display text-4xl font-bold text-neutral-950">Discover Guam</h1>
    <p className="mt-2 text-neutral-500">Useful local picks, curated by people—not an opaque ranking.</p>
    {!collections ? <Loader2 className="mx-auto mt-16 h-8 w-8 animate-spin text-brand-500" /> : collections.length === 0 ?
      <div className="mt-10 rounded-2xl border border-neutral-200 bg-white p-10 text-center"><h2 className="font-semibold">Fresh events are on the way</h2><p className="mt-2 text-sm text-neutral-500">Browse all current inventory or publish the island’s next event.</p><Link className="btn-primary mt-5 inline-flex" to="/events">Browse events</Link></div> :
      <div className="mt-10 space-y-14">{collections.map(collection => <section key={collection.id} aria-labelledby={`collection-${collection.id}`}>
        <div className="mb-5 flex items-end justify-between gap-4"><div><h2 id={`collection-${collection.id}`} className="text-2xl font-bold">{collection.title}</h2><p className="mt-1 text-neutral-500">{collection.description}</p></div><Link className="inline-flex items-center gap-1 text-sm font-semibold text-brand-600" to={`/collections/${collection.slug}`}>View all <ArrowRight className="h-4 w-4" /></Link></div>
        <div className="grid gap-6 sm:grid-cols-2 lg:grid-cols-3">{collection.events.map(event => <EventCard key={event.id} event={event} />)}</div>
      </section>)}</div>}
  </div>
}
