import { useTranslation } from 'react-i18next'
import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { Loader2, ArrowRight } from 'lucide-react'
import apiClient from '../api/client'
import EventCard from '../components/EventCard'
import EmptyInventory from '../components/EmptyInventory'
import SEO from '../components/SEO'
import BuyerTitleBand from '../components/BuyerTitleBand'

export default function CollectionsPage() {
  const { t } = useTranslation()
  const [collections, setCollections] = useState(null)
  const [error, setError] = useState(false)
  const [attempt, setAttempt] = useState(0)
  const [inventoryEmpty, setInventoryEmpty] = useState(false)
  useEffect(() => {
    let active = true
    setError(false)
    setCollections(null)
    apiClient.get('/marketplace_collections')
      .then(async res => {
        const next = res.data.collections
        let empty = false
        if (next.length === 0) {
          const inventory = await apiClient.get('/events', { params: { page: 1, per_page: 1 } })
          empty = (inventory.data.events || inventory.data).length === 0 && (inventory.data.meta?.total_count ?? 0) === 0
        }
        if (active) { setInventoryEmpty(empty); setCollections(next) }
      })
      .catch(() => { if (active) setError(true) })
    return () => { active = false }
  }, [attempt])
  return <div className="public-listing-min-height bg-stone-50">
    <SEO title={t('buyerDiscovery.collections.discoverGuam')} description={t('buyerDiscovery.collections.curatedEventsForTonightThisWeekendFamilies')} />
    <BuyerTitleBand title={t('pass.buyer.discover')} description={t('pass.buyer.discoverDescription')} />
    <div className="mx-auto max-w-6xl px-4 py-8 sm:px-6 lg:px-8">
    {!error && collections && inventoryEmpty ? <EmptyInventory className="mx-auto max-w-2xl" /> : <>
    {error ? <div className="text-center"><p role="alert">{t('buyerDiscovery.collections.loadError')}</p><button type="button" className="btn-primary mt-4" onClick={() => setAttempt(value => value + 1)}>{t('buyerDiscovery.collections.tryAgain')}</button></div> : !collections ? <Loader2 className="mx-auto my-16 h-8 w-8 animate-spin text-brand-500" /> : collections.length === 0 ?
      <div className="rounded-2xl border border-neutral-200 bg-white p-10 text-center"><p className="text-sm text-neutral-500">{t('buyerDiscovery.collections.empty')}</p><Link className="btn-primary mt-5 inline-flex" to="/events">{t('buyerDiscovery.collections.browseEvents')}</Link></div> :
      <div className="space-y-14">{collections.map(collection => <section key={collection.id} aria-labelledby={`collection-${collection.id}`}>
        <div className="mb-5 flex flex-wrap items-end justify-between gap-3"><div><h2 id={`collection-${collection.id}`} className="font-display text-2xl font-bold [overflow-wrap:anywhere]">{collection.title}</h2><p className="mt-1 text-neutral-600 [overflow-wrap:anywhere]">{collection.description}</p></div><Link className="ticket-link inline-flex min-h-11 shrink-0 items-center gap-1 rounded-lg px-2 text-sm font-semibold text-brand-800" to={`/collections/${collection.slug}`}>{t('buyerDiscovery.collections.viewAll')}<ArrowRight className="h-4 w-4" /></Link></div>
        <div className="grid gap-6 sm:grid-cols-2 lg:grid-cols-3">{collection.events.map(event => <EventCard key={event.id} event={event} />)}</div>
      </section>)}</div>}
    </>}
    </div>
  </div>
}
