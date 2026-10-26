import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import EventWorkspace from '../../components/EventWorkspace'
import Dialog from '../../components/Dialog'
import { Loader2, Search, ChevronLeft, ChevronRight, Download, Mail, ScanLine, SlidersHorizontal, Printer } from 'lucide-react'
import { useState, useEffect, useCallback, useRef } from 'react'
import { Link, useParams, useSearchParams } from 'react-router-dom'
import apiClient from '../../api/client'
import TestPaymentBadge from '../../components/TestPaymentBadge'
import { pluralize } from '../../utils/eventToolFormat'
import { saveBlob } from '../../utils/download'

const STATUS_STYLES = {
  checked_in: { label: 'Checked in', className: 'bg-green-100 text-green-800' },
  issued: { label: 'Valid', className: 'bg-brand-100 text-brand-700' },
  cancelled: { label: 'Cancelled', className: 'bg-red-100 text-red-800' },
  refunded: { label: 'Refunded', className: 'bg-amber-100 text-amber-900' },
  partially_refunded: { label: 'Partially refunded', className: 'bg-amber-100 text-amber-900' },
  transferred: { label: 'Transferred', className: 'bg-neutral-100 text-neutral-800' },
  completed: { label: 'Paid', className: 'bg-green-100 text-green-800' }
}
const STATUS_LABELS = {
  paid: 'Paid', issued: 'Valid', checked_in: 'Checked in', not_checked_in: 'Not checked in',
  refunded: 'Refunded', partially_refunded: 'Partially refunded', cancelled: 'Cancelled', transferred: 'Transferred'
}
const SORT_LABELS = { purchase_date: 'purchase date', name: 'name', ticket_type: 'ticket type', amount: 'amount', check_in_time: 'check-in time' }

function dateChip(value) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return value
  const [year, month, day] = value.split('-').map(Number)
  return new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' }).format(new Date(Date.UTC(year, month - 1, day)))
}

function filterChips(params, ticketTypes) {
  const chips = []
  for (const [key, value] of params.entries()) {
    if (!value || key === 'page' || key === 'purchased_to' || key === 'direction') continue
    if (key === 'view' && value === 'tickets') continue
    if (key === 'payment_environment' && value === 'live') continue
    if (key === 'sort' && value === 'purchase_date' && (params.get('direction') || 'desc') === 'desc') continue
    if (key === 'purchased_from') {
      const end = params.get('purchased_to')
      chips.push({ keys: ['purchased_from', 'purchased_to'], label: `Purchased ${dateChip(value)}${end ? ` – ${dateChip(end)}` : ' onward'}` })
      continue
    }
    if (key === 'sort') {
      const direction = params.get('direction') || 'desc'
      const suffix = value === 'name' || value === 'ticket_type' ? (direction === 'asc' ? 'A–Z' : 'Z–A')
        : value === 'amount' ? (direction === 'asc' ? 'low to high' : 'high to low')
          : direction === 'asc' ? 'oldest first' : 'newest first'
      chips.push({ keys: ['sort', 'direction'], label: `Sorted by ${SORT_LABELS[value] || value} (${suffix})` })
      continue
    }
    const labels = {
      view: value === 'orders' ? 'Orders' : 'Tickets / attendees', status: `Status: ${STATUS_LABELS[value] || value}`,
      ticket_type: `Ticket type: ${ticketTypes.find(type => String(type.id) === value)?.name || value}`,
      search: `Search: ${value}`, channel: `Sales channel: ${value === 'box_office' ? 'Box office' : value === 'guest_list' ? 'Comp / guest list' : 'Online'}`,
      promo_code: `Promo code: ${value}`, payment_environment: value === 'test' ? 'Test orders only' : 'Live and test orders',
      purchased_to: `Purchased through ${dateChip(value)}`
    }
    chips.push({ keys: [key], label: labels[key] || `${key.replaceAll('_', ' ')}: ${value}` })
  }
  if (params.get('purchased_to') && !params.get('purchased_from')) chips.push({ keys: ['purchased_to'], label: `Purchased through ${dateChip(params.get('purchased_to'))}` })
  if (params.get('direction') && !params.get('sort') && params.get('direction') !== 'desc') chips.push({ keys: ['direction'], label: 'Oldest first' })
  return chips
}

const RESENDABLE_STATUSES = new Set(['issued', 'checked_in'])

async function exportFailureMessage(error, fallback) {
  if (error?.response?.status === 429) return 'Too many exports. Try again later.'
  const data = error?.response?.data
  try {
    const content = data instanceof Blob ? (typeof data.text === 'function' ? await data.text() :
      await new Promise((resolve, reject) => {
        const reader = new FileReader()
        reader.onload = () => resolve(reader.result)
        reader.onerror = () => reject(reader.error)
        reader.readAsText(data)
      })) : null
    const body = content == null ? data : JSON.parse(content)
    return body?.error || fallback
  } catch { return fallback }
}

function formatDate(iso, timeZone) {
  if (!iso) return '—'
  return new Date(iso).toLocaleString('en-US', { timeZone: timeZone || 'Pacific/Guam', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
}

export default function AttendeesPage() {
 const { id } = useParams()
 const identity = useOrganizerIdentity()
 const visit = useOrganizerPageVisit(`/dashboard/events/${id}/attendees`)
 if (!visit.active) return null
 if (!identity.ready) return <p role="status" className="p-6">Preparing your account…</p>
 return <AttendeesPageSession key={`${identity.accountKey}:${identity.organizationId}:${id}:${visit.generation}`} id={id} identity={identity} />
}

function AttendeesPageSession({ id, identity }) {
 const [searchParams, setSearchParams] = useSearchParams()
 const filter = key => searchParams.get(key) || ''
 const changeFilter = (key, value) => setSearchParams(previous => {
  const next = new URLSearchParams(previous)
  if (value) next.set(key, String(value)); else next.delete(key)
  if (key !== 'page') next.delete('page')
  return next
 }, { replace: true })
 const { current, beginRequest } = useOrganizerRequests(identity, `/dashboard/events/${id}/attendees`)
 const accessEpoch = useRef(0)
 const accessDenied = useRef(false)
 const requests = useRef(new Set())
 // Exports and row actions outlive list refreshes (filters, paging) and stop
 // only when access is withdrawn, so a resend is never silently abandoned.
 const exportRequests = useRef(new Set())
 const accessWithdrawals = useRef(0)
 const [loading, setLoading] = useState(true)
 const [error, setError] = useState(null)
 const [detailError, setDetailError] = useState(null)
 const [loadAttempt, setLoadAttempt] = useState(0)
 const [attendees, setAttendees] = useState([])
 const [meta, setMeta] = useState(null)
 const [event, setEvent] = useState(null)
 const page = Math.max(1, Number(filter('page')) || 1)
 const setPage = value => changeFilter('page', typeof value === 'function' ? value(page) : value)
 const listGeneration = useRef(0)
 const search = filter('search')
 const statusFilter = filter('status')
 const ticketTypeFilter = filter('ticket_type')
 const [filtersOpen, setFiltersOpen] = useState(false)
 const [exportOpen, setExportOpen] = useState(false)
 const [exportColumns, setExportColumns] = useState(['name', 'email', 'order_number', 'ticket_type', 'channel', 'status', 'purchase_date'])
 const [queuedExport, setQueuedExport] = useState(null)
 const [recentExports, setRecentExports] = useState([])
 const [exporting, setExporting] = useState(false)
 const [exportError, setExportError] = useState(null)
 const [resendTarget, setResendTarget] = useState(null)
 const [resending, setResending] = useState(false)
 const [resendError, setResendError] = useState(null)
 const [actionNotice, setActionNotice] = useState(null)
 const withdrawAccess = useCallback(message => {
  accessDenied.current = true
  ++accessEpoch.current
  ++accessWithdrawals.current
  requests.current.forEach(request => request.controller.abort())
  exportRequests.current.forEach(request => request.controller.abort())
  setAttendees([]); setMeta(null); setEvent(null); setRecentExports([]); setQueuedExport(null)
  setDetailError(null); setError(message); setLoading(false)
 }, [])
 const withdrawForDenial = useCallback(requestError => {
  const status = requestError.response?.status
  if (![401, 403, 404].includes(status)) return
  withdrawAccess(status === 401 ? 'Please sign in.'
   : status === 404 ? 'Event not found.' : 'Your attendee access changed. Retry to verify access before viewing this list.')
 }, [withdrawAccess])
 const requestApi = useCallback(async (method, url, payload, options = {}) => {
  const request = beginRequest()
  if (!request) throw new DOMException('Page context changed', 'AbortError')
  const epoch = accessEpoch.current
  requests.current.add(request)
  try {
   const response = method === 'get' || method === 'delete'
    ? await apiClient[method](url, { ...payload, ...request.config })
    : await apiClient[method](url, payload, { ...options, ...request.config })
   if (!request.current() || epoch !== accessEpoch.current) throw new DOMException('Page context changed', 'AbortError')
   return response
  } catch (requestError) {
   if (request.current() && epoch === accessEpoch.current) withdrawForDenial(requestError)
   throw requestError
  } finally { requests.current.delete(request); request.release() }
 }, [beginRequest, withdrawForDenial])
 // A row action's 403/404 concerns that ticket, so only a lost sign-in (401)
 // withdraws the page; the list read already re-verifies event permissions.
 const requestOutsideList = useCallback(async (send, { withdrawOnlyForSignIn = false } = {}) => {
  const request = beginRequest()
  if (!request) throw new DOMException('Page context changed', 'AbortError')
  const withdrawal = accessWithdrawals.current
  exportRequests.current.add(request)
  try {
   const response = await send(request.config)
   if (!request.current() || withdrawal !== accessWithdrawals.current) throw new DOMException('Page context changed', 'AbortError')
   return response
  } catch (requestError) {
   const pageDenial = !withdrawOnlyForSignIn || requestError.response?.status === 401
   if (pageDenial && request.current() && withdrawal === accessWithdrawals.current) withdrawForDenial(requestError)
   throw requestError
  } finally { exportRequests.current.delete(request); request.release() }
 }, [beginRequest, withdrawForDenial])
 const activeQuery = useCallback(() => {
  const query = new URLSearchParams(searchParams)
  query.delete('page')
  return query
 }, [searchParams])
 const requestExport = useCallback((columns) => requestOutsideList(config => apiClient.post(`/organizer/events/${id}/sales_exports`,
  { ...Object.fromEntries(activeQuery()), columns }, { responseType: 'blob', ...config })), [id, requestOutsideList, activeQuery])

  const fetchAttendees = useCallback(async () => {
    const generation = ++listGeneration.current
    if (!current()) return
    const epoch = ++accessEpoch.current
    requests.current.forEach(request => request.controller.abort())
    const canApply = () => current() && generation === listGeneration.current && epoch === accessEpoch.current
    setLoading(true)
    setError(null)
    try {
      try {
        const response = await requestApi('get', `/organizer/events/${id}`)
        if (!canApply()) return
        const saved = response.data
        if (String(saved.id) !== String(id) || saved.organization_id == null || (identity.organizationId != null && String(saved.organization_id) !== String(identity.organizationId))) {
          withdrawAccess('The event context could not be verified. Return to your dashboard and select the event again.')
          return
        }
        if (saved.permissions?.view_attendees !== true && saved.permissions?.view_finance !== true) {
          withdrawAccess('Your event access does not include viewing attendees.')
          return
        }
        accessDenied.current = false
        setEvent(saved); setDetailError(null)
      } catch {
        if (!canApply()) return
        setDetailError('Failed to load event details.')
        // A list endpoint can independently authorize a normal metadata outage.
        // After a known denial, only fresh event permission verification restores it.
        if (accessDenied.current) return
      }
      const params = new URLSearchParams({ page: String(page), per_page: '25' })
      activeQuery().forEach((value, key) => params.set(key, value))

      const attRes = await requestApi('get', `/organizer/events/${id}/attendees?${params}`)
      if (!canApply()) return

      const data = attRes.data.attendees || attRes.data
      setAttendees(Array.isArray(data) ? data : [])
      setMeta(attRes.data.meta || null)
    } catch (err) {
      if (!canApply()) return
      if (err.response?.status === 401) setError('Please sign in.')
      else if (err.response?.status === 404) setError('Event not found.')
      else setError('Failed to load attendees.')
    } finally {
      if (canApply()) setLoading(false)
    }
  }, [id, page, activeQuery, requestApi, current, identity.organizationId, withdrawAccess])

  useEffect(() => { fetchAttendees() }, [fetchAttendees, loadAttempt])

  const refreshRecentExports = useCallback(async () => {
    try {
      const result = await requestOutsideList(config => apiClient.get(`/organizer/events/${id}/sales_exports`, config), { withdrawOnlyForSignIn: true })
      if (current()) setRecentExports(result.data?.exports || [])
    } catch { if (current()) setRecentExports([]) }
  }, [id, requestOutsideList, current])

  useEffect(() => { if (event && !accessDenied.current) refreshRecentExports() }, [event, refreshRecentExports])

  const downloadExport = async () => {
    if (exporting) return
    setExporting(true); setExportError(null)
    try {
      const response = await requestExport(allowedExportColumns)
      if (response.status === 202) {
        const payload = JSON.parse(await response.data.text())
        setQueuedExport(payload.download_url)
        refreshRecentExports()
        setExportOpen(false)
        return
      }
      saveBlob(response.data, `${event?.slug || `event-${id}`}-attendees.csv`)
      setExportOpen(false)
    } catch (exportFailure) {
      if (exportFailure?.name !== 'AbortError' && current()) setExportError(await exportFailureMessage(exportFailure, 'Unable to export attendees. Try again when your connection is available.'))
    } finally { if (current()) setExporting(false) }
  }
  const checkQueuedExport = async (downloadUrl = queuedExport) => {
    if (!downloadUrl || exporting) return
    setExporting(true); setExportError(null)
    try {
      const response = await requestOutsideList(config => apiClient.get(downloadUrl.replace('/api/v1', ''), { responseType: 'blob', ...config }))
      if (response.status === 202) { setActionNotice('Your export is still being prepared. Check again shortly.'); refreshRecentExports(); return }
      saveBlob(response.data, `${event?.slug || `event-${id}`}-sales.csv`)
      setQueuedExport(null)
      refreshRecentExports()
    } catch (error) {
      if (current() && error.response?.status === 422) {
        setQueuedExport(null)
        setExportError('This export failed — run it again')
        refreshRecentExports()
      } else if (current()) setExportError(await exportFailureMessage(error, 'The export could not be downloaded. Try again shortly.'))
    }
    finally { if (current()) setExporting(false) }
  }

  // Resend reuses the shared fulfillment resender: the order's ticket email goes
  // to the buyer, with the same two-minute cooldown buyers get.
  const confirmResend = async () => {
    if (!resendTarget || resending) return
    setResending(true); setResendError(null)
    try {
      const response = await requestOutsideList(config => apiClient.post(`/organizer/events/${id}/attendees/${resendTarget.id}/resend`, {}, config), { withdrawOnlyForSignIn: true })
      if (!current()) return
      setActionNotice(`Ticket email for ${resendTarget.attendee_name || 'this attendee'} is on its way to ${response.data?.recipient || 'the buyer'}.`)
      setResendTarget(null)
    } catch (resendFailure) {
      if (resendFailure?.name === 'AbortError' || !current()) return
      if (resendFailure.response?.status === 401) { setResendTarget(null); return }
      const status = resendFailure.response?.status
      setResendError(resendFailure.response?.data?.error || (status === 403 ? 'Your access no longer includes resending tickets for this event.'
        : status === 404 ? 'This attendee was not found. Refresh the list and try again.' : 'The ticket email could not be resent. Check your connection and try again.'))
    } finally { if (current()) setResending(false) }
  }
  const openResend = attendee => { setActionNotice(null); setResendError(null); setResendTarget(attendee) }

  const permissions = event?.permissions || {}
  const canCheckIn = attendee => filter('view') !== 'orders' && permissions.scan === true && event?.status === 'published' && attendee.status === 'issued' && (!attendee.sales_status || attendee.sales_status === 'issued')
  const canResend = attendee => filter('view') !== 'orders' && permissions.manage_attendees === true && RESENDABLE_STATUSES.has(attendee.status) && !['refunded', 'cancelled'].includes(attendee.sales_status)
  const showActions = filter('view') !== 'orders' && (permissions.scan === true || permissions.manage_attendees === true)
  // Check-in hands off to the scanner, which runs the ticket lookup but leaves
  // Admit to staff so the admission uses the device's signed ticket list, the
  // offline-safe queue and Undo, exactly like a scanned QR code.
  const checkInPath = attendee => `/dashboard/scanner?event=${encodeURIComponent(id)}&lookup=HP-T${attendee.id}`
  const rowActions = (attendee, size) => {
    const buttonSize = size === 'phone' ? 'min-h-11 flex-1 justify-center !px-3 !py-2' : 'min-h-9 !px-2.5 !py-1.5'
    const name = attendee.attendee_name || 'attendee'
    return <>
      {canCheckIn(attendee) && <Link to={checkInPath(attendee)} aria-label={`Check in ${name}`} className={`btn-secondary gap-1.5 whitespace-nowrap text-sm ${buttonSize}`}><ScanLine aria-hidden="true" className="h-4 w-4" /> Check in</Link>}
      {canResend(attendee) && <button type="button" onClick={() => openResend(attendee)} disabled={resending} aria-label={`Resend ticket to ${name}`} className={`btn-ghost gap-1.5 whitespace-nowrap text-sm ${buttonSize}`}><Mail aria-hidden="true" className="h-4 w-4" /> Resend</button>}
    </>
  }

  const visibleError = detailError || error
  const totalCount = Number.isInteger(meta?.total_count) ? meta.total_count : attendees.length
  const ticketTypes = event?.ticket_types || []
  const totalPages = meta?.total_pages || 1
  const activeFilters = filterChips(searchParams, ticketTypes)
  const removeChip = keys => setSearchParams(previous => {
    const next = new URLSearchParams(previous)
    keys.forEach(key => next.delete(key))
    next.delete('page')
    return next
  }, { replace: true })
  const canExport = permissions.view_attendees === true || permissions.view_finance === true
  const canSeeFinance = permissions.view_finance === true
  const financeColumns = ['ticket_price', 'discount', 'fee', 'tax', 'total_paid']
  const attendeeColumns = ['name', 'email', 'phone', 'check_in_time', 'transferred_to', 'notes_custom_answers']
  const allowedExportColumns = exportColumns.filter(key => (canSeeFinance || !financeColumns.includes(key)) && (permissions.view_attendees === true || !attendeeColumns.includes(key)))
  const exportChoices = [
    ['name', 'Name'], ['email', 'Email'], ['phone', 'Phone'], ['order_number', 'Order #'],
    ['ticket_type', 'Ticket type'], ['ticket_price', 'Ticket price'], ['discount', 'Discount'],
    ['fee', 'Fee'], ['tax', 'Tax'], ['total_paid', 'Total paid'], ['channel', 'Channel'], ['status', 'Status'],
    ['check_in_time', 'Check-in time'], ['transferred_to', 'Transferred to'],
    ['purchase_date', 'Purchase date'], ['notes_custom_answers', 'Registration answers']
  ].filter(([key]) => (canSeeFinance || !financeColumns.includes(key)) && (permissions.view_attendees === true || !attendeeColumns.includes(key)))

  return (
    <EventWorkspace eventId={id} event={event}><div className="max-w-4xl mx-auto">

      <div className="mb-6 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <div className="min-w-0">
          <h2 className="text-2xl font-bold text-neutral-900 mb-1">{filter('view') === 'orders' ? 'Sales orders' : 'Attendees'}</h2>
          {event && <p className="text-neutral-600 break-words">{event.title}</p>}
          {!loading && !(visibleError && attendees.length === 0) && <p role="status" className="mt-1 text-sm font-medium text-neutral-700 tabular-nums">{pluralize(totalCount, filter('view') === 'orders' ? 'order' : 'attendee')}{activeFilters.length ? ' match these filters' : ''}</p>}
        </div>
        {event && <div className="flex flex-wrap items-center gap-2">
          <button type="button" onClick={() => setFiltersOpen(true)} className="btn-secondary min-h-11 gap-1.5 !px-4 !py-2.5 text-sm"><SlidersHorizontal className="h-4 w-4" /> Filters & sort</button>
          {canExport && <button type="button" onClick={() => setExportOpen(true)} className="btn-secondary min-h-11 gap-1.5 !px-4 !py-2.5 text-sm"><Download className="h-4 w-4" /> Export this list</button>}
          {permissions.view_attendees === true && <button type="button" onClick={async () => { try { const response = await requestOutsideList(config => apiClient.get(`/organizer/events/${id}/sales_exports/door_list?${activeQuery()}`, { responseType: 'blob', ...config })); saveBlob(response.data, `${event?.slug || `event-${id}`}-door-list.pdf`) } catch (error) { if (current()) setExportError(await exportFailureMessage(error, 'Unable to prepare the door list.')) } }} className="btn-secondary min-h-11 gap-1.5 !px-4 !py-2.5 text-sm"><Printer className="h-4 w-4" /> Print door list</button>}
        </div>}
      </div>
      {activeFilters.length > 0 && <div role="region" className="mb-4 flex flex-wrap items-center gap-2" aria-label="Active filters">{activeFilters.map(({ keys, label }) => <button key={keys.join('-')} type="button" onClick={() => removeChip(keys)} className="rounded-full bg-brand-50 px-3 py-1 text-sm text-brand-900">{label} ×</button>)}<button type="button" className="text-sm font-medium underline" onClick={() => setSearchParams(new URLSearchParams(), { replace: true })}>Clear filters</button></div>}
      {queuedExport && <p role="status" className="mb-4 rounded-lg bg-brand-50 p-3 text-sm">Your export is being prepared. <button type="button" className="underline" onClick={() => checkQueuedExport()} disabled={exporting}>Check download</button></p>}
      {recentExports.length > 0 && <section aria-label="Recent exports" className="mb-4 rounded-lg border border-neutral-200 bg-white p-4"><h2 className="font-semibold">Recent exports</h2><ul className="mt-2 space-y-2 text-sm">{recentExports.map(item => <li key={item.id} className="flex flex-wrap items-center justify-between gap-2"><span>Export #{item.id} · {item.row_count} rows · {item.status === 'failed' ? 'This export failed — run it again' : item.status}</span>{['pending', 'processing', 'ready'].includes(item.status) && <button type="button" className="underline" disabled={exporting} onClick={() => checkQueuedExport(item.download_url)}>{item.status === 'ready' ? 'Download' : 'Check status'}</button>}{item.status === 'failed' && <button type="button" className="underline" onClick={() => { setExportError(null); setExportOpen(true) }}>Run again</button>}</li>)}</ul></section>}
      {exportOpen && <Dialog labelledBy="sales-export-title" onClose={() => setExportOpen(false)} busy={exporting} className="max-w-lg"><h3 id="sales-export-title" className="text-lg font-semibold">Export this list</h3><p className="mt-2 text-sm text-neutral-600">{pluralize(totalCount, filter('view') === 'orders' ? 'order' : 'attendee')} match the current filters. Choose the columns to share.</p><div className="mt-4 grid grid-cols-2 gap-2">{exportChoices.map(([key, label]) => <label key={key} className="flex items-center gap-2 text-sm"><input type="checkbox" checked={exportColumns.includes(key)} onChange={event => setExportColumns(previous => event.target.checked ? [...previous, key] : previous.filter(column => column !== key))} />{label}</label>)}</div><div className="mt-5 flex justify-end gap-2"><button type="button" className="btn-secondary" onClick={() => setExportOpen(false)}>Cancel</button><button type="button" className="btn-primary" disabled={exporting || !allowedExportColumns.length} onClick={downloadExport}>{exporting ? 'Preparing…' : 'Download CSV'}</button></div></Dialog>}
      {filtersOpen && <Dialog labelledBy="sales-filters-title" onClose={() => setFiltersOpen(false)} className="max-w-lg"><h3 id="sales-filters-title" className="text-lg font-semibold">Filters & sort</h3><div className="mt-4 grid gap-3 max-h-[60vh] overflow-y-auto">
        <label className="text-sm">View<select aria-label="View sales as" value={filter('view') || 'tickets'} onChange={e => changeFilter('view', e.target.value)} className="input mt-1"><option value="tickets">Tickets / attendees</option><option value="orders">Orders</option></select></label>
        <label className="text-sm">Status<select aria-label="Filter attendees by status" value={statusFilter} onChange={e => changeFilter('status', e.target.value)} className="input mt-1"><option value="">All statuses</option>{Object.entries(STATUS_LABELS).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
        <label className="text-sm">Ticket type<select aria-label="Filter attendees by ticket type" value={ticketTypeFilter} onChange={e => changeFilter('ticket_type', e.target.value)} className="input mt-1"><option value="">All ticket types</option>{ticketTypes.map(type => <option key={type.id} value={type.id}>{type.name}</option>)}</select></label>
        <label className="text-sm">Sales channel<select aria-label="Sales channel" value={filter('channel')} onChange={e => changeFilter('channel', e.target.value)} className="input mt-1"><option value="">All channels</option><option value="online">Online</option><option value="box_office">Box office</option><option value="guest_list">Comp / guest list</option></select></label>
        <label className="text-sm">Promo code<input aria-label="Promo code" value={filter('promo_code')} onChange={e => changeFilter('promo_code', e.target.value)} className="input mt-1" /></label>
        <label className="text-sm">Purchased from<input type="date" aria-label="Purchased from" value={filter('purchased_from')} onChange={e => changeFilter('purchased_from', e.target.value)} className="input mt-1" /></label>
        <label className="text-sm">Purchased to<input type="date" aria-label="Purchased to" value={filter('purchased_to')} onChange={e => changeFilter('purchased_to', e.target.value)} className="input mt-1" /></label>
        <label className="text-sm">Payment environment<select aria-label="Payment environment" value={filter('payment_environment') || 'live'} onChange={e => changeFilter('payment_environment', e.target.value)} className="input mt-1"><option value="live">Live only</option><option value="test">Test only</option><option value="all">Live and test</option></select></label>
        <label className="text-sm">Sort by<select aria-label="Sort by" value={filter('sort') || 'purchase_date'} onChange={e => changeFilter('sort', e.target.value)} className="input mt-1">{[['purchase_date','Purchase date'], ...(permissions.view_attendees === true ? [['name','Name']] : []), ['ticket_type','Ticket type'],['amount','Amount'],['check_in_time','Check-in time']].map(([value,label]) => <option key={value} value={value}>{label}</option>)}</select></label>
        <label className="text-sm">Direction<select aria-label="Sort direction" value={filter('direction') || 'desc'} onChange={e => changeFilter('direction', e.target.value)} className="input mt-1"><option value="desc">Descending</option><option value="asc">Ascending</option></select></label>
      </div><div className="mt-4 flex justify-between"><button type="button" className="btn-ghost" onClick={() => setSearchParams(new URLSearchParams(), { replace: true })}>Clear filters</button><button type="button" className="btn-primary" onClick={() => setFiltersOpen(false)}>Show results</button></div></Dialog>}
      {exportError && <p role="alert" className="mb-4 rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-700">{exportError}{exportError === 'This export failed — run it again' && <> <button type="button" className="underline" onClick={() => { setExportError(null); setExportOpen(true) }}>Run again</button></>}</p>}
      {actionNotice && <p role="status" className="mb-4 break-words rounded-xl border border-brand-200 bg-brand-50 p-3 text-sm text-brand-900">{actionNotice}</p>}
      {resendTarget && <Dialog labelledBy="attendee-resend-title" onClose={() => setResendTarget(null)} busy={resending} className="max-w-md">
        <h3 id="attendee-resend-title" className="text-lg font-semibold text-neutral-950">Resend ticket email?</h3>
        <p className="mt-3 break-words text-sm text-neutral-700">We'll email the tickets on {resendTarget.attendee_name || 'this attendee'}'s order again, to the buyer's email address on that order. Each order can be resent once every two minutes.</p>
        {resendError && <p role="alert" className="mt-3 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-700">{resendError}</p>}
        <div className="mt-5 flex flex-wrap justify-end gap-3">
          <button type="button" className="btn-secondary" disabled={resending} onClick={() => setResendTarget(null)}>Cancel</button>
          <button type="button" className="btn-primary gap-1.5" disabled={resending} onClick={confirmResend}>{resending ? <><Loader2 aria-hidden="true" className="h-4 w-4 animate-spin" /> Sending…</> : 'Resend ticket'}</button>
        </div>
      </Dialog>}

      {visibleError && (
        <div role="alert" className="mb-6 p-4 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm"><p>{visibleError}</p><button type="button" className="min-h-11 font-semibold underline" onClick={() => setLoadAttempt(value => value + 1)}>Retry attendee list</button></div>
      )}

      {/* Filters */}
      <div className="flex flex-col sm:flex-row gap-3 mb-6">
        <div className="relative flex-1">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-neutral-400" />
          <input
            type="text"
            value={search}
            onChange={(e) => changeFilter('search', e.target.value)}
            placeholder={permissions.view_attendees === true ? 'Search name, email or order #...' : 'Search by order #'}
            aria-label={permissions.view_attendees === true ? 'Search attendees by name, email or order number' : 'Search by order #'}
            className="input pl-9"
          />
        </div>
      </div>

      {loading ? (
        <div className="flex justify-center py-12"><Loader2 className="w-8 h-8 text-brand-500 animate-spin" /></div>
      ) : visibleError && attendees.length === 0 ? null : attendees.length === 0 ? (
        <div className="bg-white rounded-xl shadow-sm border border-neutral-200 p-12 text-center">
          <p className="text-neutral-500">No {filter('view') === 'orders' ? 'orders' : 'attendees'} match these filters.</p>
          {activeFilters.length > 0 && <button type="button" className="mt-3 font-medium underline" onClick={() => setSearchParams(new URLSearchParams(), { replace: true })}>Clear filters</button>}
        </div>
      ) : (
        <>
          {/* Desktop table */}
          <div className="hidden sm:block bg-white rounded-xl shadow-sm border border-neutral-200 overflow-x-auto">
            <table className="w-full">
              <thead>
                <tr className="bg-neutral-50">
                  <th className="text-left px-4 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Name</th>
                  <th className="text-left px-4 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Email</th>
                  <th className="text-left px-4 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Ticket Type</th>
                  {filter('view') === 'orders' && <th className="text-left px-4 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Purchased</th>}
                  {filter('view') === 'orders' && canSeeFinance && <th className="text-right px-4 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Amount</th>}
                  <th className="text-left px-4 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Status</th>
                  <th className="text-left px-4 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Checked In</th>
                  {showActions && <th className="text-right px-4 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Actions</th>}
                </tr>
              </thead>
              <tbody className="divide-y divide-neutral-200">
                {attendees.map((att) => {
                  const style = STATUS_STYLES[att.sales_status || att.status] || { label: STATUS_LABELS[att.sales_status || att.status] || (att.sales_status || att.status).replaceAll('_', ' '), className: 'bg-neutral-100 text-neutral-800' }
                  return (
                    <tr key={att.id}>
                      <td className="min-w-32 px-4 py-3 text-sm font-medium text-neutral-900">{att.attendee_name || '—'}<TestPaymentBadge order={att} />{att.order_number && <span className="block text-xs font-normal text-neutral-500">{att.order_number}</span>}</td>
                      <td className="max-w-56 break-words px-4 py-3 text-sm text-neutral-600">{att.attendee_email || '—'}</td>
                      <td className="px-4 py-3 text-sm text-neutral-600">{att.ticket_type}</td>
                      {filter('view') === 'orders' && <td className="px-4 py-3 text-sm text-neutral-600">{formatDate(att.purchase_date, event?.timezone)}</td>}
                      {filter('view') === 'orders' && canSeeFinance && <td className="px-4 py-3 text-right text-sm text-neutral-900 tabular-nums">{att.amount_cents == null ? '—' : `$${(att.amount_cents / 100).toFixed(2)}`}</td>}
                      <td className="px-4 py-3"><span className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-medium ${style.className}`}>{att.sales_status_label || style.label}</span></td>
                      <td className="px-4 py-3 text-sm text-neutral-500">{filter('view') === 'orders' ? `${att.checked_in_count || 0}/${att.ticket_count || 0}` : formatDate(att.checked_in_at, event?.timezone)}</td>
                      {/* Stacked until 2xl so the actions stay in view beside the event sidebar at 1280. */}
                      {showActions && <td className="px-4 py-3"><div className="flex flex-col items-stretch gap-1.5 2xl:flex-row 2xl:justify-end">{rowActions(att, 'desktop')}</div></td>}
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>

          {/* Mobile cards */}
          <div className="sm:hidden space-y-2">
            {attendees.map((att) => {
              const style = STATUS_STYLES[att.sales_status || att.status] || { label: STATUS_LABELS[att.sales_status || att.status] || (att.sales_status || att.status).replaceAll('_', ' '), className: 'bg-neutral-100 text-neutral-800' }
              return (
                <div key={att.id} className="bg-white rounded-xl border border-neutral-200 p-4">
                  <div className="flex items-center justify-between">
                    <span className="text-sm font-medium text-neutral-900">{att.attendee_name || '—'}<TestPaymentBadge order={att} /></span>
                    <span className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-medium ${style.className}`}>{att.sales_status_label || style.label}</span>
                  </div>
                  <p className="text-xs text-neutral-500 mt-1 break-all">{att.attendee_email || '—'}</p>
                  {att.order_number && <p className="text-xs text-neutral-500 mt-1">{att.order_number}{canSeeFinance && att.amount_cents != null ? ` · $${(att.amount_cents / 100).toFixed(2)}` : ''}</p>}
                  {att.purchase_date && <p className="text-xs text-neutral-500 mt-1">Purchased {formatDate(att.purchase_date, event?.timezone)}</p>}
                  <div className="flex justify-between mt-1">
                    <span className="text-xs text-neutral-600">{att.ticket_type}</span>
                    {filter('view') === 'orders' ? <span className="text-xs text-neutral-600">{att.checked_in_count || 0}/{att.ticket_count || 0} checked in</span> : att.checked_in_at && <span className="text-xs text-neutral-600">{formatDate(att.checked_in_at, event?.timezone)}</span>}
                  </div>
                  {(canCheckIn(att) || canResend(att)) && <div className="mt-3 flex gap-2">{rowActions(att, 'phone')}</div>}
                </div>
              )
            })}
          </div>

          {/* Pagination */}
          {totalPages > 1 && (
            <div className="flex items-center justify-center gap-4 mt-6">
              <button onClick={() => setPage(p => Math.max(1, p - 1))} disabled={page <= 1} className="p-2 text-neutral-500 hover:text-neutral-700 disabled:opacity-30">
                <ChevronLeft className="w-5 h-5" />
              </button>
              <span className="text-sm text-neutral-600">Page {page} of {totalPages}</span>
              <button onClick={() => setPage(p => Math.min(totalPages, p + 1))} disabled={page >= totalPages} className="p-2 text-neutral-500 hover:text-neutral-700 disabled:opacity-30">
                <ChevronRight className="w-5 h-5" />
              </button>
            </div>
          )}
        </>
      )}
    </div></EventWorkspace>
  )
}
