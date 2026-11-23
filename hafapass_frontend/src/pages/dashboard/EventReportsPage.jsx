import { useEffect, useId, useRef, useState } from 'react'
import { Link, useParams, useSearchParams } from 'react-router-dom'
import { Download, Printer, X } from 'lucide-react'
import apiClient from '../../api/client'
import EventWorkspace from '../../components/EventWorkspace'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import { saveBlob } from '../../utils/download'
import { AttendanceReport, DemographicsReport, PayoutsReport, RegistrationReport, SalesReport } from './EventReportViews'
import './eventReports.css'

const VIEWS = [
  { tab: 'sales', label: 'Sales by Price Window', type: 'sales_by_tier', permission: 'view_finance' },
  { tab: 'attendance', label: 'Attendance & Door Pace', type: 'attendance', permission: 'view_attendees' },
  { tab: 'demographics', label: 'Attendee Answers & Sizes', type: 'demographics', permission: 'view_attendees' },
  { tab: 'registrations', label: 'Registrations & Teams', type: 'registrations_roster', permission: 'view_attendees' },
  { tab: 'payouts', label: 'Payouts & Splits', type: 'payouts', permission: 'view_finance' },
]
const CHANNELS = { online: 'Online', box_office: 'Box office', guest_list: 'Guest list' }
const STATUSES = { checked_in: 'Checked in', not_checked_in: 'Not checked in', paid: 'Paid', partially_refunded: 'Partially refunded', refunded: 'Refunded', cancelled: 'Cancelled' }
const FILTER_KEYS = ['ticket_type_id', 'channel', 'status']
const ROSTER_FILTERS = ['question_id', 'answer_value', 'search']

function setFilters(params, changes) {
  const next = new URLSearchParams(params)
  Object.entries(changes).forEach(([key, value]) => {
    if (value === '' || value == null) next.delete(key)
    else next.set(key, value)
  })
  return next
}

export default function EventReportsPage() {
  const { id } = useParams()
  const identity = useOrganizerIdentity()
  const path = `/dashboard/events/${id}/reports`
  const visit = useOrganizerPageVisit(path)
  if (!visit.active) return null
  if (!identity.ready) return <p className="p-6" role="status">Preparing your account…</p>
  return <EventReportsSession key={`${identity.accountKey}:${identity.organizationId}:${id}:${visit.generation}`} id={id} identity={identity} path={path} />
}

function EventReportsSession({ id, identity, path }) {
  const { beginRequest } = useOrganizerRequests(identity, path)
  const [event, setEvent] = useState(null)
  const [eventError, setEventError] = useState('')
  const [attempt, retry] = useState(0)

  useEffect(() => {
    const request = beginRequest()
    if (!request) return
    apiClient.get(`/organizer/events/${id}`, request.config).then(({ data }) => {
      if (!request.current()) return
      if (String(data.id) !== id || data.organization_id == null ||
        (identity.organizationId != null && String(data.organization_id) !== String(identity.organizationId))) {
        setEventError('This event could not be verified. Select the event again from your dashboard.')
        return
      }
      setEvent(data)
    }).catch(error => {
      if (request.current()) setEventError(error.response?.status === 403 ? 'Your role does not include this event.' : 'The event could not be loaded.')
    }).finally(request.release)
    return () => { request.controller.abort(); request.release() }
  }, [beginRequest, id, identity.organizationId, attempt])

  const views = VIEWS.filter(view => event?.permissions?.[view.permission] === true)
  return <EventWorkspace event={event} eventId={id}>
    <section className="event-report space-y-5 text-base text-neutral-950" aria-labelledby="reports-title">
      {event && <p className="hidden text-2xl font-bold print:block">{event.title}</p>}
      <h2 id="reports-title" className="text-2xl font-bold">Reports</h2>
      {eventError ? <ReportError message={eventError} onRetry={() => { setEventError(''); setEvent(null); retry(value => value + 1) }} />
        : !event ? <p role="status">Loading reports…</p>
        : views.length === 0 ? <p role="alert">Your role does not include event reports.</p>
        : <ReportSession views={views} event={event} path={path} beginRequest={beginRequest} />}
    </section>
  </EventWorkspace>
}

function ReportError({ message, onRetry }) {
  return <div role="alert" className="rounded-lg border border-red-300 bg-red-50 p-4 text-red-900">
    <p>{message}</p>
    <button type="button" onClick={onRetry} className="mt-1 min-h-12 font-semibold underline">Try again</button>
  </div>
}

const deniedResponse = error => [401, 403, 404].includes(error?.response?.status)

function ReportSession({ views, event, path, beginRequest }) {
  const [params, setParams] = useSearchParams()
  const requested = params.get('tab')
  const view = views.find(item => item.tab === requested) || views[0]
  const filter = key => params.get(key) || ''
  const to = changes => ({ pathname: path, search: setFilters(params, changes).toString() })
  const change = changes => {
    // BrowserRouter can commit the URL before React renders the new tab.
    // A filter used during that gap should update the URL the user just chose.
    const latest = window.location.pathname === path ? window.location.search : params
    setParams(setFilters(latest, { page: null, ...changes }))
  }
  const roster = view.tab === 'registrations'
  const payouts = view.tab === 'payouts'
  const filterKeys = payouts ? [] : roster ? [...FILTER_KEYS, ...ROSTER_FILTERS] : FILTER_KEYS
  const filters = Object.fromEntries(filterKeys.filter(key => params.has(key)).map(key => [key, params.get(key)]))
  const requestFilters = { ...filters, ...(roster ? { active_only: 'true', page: filter('page') || '1' } : { report_type: view.type }) }
  const requestKey = new URLSearchParams(requestFilters).toString()
  const base = `/organizer/events/${event.id}`
  const endpoint = `${base}/${roster ? 'attendees' : 'reports'}`
  const [result, setResult] = useState(null)
  const [attempt, retry] = useState(0)
  const currentResult = result?.requestKey === requestKey && result?.attempt === attempt ? result : null
  const exportRequest = useRef(null)
  const [exportState, setExportState] = useState(null)
  const [denied, setDenied] = useState(false)
  const viewHeading = useRef(null)
  const previousTab = useRef(view.tab)

  useEffect(() => {
    if (previousTab.current !== view.tab && roster && params.has('question_id')) viewHeading.current?.focus()
    previousTab.current = view.tab
  }, [view.tab, roster, params])

  useEffect(() => {
    const request = beginRequest()
    if (!request) return
    apiClient.get(endpoint, { params: Object.fromEntries(new URLSearchParams(requestKey)), ...request.config }).then(({ data }) => {
      if (request.current()) setResult({ requestKey, attempt, data })
    }).catch(error => {
      if (!request.current()) return
      if (deniedResponse(error)) {
        setDenied(true)
        exportRequest.current?.controller.abort()
        setExportState(null)
      }
      const message = error.response?.status === 422 ? 'One of these filters is unavailable. Clear the filters to try again.' : 'This report could not be loaded.'
      setResult({ requestKey, attempt, error: message })
    }).finally(request.release)
    return () => { request.controller.abort(); request.release() }
  }, [attempt, beginRequest, endpoint, requestKey])

  const download = async () => {
    if (exportRequest.current) return
    const request = beginRequest()
    if (!request) return
    exportRequest.current = request
    setExportState({ kind: 'loading', requestKey })
    try {
      const { data } = await apiClient.get(`${base}/reports/export.csv`, {
        ...request.config, responseType: 'blob', params: { ...filters, report_type: view.type },
      })
      if (typeof data.text === 'function' && (await data.text()).includes('EXPORT INCOMPLETE: an error stopped this file early.')) {
        throw new Error('Incomplete CSV')
      }
      if (request.current()) saveBlob(data, `${event.slug || 'event'}-${view.type.replaceAll('_', '-')}.csv`)
      if (request.current()) setExportState({ kind: 'success', requestKey })
    } catch (error) {
      if (request.current()) {
        if (deniedResponse(error)) setDenied(true)
        setExportState({ kind: 'error', requestKey })
      }
    } finally {
      exportRequest.current = null
      request.release()
    }
  }

  const clear = () => setParams(setFilters(params, {
    tab: view.tab, ticket_type_id: null, status: null, channel: null, search: null, page: null, question_id: null, answer_value: null,
  }))
  if (denied) return <ReportError message="This report is unavailable. Your event access may have changed." onRetry={() => { setDenied(false); retry(value => value + 1) }} />

  const data = currentResult?.data
  const answerValue = filter('answer_value')
  const question = data?.registration_questions?.find(row => String(row.question_id) === filter('question_id'))
  const answerLabel = question?.kind === 'checkbox' ? (({ true: 'Yes', false: 'No' })[answerValue] || answerValue) : answerValue
  const chipLabel = question ? `${question.prompt} · ${answerLabel}` : `Answer · ${answerLabel}`
  const selectedFilters = [
    event.ticket_types?.find(type => String(type.id) === filter('ticket_type_id'))?.name,
    CHANNELS[filter('channel')], STATUSES[filter('status')], roster && filter('question_id') && chipLabel,
    roster && filter('search') && `Search · ${filter('search')}`,
  ].filter(Boolean)
  const visibleExport = exportState?.requestKey === requestKey ? exportState.kind : null

  return <>
    <nav aria-label="Report views" className="grid grid-cols-2 gap-2 xl:grid-cols-5 event-report-controls">
      {views.map(item => <Link key={item.tab} to={to({ tab: item.tab, page: null })} aria-current={view.tab === item.tab ? 'page' : undefined}
        className={`flex min-h-12 items-center rounded-lg border px-3 py-2 font-semibold leading-snug ${view.tab === item.tab
          ? 'border-brand-800 bg-brand-800 text-white' : 'border-neutral-400 bg-white text-neutral-900 hover:bg-neutral-100'}`}>{item.label}</Link>)}
    </nav>

    {!payouts && <div className="event-report-controls space-y-4 rounded-xl border border-neutral-200 bg-white p-4">
      <div className="flex flex-wrap items-end gap-3">
        <ReportSelect label="Ticket type" value={filter('ticket_type_id')} onChange={value => change({ ticket_type_id: value })}
          placeholder="All ticket types" choices={(event.ticket_types || []).map(type => [type.id, type.name])} />
        <ReportSelect label="Where tickets came from" value={filter('channel')} onChange={value => change({ channel: value })}
          placeholder="All sources" choices={Object.entries(CHANNELS)} />
        <ReportSelect label="Status" value={filter('status')} onChange={value => change({ status: value })}
          placeholder="All statuses" choices={Object.entries(STATUSES)} />
        {Object.keys(filters).length > 0 && <button type="button" className="min-h-12 px-2 font-semibold underline" onClick={clear}>Clear filters</button>}
      </div>
      {roster && <form key={filter('search')} onSubmit={submit => {
        submit.preventDefault()
        change({ search: new FormData(submit.currentTarget).get('search').trim() })
      }} className="flex flex-wrap items-end gap-3">
        <label className="grid w-full max-w-sm gap-1 font-medium">
          Search registrations
          <input name="search" type="search" defaultValue={filter('search')} placeholder="Name, email or order number" className="input min-h-12 text-base" />
        </label>
        <button type="submit" className="btn-secondary min-h-12 text-base">Search</button>
      </form>}
      {roster && filter('question_id') && <button type="button" aria-label={`Remove filter ${chipLabel}`}
        onClick={() => change({ question_id: null, answer_value: null })}
        className="inline-flex min-h-12 max-w-full items-center gap-2 rounded-lg border border-brand-700 bg-brand-50 px-3 text-left font-semibold text-brand-900">
        <span className="break-all">{chipLabel}</span><X size={18} className="shrink-0" aria-hidden="true" />
      </button>}
    </div>}

    <div className="flex flex-wrap items-center justify-between gap-3">
      <h3 ref={viewHeading} tabIndex={-1} id="report-view-title" className="text-xl font-bold outline-offset-4">{view.label}</h3>
      {data && !payouts && <div className="event-report-controls flex flex-wrap gap-2">
        <button type="button" className="btn-primary min-h-12 gap-2 text-base" onClick={download} disabled={exportState?.kind === 'loading'}>
          <Download size={18} aria-hidden="true" />{exportState?.kind === 'loading' ? 'Downloading…' : 'Download CSV'}
        </button>
        <button type="button" className="btn-secondary min-h-12 gap-2 text-base" onClick={() => window.print()}>
          <Printer size={18} aria-hidden="true" />Print Report
        </button>
      </div>}
    </div>
    {selectedFilters.length > 0 && <p className="hidden print:block">{selectedFilters.join(' · ')}</p>}
    {visibleExport === 'error' && <p className="event-report-controls text-red-800" role="alert">The CSV could not be downloaded. Try again.</p>}
    {visibleExport === 'success' && <p className="event-report-controls text-neutral-700" role="status">CSV downloaded.</p>}
    {!currentResult && <p role="status">Loading report…</p>}
    {currentResult?.error && <ReportError message={currentResult.error} onRetry={() => retry(value => value + 1)} />}
    {data && view.tab === 'sales' && <SalesReport data={data} />}
    {data && view.tab === 'attendance' && <AttendanceReport data={data.attendance} />}
    {data && view.tab === 'demographics' && <DemographicsReport questions={data.demographics} answerLink={(question, bucket) =>
      to({ tab: 'registrations', question_id: question.question_id, answer_value: question.kind === 'short_text' ? bucket.label : bucket.value, search: null, page: null })} />}
    {data && roster && <RegistrationReport data={data} changePage={page => change({ page })} />}
    {data && payouts && <PayoutsReport series={data.payout_series} eventId={event.id} />}
  </>
}

function ReportSelect({ label, value, onChange, placeholder, choices }) {
  const id = useId()
  return <div className="grid min-w-0 max-w-full gap-1 font-medium">
    <label htmlFor={id}>{label}</label>
    <select id={id} className="input min-h-12 max-w-full text-base" value={value} onChange={event => onChange(event.target.value)}>
      <option value="">{placeholder}</option>
      {value && !choices.some(([key]) => String(key) === value) && <option value={value}>From shared link</option>}
      {choices.map(([key, name]) => <option key={key} value={key}>{name}</option>)}
    </select>
  </div>
}
