import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Compass, Search } from 'lucide-react'
import SEO from './SEO'

const COPY = {
  page: {
    title: 'We couldn’t find that page',
    message: 'The link may be mistyped, or the page may have moved.',
  },
  event: {
    title: 'We couldn’t find that event',
    message: 'The link may be mistyped, or the organizer may have taken the event down. Other events on Guam are a search away.',
  },
  organizer: {
    title: 'We couldn’t find that organizer',
    message: 'The link may be mistyped, or this organizer isn’t listing events on HåfaPass right now.',
  },
  venue: {
    title: 'We couldn’t find that venue',
    message: 'The link may be mistyped, or this venue isn’t listed on HåfaPass right now.',
  },
  collection: {
    title: 'We couldn’t find that collection',
    message: 'The link may be mistyped, or this collection is no longer featured.',
  },
}

// Shared "not found" experience for unknown routes and for public detail pages
// whose record is missing. It always offers a way forward: search, browse, home.
export default function NotFound({ kind = 'page', backTo }) {
  const navigate = useNavigate()
  const [query, setQuery] = useState('')
  const copy = COPY[kind] || COPY.page

  const search = event => {
    event.preventDefault()
    const term = query.trim()
    navigate(term ? `/events?search=${encodeURIComponent(term)}` : '/events')
  }

  return (
    <section aria-labelledby="not-found-title" className="mx-auto flex max-w-xl flex-col items-center px-4 py-16 text-center sm:py-24">
      <SEO title="Not found" noIndex />
      <div className="flex h-14 w-14 items-center justify-center rounded-2xl bg-brand-50 text-brand-600">
        <Compass aria-hidden="true" className="h-7 w-7" />
      </div>
      <p className="mt-6 text-sm font-semibold uppercase tracking-wider text-brand-700">Not found</p>
      <h1 id="not-found-title" className="mt-2 font-display text-3xl font-bold text-neutral-950 sm:text-4xl">{copy.title}</h1>
      <p className="mt-3 text-base text-content-muted">{copy.message}</p>

      <form role="search" onSubmit={search} className="mt-8 flex w-full flex-col gap-3 sm:flex-row">
        <label htmlFor="not-found-search" className="sr-only">Search events</label>
        <div className="relative flex-1">
          <Search aria-hidden="true" className="pointer-events-none absolute left-4 top-1/2 h-4 w-4 -translate-y-1/2 text-neutral-400" />
          <input
            id="not-found-search"
            type="search"
            value={query}
            onChange={event => setQuery(event.target.value)}
            placeholder="Search events or venues"
            className="input !pl-10 text-base"
          />
        </div>
        <button type="submit" className="btn-primary">Search</button>
      </form>

      <div className="mt-4 flex w-full flex-col gap-3 sm:w-auto sm:flex-row">
        <Link to={backTo || '/events'} className="btn-secondary">Browse events</Link>
        <Link to="/" className="btn-ghost">Go to home</Link>
      </div>
    </section>
  )
}
