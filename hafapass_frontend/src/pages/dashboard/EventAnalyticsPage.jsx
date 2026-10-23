import { payoutAccountLabel, payoutProviderLabel } from '../../utils/payoutLabels'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import EventWorkspace from '../../components/EventWorkspace'
import { CheckCircle2, CircleAlert, Download, Loader2, WalletCards } from 'lucide-react'
import { useState, useEffect, useCallback, useRef } from 'react'
import { useParams, Link } from 'react-router-dom'
import apiClient from '../../api/client'
import TestPaymentBadge from '../../components/TestPaymentBadge'
import FeeTermsNote from '../../components/FeeTermsNote'
import usePlatformFeeTerms from '../../hooks/usePlatformFeeTerms'
import EventSalesInsights from './EventSalesInsights'
import { saveBlob } from '../../utils/download'

function formatCents(cents) {
 const safe = Number.isFinite(cents) ? cents : 0
 return `$${(safe / 100).toFixed(2)}`
}

function formatDate(isoString) {
 if (!isoString) return ''
 return new Date(isoString).toLocaleString('en-US', {
  month: 'short',
  day: 'numeric',
  year: 'numeric',
  hour: 'numeric',
  minute: '2-digit'
 })
}

export default function EventAnalyticsPage() {
 const { id } = useParams()
 const identity = useOrganizerIdentity()
 const visit = useOrganizerPageVisit(`/dashboard/events/${id}/analytics`)
 if (!visit.active) return null
 if (!identity.ready) return <p role="status" className="p-6">Preparing your account…</p>
 return <EventAnalyticsPageSession key={`${identity.accountKey}:${identity.organizationId}:${id}:${visit.generation}`} id={id} identity={identity} />
}

function EventAnalyticsPageSession({ id, identity }) {
 const { current, beginRequest } = useOrganizerRequests(identity, `/dashboard/events/${id}/analytics`)
 const [loading, setLoading] = useState(true)
 const [error, setError] = useState(null)
 const [stats, setStats] = useState(null)
 const [event, setEvent] = useState(null)
 const [finance, setFinance] = useState(null)
 const [financeBusy, setFinanceBusy] = useState(false)
 const [payoutNotice, setPayoutNotice] = useState('')
 const [exporting, setExporting] = useState(null)
 const [exportError, setExportError] = useState(null)
 const [statementChoice, setStatementChoice] = useState('')
 const feeTerms = usePlatformFeeTerms()
 const loadGeneration = useRef(0)
 const accessEpoch = useRef(0)
 const verifiedRights = useRef(null)
 const requests = useRef(new Set())
 const permissions = event?.permissions || {}

 const withdrawAccess = useCallback(message => {
  ++accessEpoch.current
  verifiedRights.current = null
  requests.current.forEach(request => request.controller.abort())
  setStats(null); setFinance(null); setEvent(null)
  setFinanceBusy(false); setPayoutNotice(''); setLoading(false)
  setError(message)
 }, [])
 const requestApi = useCallback(async (method, url, payload, options = {}) => {
  const verifyingEvent = method === 'get' && url === `/organizer/events/${id}`
  const permission = url.endsWith('/finalize') ? 'manage_finance' : url.endsWith('/payout') ? 'payout' : 'view_finance'
  if (!verifyingEvent && verifiedRights.current?.[permission] !== true) throw new DOMException('Analytics access is not verified', 'AbortError')
  const request = beginRequest()
  if (!request) throw new DOMException('Page context changed', 'AbortError')
  const epoch = accessEpoch.current
  requests.current.add(request)
  try {
   const response = method === 'get'
    ? await apiClient.get(url, { ...payload, ...request.config })
    : await apiClient[method](url, payload, { ...options, ...request.config })
   if (!request.current() || epoch !== accessEpoch.current) throw new DOMException('Analytics access changed', 'AbortError')
   return response
  } catch (requestError) {
   if (request.current() && epoch === accessEpoch.current && ([401, 403].includes(requestError.response?.status) || (verifyingEvent && requestError.response?.status === 404))) {
    withdrawAccess(requestError.response.status === 401 ? 'Please sign in to verify your analytics access.'
     : requestError.response.status === 404 ? 'Event not found.'
      : 'Your event access changed. Analytics and finance actions are paused. Retry to verify your current permissions.')
   }
   throw requestError
  } finally { requests.current.delete(request); request.release() }
 }, [id, beginRequest, withdrawAccess])

 const fetchData = useCallback(async () => {
  if (!current()) return
  const generation = ++loadGeneration.current
  withdrawAccess(null)
  const epoch = accessEpoch.current
  const canApply = () => current() && generation === loadGeneration.current && epoch === accessEpoch.current
  setLoading(true)
  try {
   // The event permission map is authoritative. Do not request private finance
   // or buyer records until this exact event and organization are verified.
   const eventRes = await requestApi('get', `/organizer/events/${id}`)
   if (!canApply()) return
   const saved = eventRes.data
   if (String(saved.id) !== String(id) || saved.organization_id == null || (identity.organizationId != null && String(saved.organization_id) !== String(identity.organizationId))) {
    withdrawAccess('The event context could not be verified. Return to your dashboard and select the event again.')
    return
   }
   if (saved.permissions?.view_finance !== true) {
    withdrawAccess('Your event access does not include analytics and finances.')
    return
   }
   verifiedRights.current = saved.permissions
   const [statsRes, financeRes] = await Promise.all([
    requestApi('get', `/organizer/events/${id}/stats`),
    requestApi('get', `/organizer/events/${id}/finance`),
   ])
   if (!canApply()) return
   setEvent(saved); setStats(statsRes.data); setFinance(financeRes.data)
  } catch {
   if (!canApply()) return
   withdrawAccess('Failed to load analytics. Retry to verify access and load the current records.')
  } finally { if (canApply()) setLoading(false) }
 }, [id, identity.organizationId, requestApi, current, withdrawAccess])
 useEffect(() => { fetchData() }, [fetchData])
 // The organization finances page links straight to this event's settlement.
 const settlementReady = Boolean(finance)
 useEffect(() => {
  if (!settlementReady || window.location.hash !== '#settlement') return
  const target = document.getElementById('settlement')
  if (!target) return
  const reduce = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches
  target.scrollIntoView?.({ behavior: reduce ? 'auto' : 'smooth', block: 'start' })
 }, [settlementReady])

 // CSV exports come from the API, which owns the money math and the
 // spreadsheet-safe formatting.
 const downloadExport = async (kind, path, filename) => {
  if (exporting) return
  const epoch = accessEpoch.current
  const canApply = () => current() && epoch === accessEpoch.current
  setExporting(kind); setExportError(null)
  try {
   const response = await requestApi('get', path, { responseType: 'blob' })
   if (canApply()) saveBlob(response.data, filename)
  } catch (exportFailure) {
   if (exportFailure?.name !== 'AbortError' && canApply()) setExportError('That export could not be downloaded. Check your connection and try again.')
  } finally { if (canApply()) setExporting(null) }
 }

 const refreshFinance = async () => {
  const epoch = accessEpoch.current
  const response = await requestApi('get', `/organizer/events/${id}/finance`)
  if (current() && epoch === accessEpoch.current) setFinance(response.data)
 }
 const finalizeSettlement = async () => {
  if (!current() || verifiedRights.current?.manage_finance !== true || financeBusy) return
  const epoch = accessEpoch.current
  const canApply = () => current() && epoch === accessEpoch.current
  setFinanceBusy(true); setError(null); setPayoutNotice('')
  try {
   await requestApi('post', `/organizer/events/${id}/finance/finalize`)
   if (canApply()) await refreshFinance()
  } catch (requestError) { if (canApply()) setError(requestError.response?.data?.error || 'Could not finalize this statement.') }
  finally { if (canApply()) setFinanceBusy(false) }
 }
 const createPayout = async settlement => {
  if (!current() || verifiedRights.current?.payout !== true || financeBusy) return
  if (!window.confirm(`Request a payout of ${formatCents(settlement.available_to_payout_cents)}? A processing request is not confirmation that money has been sent.`)) return
  const epoch = accessEpoch.current
  const canApply = () => current() && epoch === accessEpoch.current
  setFinanceBusy(true); setError(null); setPayoutNotice('')
  try {
   const response = await requestApi('post', `/organizer/events/${id}/finance/payout`, {
    settlement_id: settlement.id,
    amount_cents: settlement.available_to_payout_cents,
   }, { headers: { 'Idempotency-Key': crypto.randomUUID() } })
   if (canApply()) {
    setPayoutNotice(response.data?.status === 'paid' ? 'Payout recorded as paid.' : 'Payout requested. Processing does not confirm that money has been sent.')
    await refreshFinance()
   }
  } catch (requestError) { if (canApply()) setError(requestError.response?.data?.error || 'Could not create payout.') }
  finally { if (canApply()) setFinanceBusy(false) }
 }

 if (loading) {
  return (
   <div className="flex justify-center items-center py-20">
    <Loader2 className="w-8 h-8 text-brand-500 animate-spin" />
   </div>
  )
 }

 if (error && !stats) {
  return (
   <div className="max-w-4xl mx-auto">
    <div role="alert" className="p-4 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm">
     {error}
     <button type="button" onClick={fetchData} className="ml-3 min-h-11 font-semibold underline">Retry analytics</button>
    </div>
    <Link to="/dashboard" className="mt-4 inline-flex min-h-11 items-center rounded text-brand-700 hover:text-brand-900 text-sm font-medium">
     Back to Dashboard
    </Link>
   </div>
  )
 }

 const totalTickets = (stats.tickets_by_type || []).reduce((sum, t) => sum + t.sold + t.available, 0)
 const checkInRate = stats.total_tickets_sold > 0
  ? Math.round((stats.tickets_checked_in / stats.total_tickets_sold) * 100)
  : 0
 const latestSettlement = finance?.settlements?.[0]
 const currency = (finance?.preview?.currency || 'usd').toUpperCase()
 const exportName = event?.slug || `event-${id}`
 const statementValue = statementChoice || (latestSettlement ? String(latestSettlement.id) : 'current')
 const statementLabel = statementValue === 'current' ? 'current' : `v${finance?.settlements?.find(item => String(item.id) === statementValue)?.version ?? ''}`

 return (
  <EventWorkspace eventId={id} event={event}><div className="max-w-4xl mx-auto">
   {/* Header */}

   <h2 className="text-2xl font-bold text-neutral-900 mb-1">Event Analytics</h2>
   {event && (
    <p className="text-neutral-600 mb-6">{event.title}</p>
   )}

   {error && (
    <div className="mb-6 p-4 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm">
     {error}
     <button type="button" onClick={fetchData} className="ml-3 min-h-11 font-semibold underline">Retry analytics</button>
    </div>
   )}

   {/* Summary Cards */}
   <div className="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-8">
    <div className="bg-white rounded-xl shadow-sm border border-neutral-200 p-5">
     <div className="flex items-center gap-3">
      <div className="w-10 h-10 bg-brand-100 rounded-xl flex items-center justify-center">
       <svg className="w-5 h-5 text-brand-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 5v2m0 4v2m0 4v2M5 5a2 2 0 00-2 2v3a2 2 0 110 4v3a2 2 0 002 2h14a2 2 0 002-2v-3a2 2 0 110-4V7a2 2 0 00-2-2H5z" />
       </svg>
      </div>
      <div>
       <p className="text-sm text-neutral-500">Tickets Sold</p>
       <p className="text-2xl font-bold text-neutral-900">{stats.total_tickets_sold}</p>
       {totalTickets > 0 && (
        <p className="text-xs text-neutral-400">of {totalTickets} total</p>
       )}
      </div>
     </div>
    </div>

    <div className="bg-white rounded-xl shadow-sm border border-neutral-200 p-5">
     <div className="flex items-center gap-3">
      <div className="w-10 h-10 bg-green-100 rounded-xl flex items-center justify-center">
       <svg className="w-5 h-5 text-green-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 8c-1.657 0-3 .895-3 2s1.343 2 3 2 3 .895 3 2-1.343 2-3 2m0-8c1.11 0 2.08.402 2.599 1M12 8V7m0 1v8m0 0v1m0-1c-1.11 0-2.08-.402-2.599-1M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
       </svg>
      </div>
      <div>
       <p className="text-sm text-neutral-500">Total Revenue</p>
       <p className="text-2xl font-bold text-neutral-900">{formatCents(stats.total_revenue_cents)}</p>
      </div>
     </div>
    </div>

    <div className="bg-white rounded-xl shadow-sm border border-neutral-200 p-5">
     <div className="flex items-center gap-3">
      <div className="w-10 h-10 bg-purple-100 rounded-xl flex items-center justify-center">
       <svg className="w-5 h-5 text-purple-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
       </svg>
      </div>
      <div>
       <p className="text-sm text-neutral-500">Check-in Rate</p>
       <p className="text-2xl font-bold text-neutral-900">{checkInRate}%</p>
       <p className="text-xs text-neutral-400">{stats.tickets_checked_in} checked in</p>
      </div>
     </div>
    </div>
   </div>

   {/* Settlement and payout ledger */}
   {finance && (
    <section id="settlement" className="mb-8 scroll-mt-24 rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6" aria-labelledby="finance-heading">
     <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
      <div className="flex items-start gap-3">
       <div className="rounded-xl bg-emerald-50 p-2.5"><WalletCards className="h-5 w-5 text-emerald-700" /></div>
       <div><h2 id="finance-heading" className="text-lg font-semibold text-neutral-900">Settlement and payout</h2><p className="mt-1 text-sm text-neutral-500">Built from recorded sales, refunds, processing costs, disputes, reserves, adjustments, and payouts. Past records are never changed.</p></div>
      </div>
      {finance.connected_account?.payout_ready ? (
       <span className="inline-flex items-center gap-1.5 text-xs font-semibold text-emerald-700"><CheckCircle2 className="h-4 w-4" /> {payoutAccountLabel(finance.connected_account)}</span>
      ) : (
       <Link to="/dashboard/settings" className="inline-flex items-center gap-1.5 text-xs font-semibold text-amber-700"><CircleAlert className="h-4 w-4" /> Complete payout setup</Link>
      )}
     </div>

     <div className="mt-5 grid grid-cols-2 gap-3 sm:grid-cols-4">
      <div className="rounded-xl bg-neutral-50 p-3"><p className="text-xs text-neutral-500">Gross ticket value</p><p className="mt-1 font-bold text-neutral-900">{formatCents(finance.preview.gross_cents)}</p></div>
      <div className="rounded-xl bg-neutral-50 p-3"><p className="text-xs text-neutral-500">Refunds</p><p className="mt-1 font-bold text-neutral-900">{formatCents(finance.preview.refund_cents)}</p></div>
      <div className="rounded-xl bg-neutral-50 p-3"><p className="text-xs text-neutral-500">Processing costs to you</p><p className="mt-1 font-bold text-neutral-900">{formatCents(finance.preview.processing_fee_cents)}</p>{finance.preview.platform_processing_fee_cents > 0 && <p className="mt-0.5 text-xs text-emerald-700">HåfaPass covered {formatCents(finance.preview.platform_processing_fee_cents)}</p>}</div>
      <div className="rounded-xl bg-brand-50 p-3"><p className="text-xs text-brand-700">Organizer payable</p><p className="mt-1 font-bold text-brand-900">{formatCents(finance.preview.payable_cents)}</p></div>
     </div>

     <FeeTermsNote className="mt-4" feeTerms={feeTerms} feePolicy={event?.fee_policy} buyerFeePercent={event?.buyer_fee_percent} />
     {feeTerms.terms?.bearer === 'platform' && finance.preview.processing_fee_cents > 0 && <p className="mt-2 text-sm text-neutral-600" data-testid="earlier-processing-note">{formatCents(finance.preview.processing_fee_cents)} in card processing is deducted from your proceeds. That covers orders placed under earlier terms, when card processing came out of organizer proceeds, and any add-ons or donations.</p>}

     {finance.preview.negative_balance_cents > 0 && <div className="mt-4 rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-700">A {formatCents(finance.preview.negative_balance_cents)} negative balance will be withheld from future organization payouts.</div>}
     {payoutNotice && <p role="status" className="mt-4 rounded-xl bg-neutral-50 p-3 text-sm text-neutral-700">{payoutNotice}</p>}

     <div className="mt-5 flex flex-wrap items-center gap-3 border-t border-neutral-100 pt-5">
      {permissions.manage_finance === true && ['completed', 'cancelled'].includes(event?.status) && <button disabled={financeBusy} onClick={finalizeSettlement} className="rounded-xl border border-brand-200 px-4 py-2 text-sm font-semibold text-brand-700 hover:bg-brand-50 disabled:opacity-50">{financeBusy ? 'Working…' : latestSettlement ? 'Finalize current version' : 'Finalize statement'}</button>}
      {permissions.payout === true && latestSettlement?.available_to_payout_cents > 0 && <button disabled={financeBusy || !finance.connected_account?.payout_ready} onClick={() => createPayout(latestSettlement)} className="btn-primary text-sm disabled:opacity-50">Request payout {formatCents(latestSettlement.available_to_payout_cents)}</button>}
      {latestSettlement && <p className="text-xs text-neutral-500">Version {latestSettlement.version} · {latestSettlement.status} · {formatCents(latestSettlement.available_to_payout_cents)} available</p>}
     </div>

     {finance.payouts?.length > 0 && <div className="mt-5 divide-y divide-neutral-100 rounded-xl border border-neutral-200">{finance.payouts.map(payout => <div key={payout.id} className="flex items-center justify-between px-4 py-3 text-sm"><span className="text-neutral-600">{payoutProviderLabel(payout.provider)} · {payout.status}</span><span className="font-semibold text-neutral-900">{formatCents(payout.amount_cents)}</span></div>)}</div>}

     <div className="mt-5 border-t border-neutral-100 pt-5">
      <h3 className="text-sm font-semibold text-neutral-900">Exports</h3>
      <p className="mt-1 text-sm text-neutral-600">Spreadsheet files for your records. The orders file lists every paid, refunded and complimentary order with fees, card processing and your proceeds.</p>
      <div className="mt-3 flex flex-col gap-3 sm:flex-row sm:flex-wrap sm:items-end">
       <button type="button" disabled={Boolean(exporting)} onClick={() => downloadExport('orders', `/organizer/events/${id}/finance/orders_export`, `${exportName}-orders.csv`)} className="btn-secondary gap-2 !px-4 !py-2.5 text-sm">
        {exporting === 'orders' ? <Loader2 aria-hidden="true" className="h-4 w-4 animate-spin" /> : <Download aria-hidden="true" className="h-4 w-4" />} Orders CSV
       </button>
       <div className="flex min-w-0 flex-col gap-2 sm:flex-row sm:items-end">
        <label className="flex min-w-0 flex-col gap-1 text-xs font-medium text-neutral-700">Statement
         <select value={statementValue} onChange={changeEvent => setStatementChoice(changeEvent.target.value)} className="input min-h-11 !py-2 text-sm sm:w-56">
          {(finance.settlements || []).map(item => <option key={item.id} value={String(item.id)}>Version {item.version} ({item.status})</option>)}
          <option value="current">Current, not finalized</option>
         </select>
        </label>
        <button type="button" disabled={Boolean(exporting)} onClick={() => downloadExport('statement', `/organizer/events/${id}/finance/statement_export?settlement_id=${encodeURIComponent(statementValue)}`, `${exportName}-statement-${statementLabel}.csv`)} className="btn-secondary gap-2 !px-4 !py-2.5 text-sm">
         {exporting === 'statement' ? <Loader2 aria-hidden="true" className="h-4 w-4 animate-spin" /> : <Download aria-hidden="true" className="h-4 w-4" />} Statement CSV
        </button>
       </div>
      </div>
      {exportError && <p role="alert" className="mt-3 rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-700">{exportError}</p>}
      <Link to={`/dashboard/events/${id}/attendees`} className="mt-3 mr-5 inline-flex min-h-11 items-center text-sm font-semibold text-brand-700 hover:text-brand-900">Export this list with filters</Link>
      <Link to="/dashboard/finances" className="mt-3 inline-flex min-h-11 items-center text-sm font-semibold text-brand-700 hover:text-brand-900">All events and payouts</Link>
     </div>
    </section>
   )}

   <EventSalesInsights stats={stats} currency={currency} />

   {/* Tickets by Type */}
   <div className="bg-white rounded-xl shadow-sm border border-neutral-200 mb-8">
    <div className="px-4 sm:px-5 py-4 border-b border-neutral-200">
     <h2 className="text-lg font-semibold text-neutral-900">Tickets by Type</h2>
    </div>
    <div className="overflow-x-auto">
     <table className="w-full">
      <thead>
       <tr className="bg-neutral-50">
        <th className="text-left px-3 sm:px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Type</th>
        <th className="text-right px-2 sm:px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Sold</th>
        <th className="text-right px-2 sm:px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Avail</th>
        <th className="text-right px-3 sm:px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Revenue</th>
       </tr>
      </thead>
      <tbody className="divide-y divide-neutral-200">
       {(stats.tickets_by_type || []).map((type, idx) => (
        <tr key={idx}>
         <td className="px-3 sm:px-5 py-3 text-sm font-medium text-neutral-900">{type.name}</td>
         <td className="px-2 sm:px-5 py-3 text-sm text-neutral-600 text-right">{type.sold}</td>
         <td className="px-2 sm:px-5 py-3 text-sm text-neutral-600 text-right">{type.available}</td>
         <td className="px-3 sm:px-5 py-3 text-sm text-neutral-900 text-right font-medium">{formatCents(type.revenue_cents)}</td>
        </tr>
       ))}
       {(stats.tickets_by_type || []).length === 0 && (
        <tr>
         <td colSpan={4} className="px-3 sm:px-5 py-4 text-sm text-neutral-500 text-center">No ticket types yet.</td>
        </tr>
       )}
      </tbody>
     </table>
    </div>
   </div>

   {/* Recent Orders */}
   <div className="bg-white rounded-xl shadow-sm border border-neutral-200 mb-8">
    <div className="px-5 py-4 border-b border-neutral-200">
     <h2 className="text-lg font-semibold text-neutral-900">Recent Orders</h2>
    </div>
    {(stats.recent_orders || []).length > 0 ? (
     <>
      {/* Desktop table */}
      <div className="hidden sm:block overflow-x-auto">
       <table className="w-full">
        <thead>
         <tr className="bg-neutral-50">
          <th className="text-left px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Buyer</th>
          <th className="text-left px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Email</th>
          <th className="text-right px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Tickets</th>
          <th className="text-right px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Total</th>
          <th className="text-right px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Date</th>
         </tr>
        </thead>
        <tbody className="divide-y divide-neutral-200">
         {(stats.recent_orders || []).map((order) => (
          <tr key={order.id}>
           <td className="px-5 py-3 text-sm font-medium text-neutral-900">{order.buyer_name}<TestPaymentBadge order={order} /></td>
           <td className="px-5 py-3 text-sm text-neutral-600">{order.buyer_email}</td>
           <td className="px-5 py-3 text-sm text-neutral-600 text-right">{order.ticket_count}</td>
           <td className="px-5 py-3 text-sm text-neutral-900 text-right font-medium">{formatCents(order.total_cents)}</td>
           <td className="px-5 py-3 text-sm text-neutral-500 text-right whitespace-nowrap">{formatDate(order.created_at)}</td>
          </tr>
         ))}
        </tbody>
       </table>
      </div>
      {/* Mobile card layout */}
      <div className="sm:hidden divide-y divide-neutral-200">
       {(stats.recent_orders || []).map((order) => (
        <div key={order.id} className="px-4 py-3">
         <div className="flex items-center justify-between">
          <span className="text-sm font-medium text-neutral-900">{order.buyer_name}<TestPaymentBadge order={order} /></span>
          <span className="text-sm font-medium text-neutral-900">{formatCents(order.total_cents)}</span>
         </div>
         <div className="flex items-center justify-between mt-1">
          <span className="text-xs text-neutral-500 truncate mr-2">{order.buyer_email}</span>
          <span className="text-xs text-neutral-500 whitespace-nowrap">{order.ticket_count} ticket{order.ticket_count === 1 ? '' : 's'}</span>
         </div>
         <p className="text-xs text-neutral-400 mt-1">{formatDate(order.created_at)}</p>
        </div>
       ))}
      </div>
     </>
    ) : (
     <div className="px-5 py-8 text-center">
      <p className="text-sm text-neutral-500">No orders yet.</p>
     </div>
    )}
   </div>

   {/* Attendees: one link to the full, searchable list instead of a second inline copy. */}
   <section aria-labelledby="analytics-attendees-heading" className="bg-white rounded-xl shadow-sm border border-neutral-200 px-5 py-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
    <div className="min-w-0">
     <h2 id="analytics-attendees-heading" className="text-lg font-semibold text-neutral-900">Attendees</h2>
     <p className="mt-1 text-sm text-neutral-600">{permissions.view_attendees === true ? 'Search, filter, check status and export everyone holding a ticket.' : 'Your event access does not include the attendee list.'}</p>
    </div>
    {permissions.view_attendees === true && <Link to={`/dashboard/events/${id}/attendees`} className="btn-secondary min-h-11 shrink-0 self-start !px-4 !py-2.5 text-sm sm:self-auto">
     View attendee list
    </Link>}
   </section>
  </div></EventWorkspace>
 )
}
