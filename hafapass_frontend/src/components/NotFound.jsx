import { useTranslation } from 'react-i18next'
import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Compass, Search } from 'lucide-react'
import SEO from './SEO'

const copyFor = t => ({
  page: {
    title: t('buyer.NotFound.pageTitle'),
    message: t('buyer.NotFound.pageMessage'),
  },
  event: {
    title: t('buyer.NotFound.eventTitle'),
    message: t('buyer.NotFound.eventMessage'),
  },
  organizer: {
    title: t('buyer.NotFound.organizerTitle'),
    message: t('buyer.NotFound.organizerMessage'),
  },
  venue: {
    title: t('buyer.NotFound.venueTitle'),
    message: t('buyer.NotFound.venueMessage'),
  },
  collection: {
    title: t('buyer.NotFound.collectionTitle'),
    message: t('buyer.NotFound.collectionMessage'),
  },
})

// Shared "not found" experience for unknown routes and for public detail pages
// whose record is missing. It always offers a way forward: search, browse, home.
export default function NotFound({ kind = 'page', backTo }) {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const [query, setQuery] = useState('')
  const copy = copyFor(t)[kind] || copyFor(t).page

  const search = event => {
    event.preventDefault()
    const term = query.trim()
    navigate(term ? `/events?search=${encodeURIComponent(term)}` : '/events')
  }

  return (
    <section data-release-safe="not-found" aria-labelledby="not-found-title" className="mx-auto flex max-w-xl flex-col items-center px-4 py-16 text-center sm:py-24">
      <SEO title={t('buyer.NotFound.notFound')} noIndex />
      <div className="flex h-14 w-14 items-center justify-center rounded-2xl bg-brand-50 text-brand-600">
        <Compass aria-hidden="true" className="h-7 w-7" />
      </div>
      <p className="mt-6 text-sm font-semibold uppercase tracking-wider text-brand-700">{t('buyer.NotFound.notFound')}</p>
      <h1 id="not-found-title" className="mt-2 font-display text-3xl font-bold text-neutral-950 sm:text-4xl">{copy.title}</h1>
      <p className="mt-3 text-base text-content-muted">{copy.message}</p>

      <form role="search" onSubmit={search} className="mt-8 flex w-full flex-col gap-3 sm:flex-row">
        <label htmlFor="not-found-search" className="sr-only">{t('buyer.NotFound.searchEvents')}</label>
        <div className="relative flex-1">
          <Search aria-hidden="true" className="pointer-events-none absolute left-4 top-1/2 h-4 w-4 -translate-y-1/2 text-neutral-400" />
          <input
            id="not-found-search"
            type="search"
            value={query}
            onChange={event => setQuery(event.target.value)}
            placeholder={t('buyer.NotFound.searchEventsOrVenues')}
            className="input !pl-10 text-base"
          />
        </div>
        <button type="submit" className="btn-primary">{t('buyer.NotFound.search')}</button>
      </form>

      <div className="mt-4 flex w-full flex-col gap-3 sm:w-auto sm:flex-row">
        <Link to={backTo || '/events'} className="btn-secondary">{t('buyer.NotFound.browseEvents')}</Link>
        <Link to="/" className="btn-ghost">{t('buyer.NotFound.goToHome')}</Link>
      </div>
    </section>
  )
}
