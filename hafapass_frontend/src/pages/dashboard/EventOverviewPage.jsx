import { useCallback, useEffect, useRef, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { CalendarDays, CheckCircle2, Circle, Copy, ExternalLink, Loader2, MapPin } from 'lucide-react'
import apiClient from '../../api/client'
import EventWorkspace from '../../components/EventWorkspace'
import { BackLink, WorkspacePage } from '../../components/WorkspacePage'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import { formatEventDateTime } from '../../utils/eventTime'
import { formatMoneyCents } from '../../utils/money'
import { PUBLIC_WEB_URL } from '../../utils/site'

const statusCopy = {
  draft: 'Draft — only your team can see it.',
  published: 'Published — buyers can find it and get tickets.',
  postponed: 'Postponed — ticket holders keep their tickets until a new date is set.',
  cancelled: 'Cancelled — sales are closed.',
  completed: 'Completed — the event has ended.',
  archived: 'Archived — kept for your records.',
}

export default function EventOverviewPage() {
  const { id } = useParams()
  const identity = useOrganizerIdentity()
  const visit = useOrganizerPageVisit(`/dashboard/events/${id}`)
  if (!visit.active) return null
  if (!identity.ready) return <p role="status" className="p-6">Preparing your account…</p>
  return <EventOverviewSession key={`${identity.accountKey}:${identity.organizationId}:${id}:${visit.generation}`} id={id} identity={identity} />
}

// Quick links mirror the workspace navigation: each appears only when the
// event permission map grants that tool.
function overviewTools(event, has) {
  const base = `/dashboard/events/${event.id}`
  return [
    { label: 'Edit event', to: `${base}/edit`, allowed: has('edit_event_content') },
    { label: 'Ticket types', to: `${base}/edit#ticket-types`, allowed: has('manage_inventory') && has('edit_event_content') },
    { label: 'Attendee list', to: `${base}/attendees`, allowed: has('view_attendees') },
    { label: 'Scan tickets', to: `/dashboard/scanner?event=${event.id}`, allowed: has('scan') },
    { label: 'Box office', to: `${base}/box-office`, allowed: has('box_office') },
    { label: 'Promo codes', to: `${base}/promo-codes`, allowed: has('manage_marketing') },
    { label: 'Event team', to: `${base}/team`, allowed: has('manage_staff') },
    { label: 'Sales & finances', to: `${base}/analytics`, allowed: has('view_finance') },
  ].filter(tool => tool.allowed)
}

function EventOverviewSession({ id, identity }) {
  const { current, beginRequest } = useOrganizerRequests(identity, `/dashboard/events/${id}`)
  const [event, setEvent] = useState(null)
  const [stats, setStats] = useState(null)
  const [admissions, setAdmissions] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [copied, setCopied] = useState(false)
  const generation = useRef(0)

  const get = useCallback(async url => {
    const request = beginRequest()
    if (!request) throw new DOMException('Page context changed', 'AbortError')
    try {
      const response = await apiClient.get(url, request.config)
      if (!request.current()) throw new DOMException('Page context changed', 'AbortError')
      return response
    } finally { request.release() }
  }, [beginRequest])

  const load = useCallback(async () => {
    if (!current()) return
    const attempt = ++generation.current
    const canApply = () => current() && attempt === generation.current
    setLoading(true); setError(null); setStats(null); setAdmissions(null)
    try {
      const saved = (await get(`/organizer/events/${id}`)).data
      if (!canApply()) return
      if (String(saved.id) !== String(id) || (identity.organizationId != null && saved.organization_id != null && String(saved.organization_id) !== String(identity.organizationId))) {
        setEvent(null)
        setError('This event could not be matched to the selected organization. Return to your dashboard and pick it again.')
        return
      }
      setEvent(saved)
      setLoading(false)
      // Sales and door numbers are optional extras. A failure here leaves
      // the rest of the overview usable.
      const permissions = saved.permissions || {}
      const [statsResponse, admissionsResponse] = await Promise.all([
        permissions.view_finance === true ? get(`/organizer/events/${id}/stats`).catch(() => null) : null,
        permissions.view_finance !== true && permissions.scan === true ? get(`/organizer/events/${id}/admissions`).catch(() => null) : null,
      ])
      if (!canApply()) return
      setStats(statsResponse?.data || null)
      setAdmissions(admissionsResponse?.data?.counts || null)
    } catch (requestError) {
      if (!canApply()) return
      setEvent(null)
      const status = requestError.response?.status
      setError(status === 401 ? 'Please sign in to see this event.'
        : status === 403 ? 'Your access does not include this event.'
          : status === 404 ? 'Event not found.' : 'We could not load this event. Please try again.')
    } finally { if (canApply()) setLoading(false) }
  }, [current, get, id, identity.organizationId])
  useEffect(() => { load() }, [load])

  const copyLink = async url => {
    try { await navigator.clipboard.writeText(url); setCopied(true) } catch { setCopied(false) }
  }

  if (loading && !event) {
    return <EventWorkspace eventId={id} event={null}>
      <p role="status" className="flex items-center gap-2 text-sm text-neutral-700"><Loader2 aria-hidden="true" className="h-4 w-4 animate-spin" />Loading event overview…</p>
    </EventWorkspace>
  }
  if (!event) {
    return <WorkspacePage width="form">
      <BackLink>All events</BackLink>
      <div className="mt-4 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700" role="alert">
        <p>{error}</p>
        <button type="button" onClick={load} className="mt-2 min-h-11 font-semibold underline">Try again</button>
      </div>
    </WorkspacePage>
  }

  const has = key => event.permissions?.[key] === true
  const ticketTypes = event.ticket_types || []
  const sold = stats ? stats.total_tickets_sold : ticketTypes.reduce((sum, type) => sum + (type.quantity_sold || 0), 0)
  const inventory = ticketTypes.reduce((sum, type) => sum + (type.quantity_available || 0), 0)
  const capacity = inventory || event.max_capacity || 0
  const soldPercent = capacity > 0 ? Math.min(100, Math.round((sold / capacity) * 100)) : 0
  const checkIn = stats ? { admitted: stats.tickets_checked_in, total: stats.total_tickets_sold }
    : admissions ? { admitted: admissions.admitted, total: admissions.admitted + admissions.remaining } : null
  const checklist = event.publish_checklist || []
  const openItems = checklist.filter(item => !item.complete)
  const publicPath = event.slug ? `/events/${event.slug}` : null
  const tools = overviewTools(event, has)

  return <EventWorkspace eventId={id} event={event}>
    <div className="space-y-6">
      <section aria-labelledby="overview-status" className="rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6">
        <h2 id="overview-status" className="text-lg font-semibold text-neutral-950">Overview</h2>
        <p className="mt-1 text-sm text-neutral-700">{statusCopy[event.status] || 'Event status unavailable.'}</p>
        <dl className="mt-4 grid gap-3 text-sm sm:grid-cols-2">
          <div className="flex items-start gap-2"><CalendarDays aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-neutral-500" /><div><dt className="sr-only">Date</dt><dd className="text-neutral-900">{event.starts_at ? formatEventDateTime(event.starts_at, event.timezone) : 'Date not set yet'}</dd></div></div>
          <div className="flex items-start gap-2"><MapPin aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-neutral-500" /><div className="min-w-0"><dt className="sr-only">Venue</dt><dd className="break-words text-neutral-900">{event.venue_name || 'Venue not set yet'}{event.venue_city ? `, ${event.venue_city}` : ''}</dd></div></div>
        </dl>
      </section>

      <section aria-labelledby="overview-sales" className="rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6">
        <h2 id="overview-sales" className="text-lg font-semibold text-neutral-950">Sales so far</h2>
        <div className="mt-4 grid grid-cols-2 gap-3 sm:grid-cols-3">
          <div className="rounded-xl bg-neutral-50 p-3">
            <p className="text-xs text-neutral-600">Tickets sold</p>
            <p className="mt-1 text-xl font-bold text-neutral-950">{sold}{capacity > 0 && <span className="text-sm font-medium text-neutral-600"> / {capacity}</span>}</p>
          </div>
          {stats && <div className="rounded-xl bg-neutral-50 p-3">
            <p className="text-xs text-neutral-600">Revenue</p>
            <p className="mt-1 text-xl font-bold text-neutral-950">{formatMoneyCents(stats.total_revenue_cents)}</p>
          </div>}
          {checkIn && <div className="rounded-xl bg-neutral-50 p-3">
            <p className="text-xs text-neutral-600">Checked in</p>
            <p className="mt-1 text-xl font-bold text-neutral-950">{checkIn.admitted}<span className="text-sm font-medium text-neutral-600"> / {checkIn.total}</span></p>
          </div>}
        </div>
        {capacity > 0 && <div className="mt-4 h-2 overflow-hidden rounded-full bg-neutral-100" role="progressbar" aria-label="Tickets sold of capacity" aria-valuemin={0} aria-valuemax={100} aria-valuenow={soldPercent}>
          <div className="h-full rounded-full bg-brand-600" style={{ width: `${soldPercent}%` }} />
        </div>}
      </section>

      <section aria-labelledby="overview-next" className="rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6">
        <h2 id="overview-next" className="text-lg font-semibold text-neutral-950">Next steps</h2>
        {event.status === 'draft' && <>
          <p className="mt-1 text-sm text-neutral-700">{openItems.length ? `${checklist.length - openItems.length} of ${checklist.length} publish checks done.` : 'All publish checks are done.'}</p>
          {openItems.length > 0 && <ul className="mt-3 space-y-2 text-sm text-neutral-800">
            {openItems.slice(0, 5).map(item => <li key={item.code} className="flex items-start gap-2"><Circle aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-neutral-400" />{item.label}</li>)}
            {openItems.length > 5 && <li className="pl-6 text-neutral-600">and {openItems.length - 5} more</li>}
          </ul>}
          {has('edit_event_content')
            ? <Link to={`/dashboard/events/${event.id}/edit`} className="btn-primary mt-4 inline-flex min-h-11 text-sm">{openItems.length ? 'Finish setup' : 'Review and publish'}</Link>
            : <p className="mt-3 text-sm text-neutral-600">Ask an event manager to finish setup and publish.</p>}
        </>}
        {event.status === 'published' && <>
          <p className="mt-1 flex items-center gap-2 text-sm text-neutral-700"><CheckCircle2 aria-hidden="true" className="h-4 w-4 text-emerald-600" />Your event is live. Share it and get ready for the door.</p>
          <div className="mt-4 flex flex-wrap gap-2">
            {publicPath && <Link to={publicPath} className="btn-secondary inline-flex min-h-11 gap-2 text-sm"><ExternalLink aria-hidden="true" className="h-4 w-4" />View public page</Link>}
            {publicPath && <button type="button" onClick={() => copyLink(`${PUBLIC_WEB_URL}${publicPath}`)} className="btn-secondary inline-flex min-h-11 gap-2 text-sm"><Copy aria-hidden="true" className="h-4 w-4" />{copied ? 'Link copied' : 'Copy event link'}</button>}
            {has('scan') && <Link to={`/dashboard/scanner?event=${event.id}`} className="btn-secondary inline-flex min-h-11 text-sm">Scan tickets</Link>}
          </div>
          <p className="sr-only" aria-live="polite">{copied ? 'Event link copied' : ''}</p>
        </>}
        {event.status === 'postponed' && <p className="mt-1 text-sm text-neutral-700">{has('edit_event_content') ? <>Set a new date in <Link to={`/dashboard/events/${event.id}/edit`} className="font-semibold text-brand-700 underline">event details</Link> when you have one.</> : 'Your event manager will set a new date.'}</p>}
        {['cancelled', 'completed', 'archived'].includes(event.status) && <p className="mt-1 text-sm text-neutral-700">This event is closed. {has('view_finance') ? <>Review the final numbers in <Link to={`/dashboard/events/${event.id}/analytics`} className="font-semibold text-brand-700 underline">sales &amp; finances</Link>.</> : 'Nothing else needs doing here.'}</p>}
      </section>

      {tools.length > 0 && <section aria-labelledby="overview-tools">
        <h2 id="overview-tools" className="text-lg font-semibold text-neutral-950">Event tools</h2>
        <ul className="mt-3 grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3">
          {tools.map(tool => <li key={tool.to}><Link to={tool.to} className="flex min-h-11 items-center rounded-xl border border-neutral-200 bg-white px-4 py-3 text-sm font-medium text-neutral-900 transition-colors hover:border-brand-300 hover:bg-brand-50">{tool.label}</Link></li>)}
        </ul>
      </section>}
    </div>
  </EventWorkspace>
}
