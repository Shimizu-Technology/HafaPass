import { Link } from 'react-router-dom'
import { ChevronRight } from 'lucide-react'
import { formatEventDate } from '../../utils/eventTime'
import { formatMoneyCents } from '../../utils/money'

function Tile({ label, children, detail }) {
  return (
    <div className="min-w-0 rounded-xl border border-neutral-200 bg-white p-4">
      <dt className="text-xs font-medium text-neutral-600 sm:text-sm">{label}</dt>
      <dd className="mt-1 truncate text-xl font-bold text-neutral-950 sm:text-2xl">{children}</dd>
      {detail && <dd className="mt-0.5 truncate text-xs text-neutral-600">{detail}</dd>}
    </div>
  )
}

// Organization-wide totals for the dashboard home. Revenue only arrives from
// the API when the member may view finances, so its absence hides the tile
// and the link to the organization finances page.
export default function DashboardSummary({ state, currency = 'USD', onRetry }) {
  if (!state || state.status === 'loading') {
    return (
      <div className="mb-6" aria-busy="true">
        <p role="status" className="sr-only">Loading summary…</p>
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
          {[0, 1, 2, 3].map(index => <div key={index} className="h-[88px] animate-pulse rounded-xl bg-neutral-100 motion-reduce:animate-none" />)}
        </div>
      </div>
    )
  }
  if (state.status === 'error') {
    return (
      <div className="mb-6 flex flex-wrap items-center gap-x-3 rounded-xl border border-neutral-200 bg-white px-4 py-2 text-sm text-neutral-700">
        <p>Your summary is unavailable right now.</p>
        <button type="button" onClick={onRetry} className="min-h-11 font-semibold text-brand-700 underline">Try again</button>
      </div>
    )
  }
  const summary = state.data
  const next = summary.next_event
  const showRevenue = Number.isFinite(summary.revenue_cents)
  return (
    <section aria-label="Summary" className="mb-6">
      <dl className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Tile label="Upcoming events">{summary.upcoming_events_count ?? 0}</Tile>
        <Tile label="Tickets sold">{summary.tickets_sold ?? 0}</Tile>
        {showRevenue && <Tile label="Revenue">{formatMoneyCents(summary.revenue_cents, currency)}</Tile>}
        <Tile label="Next event" detail={next?.title}>{next ? formatEventDate(next.starts_at, next.timezone) : 'None scheduled'}</Tile>
      </dl>
      {showRevenue && (
        <Link to="/dashboard/finances" className="mt-2 inline-flex min-h-11 items-center gap-1 rounded-lg text-sm font-semibold text-brand-700 transition-colors hover:text-brand-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus">
          Finances, payouts and exports
          <ChevronRight aria-hidden="true" className="h-4 w-4" />
        </Link>
      )}
    </section>
  )
}
