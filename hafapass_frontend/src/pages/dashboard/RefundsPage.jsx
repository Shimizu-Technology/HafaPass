import useOperationalListing from '../../hooks/useOperationalListing'
import OperationalSearch from '../../components/OperationalSearch'
import OperationalPagination from '../../components/OperationalPagination'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import EventWorkspace from '../../components/EventWorkspace'
import { useState, useEffect, useCallback, useRef } from 'react'
import { useParams } from 'react-router-dom'
import { RotateCcw, DollarSign, Loader2, AlertTriangle, Check } from 'lucide-react'
import apiClient from '../../api/client'
import { supportMailto } from '../../utils/supportContact'
import { refundConfirmLabel, ticketCountLabel } from '../../utils/eventToolFormat'

const newRefundRequestKey = () => globalThis.crypto?.randomUUID?.() || `refund-${Date.now()}-${Math.random()}`
const needsFinanceReview = (data, request) => data?.finance_review_required === true || (request?.financeReview && data?.finance_review_required !== false)

const isCashOrder = order => order?.payment_method === 'door_cash' && order?.payment_provider === 'door_cash'
const initialRefundForm = request => ({
 amount: request?.payload?.amount_cents ? String(request.payload.amount_cents / 100) : '',
 reason: request?.payload?.reason || '', type: request?.payload?.amount_cents ? 'partial' : 'full',
 cashReference: request?.payload?.cash_return?.reference || '',
 cashReturnedAt: request?.payload?.cash_return?.returned_at || '',
})

const readSavedRefund = key => {
 try {
  const raw = window.sessionStorage.getItem(key)
  if (raw === null) return null
  const request = JSON.parse(raw)
  const payload = request?.payload
  const valid = typeof request?.key === 'string' && request.key.trim() && Number.isSafeInteger(request.orderId) && request.orderId > 0
   && payload && typeof payload === 'object' && !Array.isArray(payload)
   && (payload.reason == null || typeof payload.reason === 'string')
   && (!Object.hasOwn(payload, 'cash_return') || (typeof payload.cash_return?.reference === 'string' && payload.cash_return.reference.trim() && typeof payload.cash_return?.returned_at === 'string' && Number.isFinite(Date.parse(payload.cash_return.returned_at))))
   && (!Object.hasOwn(payload, 'amount_cents') || payload.amount_cents == null || (Number.isSafeInteger(payload.amount_cents) && payload.amount_cents > 0))
  return valid ? request : { recoveryRequired: true }
 } catch { return { recoveryRequired: true } }
}

export default function RefundsPage() {
 const { id: eventId } = useParams()
 const identity = useOrganizerIdentity()
 const visit = useOrganizerPageVisit(`/dashboard/events/${eventId}/refunds`)
 if (!visit.active) return null
 if (!identity.ready) return <p role="status" className="p-6">Preparing your account…</p>
 return <RefundsPageSession key={`${identity.accountKey}:${identity.organizationId}:${eventId}:${visit.generation}`} eventId={eventId} identity={identity} />
}

function RefundsPageSession({ eventId, identity }) {
 const { current, beginRequest } = useOrganizerRequests(identity, `/dashboard/events/${eventId}/refunds`)
 const accessEpoch = useRef(0)
 const requests = useRef(new Set())
 const legacyStorageKey = `hafapass:pending-refund:${identity.owner}:${eventId}`
 const storageKey = `hafapass:pending-refund:v2:${identity.owner}:${identity.organizationId ?? 'default'}:${eventId}`
 const authorizedEvent = useRef(false)
 const [accessRefreshing, setAccessRefreshing] = useState(false)
 const importedLegacyKey = useRef(null)
 const [contextError, setContextError] = useState('')
 const [pendingRequest, setPendingRequest] = useState(() => readSavedRefund(storageKey))
 const [notice, setNotice] = useState('')
 const [cashInvalidField, setCashInvalidField] = useState(null)
 const [loadError, setLoadError] = useState('')
 const [orders, setOrders] = useState([])
 const listing = useOperationalListing(`refunds:${identity.owner}:${identity.organizationId}:${eventId}`)
 const [orderMeta, setOrderMeta] = useState(null)
 const [loading, setLoading] = useState(true)
 const loadGeneration = useRef(0)
 const [refundingId, setRefundingId] = useState(pendingRequest?.orderId || null)
 const [refundForm, setRefundForm] = useState(() => initialRefundForm(pendingRequest?.recoveryRequired ? null : pendingRequest))
 const [refundRequestKey, setRefundRequestKey] = useState(pendingRequest?.key || null)
 const [processing, setProcessing] = useState(false)
 const withdrawAccess = useCallback(message => {
  ++accessEpoch.current
  authorizedEvent.current = false
  requests.current.forEach(request => request.controller.abort())
  // The durable financial operation is retained unchanged. Access refusal is
  // not a provider verdict and cannot clear or replace its original identity.
  setOrders([]); setRefundingId(null); setRefundRequestKey(null)
  setRefundForm(initialRefundForm())
  setNotice(''); setLoadError(''); setProcessing(false); setAccessRefreshing(false); setLoading(false)
  setContextError(message)
 }, [])
 const requestApi = useCallback(async (method, url, payload, options = {}) => {
  const verifying = method === 'get' && url === `/organizer/events/${eventId}`
  if (!verifying && !authorizedEvent.current) throw new DOMException('Refund access is not verified', 'AbortError')
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
   if (request.current() && epoch === accessEpoch.current && [401, 403].includes(requestError.response?.status)) {
    withdrawAccess(requestError.response.status === 401 ? 'Please sign in to verify refund access.'
     : 'Your refund access changed. Retry to verify permissions. The original saved financial operation is retained.')
   }
   throw requestError
  } finally { requests.current.delete(request); request.release() }
 }, [beginRequest, eventId, withdrawAccess])

 const fetchOrders = useCallback(async () => {
  const generation = ++loadGeneration.current
  if (!current()) return
  const epoch = ++accessEpoch.current
  requests.current.forEach(request => request.controller.abort())
  const canApply = () => current() && generation === loadGeneration.current && epoch === accessEpoch.current
  setLoadError('')
  setContextError('')
  setProcessing(false)
  authorizedEvent.current = false
  setAccessRefreshing(true)
  setOrders([])
  try {
   const eventResponse = await requestApi('get', `/organizer/events/${eventId}`)
   if (!canApply()) return
   if (String(eventResponse.data.id) !== String(eventId) || eventResponse.data.organization_id == null || (identity.organizationId != null && String(eventResponse.data.organization_id) !== String(identity.organizationId))) {
    throw new Error('Event authorization does not match this page')
   }
   if (eventResponse.data.permissions?.refund !== true || eventResponse.data.permissions?.view_finance !== true) throw new Error('Refund access is not available for your role')
   authorizedEvent.current = true
   try {
    const legacy = readSavedRefund(legacyStorageKey)
    const cached = readSavedRefund(storageKey)
    if (cached?.recoveryRequired || legacy?.recoveryRequired) {
     setPendingRequest({ recoveryRequired: true })
     setRefundingId(null); setRefundRequestKey(null)
     setRefundForm(initialRefundForm())
    } else if (legacy?.key && !cached) {
     window.sessionStorage.setItem(storageKey, JSON.stringify(legacy))
     setPendingRequest(legacy)
     setRefundingId(legacy.orderId)
     setRefundRequestKey(legacy.key)
     setRefundForm(initialRefundForm(legacy))
    }
    if (cached?.key && !cached.recoveryRequired && !legacy?.recoveryRequired) {
     setPendingRequest(cached)
     setRefundingId(cached.orderId)
     setRefundRequestKey(cached.key)
     setRefundForm(initialRefundForm(cached))
    }
    if (legacy?.key && legacy.key === (cached || legacy)?.key) importedLegacyKey.current = legacy.key
   } catch {
    setPendingRequest({ recoveryRequired: true })
    setRefundingId(null); setRefundRequestKey(null)
    setRefundForm(initialRefundForm())
   }
   const res = await requestApi('get', `/organizer/events/${eventId}/orders`, { params: { q: listing.q, page: listing.page } })
      if (!canApply()) return
   setOrders(res.data.orders || [])
   setOrderMeta(res.data.meta || null)
  } catch {
   if (canApply()) {
    if (authorizedEvent.current) setLoadError('Orders could not be loaded. Please try again.')
    else setContextError('This event could not be authorized for the selected organization. Retry before viewing or processing refunds.')
   }
  } finally { if (canApply()) { setLoading(false); setAccessRefreshing(false) } }
 }, [eventId, requestApi, current, identity.organizationId, legacyStorageKey, storageKey, listing.q, listing.page])

 useEffect(() => { fetchOrders() }, [fetchOrders])

 const handleRefund = async (orderId) => {
    if (!current() || !authorizedEvent.current || pendingRequest?.recoveryRequired || (pendingRequest && pendingRequest.orderId !== orderId)) return
  if (processing || accessRefreshing) return
  const epoch = accessEpoch.current
  const canApply = () => current() && epoch === accessEpoch.current
  setProcessing(true)
  setNotice('')
  let request = pendingRequest
  try {
   const payload = { reason: refundForm.reason || null }
   setCashInvalidField(null)
   if (!pendingRequest && isCashOrder(orders.find(order => order.id === orderId))) {
    const returnedAt = new Date(refundForm.cashReturnedAt)
    const selectedOrder = orders.find(order => order.id === orderId)
    const invalidField = !refundForm.cashReference.trim() || refundForm.cashReference.trim().length > 255 ? `cash-reference-${orderId}`
     : !Number.isFinite(returnedAt.getTime()) || returnedAt > new Date() || returnedAt < new Date(selectedOrder.created_at) ? `cash-returned-at-${orderId}`
      : !refundForm.reason.trim() ? `refund-reason-${orderId}` : null
    if (invalidField) {
     setCashInvalidField(invalidField)
     setNotice('Enter the reason, cash return reference and a return date/time between the order date and now.')
     const target = document.getElementById(invalidField)
     target?.focus()
     target?.scrollIntoView?.({ block: 'center', behavior: 'instant' })
     setProcessing(false)
     return
    }
    payload.cash_return = { reference: refundForm.cashReference.trim(), returned_at: returnedAt.toISOString() }
   }
   if (refundForm.type === 'partial' && refundForm.amount) {
    const parsed = parseFloat(refundForm.amount)
    if (Number.isNaN(parsed) || parsed <= 0) {
     setNotice('Please enter a valid refund amount.')
     setProcessing(false)
     return
    }
    payload.amount_cents = Math.round(parsed * 100)
   }
   request ||= { orderId, key: refundRequestKey || newRefundRequestKey(), payload }
   window.sessionStorage.setItem(storageKey, JSON.stringify(request))
   setPendingRequest(request)
   const response = await requestApi('post', `/organizer/events/${eventId}/orders/${orderId}/refund`, request.payload, {
    headers: { 'Idempotency-Key': request.key },
   })
   if (!canApply()) return
   const status = response.data.status
   request = { ...request, financeReview: Boolean(needsFinanceReview(response.data, request)) }
   window.sessionStorage.setItem(storageKey, JSON.stringify(request))
   setPendingRequest(request)
   if (request.financeReview) {
    // The persistent review banner owns this outcome, including after reload.
   } else if (status === 'pending') {
    setNotice('Refund pending — waiting for the payment provider. Retry this saved request to check its status; do not create another refund.')
   } else if (['succeeded', 'failed', 'cancelled'].includes(status)) {
    setNotice(status === 'succeeded' ? response.data.manual_record && response.data.provider === 'door_cash' ? 'Cash return recorded. The organizer returned physical cash; HafaPass did not transfer money.' : response.data.refund_simulated ? 'Test refund complete. No real money was returned.' : 'Refund confirmed by the payment provider.' : `Refund ${status}. No refund has been confirmed.`)
    window.sessionStorage.removeItem(storageKey)
    if (importedLegacyKey.current === request.key) window.sessionStorage.removeItem(legacyStorageKey)
    setPendingRequest(null)
    setRefundingId(null)
    setRefundRequestKey(null)
    setRefundForm(initialRefundForm())
   } else { setNotice('The refund outcome is not confirmed. Retry this saved request before starting another refund.') }
   fetchOrders()
  } catch (e) {
      if (!canApply()) return
   const data = e.response?.data
   if (request?.financeReview && data?.finance_review_required === false) {
    request = { ...request, financeReview: false }
    window.sessionStorage.setItem(storageKey, JSON.stringify(request))
    setPendingRequest(request)
   }
   if (needsFinanceReview(data, request)) {
    request = { ...request, financeReview: true }
    window.sessionStorage.setItem(storageKey, JSON.stringify(request))
    setPendingRequest(request)
   } else if (data?.reconciliation_required === false) {
    window.sessionStorage.removeItem(storageKey)
    if (importedLegacyKey.current === request.key) window.sessionStorage.removeItem(legacyStorageKey)
    setPendingRequest(null)
    setRefundingId(null)
    setRefundRequestKey(null)
    setRefundForm(initialRefundForm())
    setNotice(`${data.error || 'The request was rejected.'} No new refund was confirmed by this request.`)
   } else {
    setNotice(`${data?.error || 'The refund response could not be confirmed.'} Retry this saved request to check the outcome; do not create another refund.`)
   }
  }
  if (canApply()) setProcessing(false)
 }

 if (loading) return <div className="flex justify-center py-20"><Loader2 className="w-8 h-8 text-brand-500 animate-spin" /></div>

 if (contextError) return <div role="alert" className="mx-auto max-w-2xl p-6"><p>{contextError}</p><button type="button" onClick={fetchOrders} className="btn-primary mt-4">Retry refund access</button></div>

 return (
  <EventWorkspace eventId={eventId}><div className="max-w-4xl mx-auto">

   <div className="mb-8">
    <h2 className="text-2xl font-bold tracking-tight text-neutral-900">Refunds</h2>
    <p className="text-sm text-neutral-500 mt-1">Process full or partial refunds for completed orders</p>
   </div>

   <OperationalSearch label="Find an order" buttonLabel="Search orders" hint="Search by order reference, order number, buyer name or email." query={listing.q} onSearch={listing.search} busy={processing || accessRefreshing} />
   {accessRefreshing && <p role="status" className="mb-3 text-sm text-neutral-700">Loading orders…</p>}
   {notice && !pendingRequest?.financeReview && <p id="refund-notice" role="status" className="mb-4 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950">{notice}</p>}
   {pendingRequest?.financeReview && <div className="mb-4 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950" role="status">
    <p>The payment records need a finance review. Contact support before starting another refund. This saved request and its payment identity are retained.</p>
    <a className="inline-flex min-h-11 items-center font-semibold underline" href={supportMailto(`Refund review for order ${pendingRequest.orderId}`)}>Contact support</a>
   </div>}
   {pendingRequest?.recoveryRequired && <div role="alert" className="mb-4 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950"><p>A saved refund recovery record could not be safely read. Money actions are paused. Contact support to verify the original outcome before starting or retrying a refund.</p><a href={supportMailto('Recover an unreadable refund request')} className="mt-2 inline-flex min-h-11 items-center font-semibold underline">Contact support</a></div>}
   {pendingRequest && !pendingRequest.recoveryRequired && <p className="mb-4 break-words text-sm text-neutral-600">Saved refund for order #{pendingRequest.orderId}. Its amount and payment identity stay fixed until the outcome is confirmed.</p>}
   {pendingRequest && !pendingRequest.recoveryRequired && !orders.some(order => order.id === pendingRequest.orderId) && <button disabled={processing || accessRefreshing} className="btn-secondary mb-4" onClick={() => handleRefund(pendingRequest.orderId)}>{pendingRequest.financeReview ? 'Check saved refund status' : pendingRequest.payload.cash_return ? 'Retry saved cash return record' : 'Retry saved refund'}</button>}
   {loadError && <p role="alert" className="mb-4 text-sm text-red-700">{loadError} <button className="min-h-11 font-semibold underline" onClick={fetchOrders}>Retry</button></p>}
   {loadError && orders.length === 0 ? null : orders.length === 0 ? (
    <div className="card p-12 text-center">
     <DollarSign className="w-10 h-10 text-neutral-300 mx-auto mb-3" />
     <p className="text-neutral-500">{listing.q || listing.page > 1 ? 'No matching orders. Try another search or the previous page.' : 'No completed orders yet'}</p>
    </div>
   ) : (
    <div className="space-y-3">
     {orders.map(order => (
      <div key={order.id} className="card p-5">
       <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div className="flex items-center gap-4 min-w-0">
         <div className="w-10 h-10 rounded-xl bg-brand-50 flex items-center justify-center shrink-0">
          <DollarSign className="w-5 h-5 text-brand-500" />
         </div>
         <div className="min-w-0">
          <p className="font-medium text-neutral-900 break-words">{order.reference || `Order #${order.id}`} &middot; {order.buyer_name}</p>
          <p className="text-sm text-neutral-600 break-words">
           {order.buyer_email} &middot; {ticketCountLabel(order.ticket_count)} &middot; ${(order.total_cents / 100).toFixed(2)}
           {order.refunded_cents > 0 && <> &middot; ${(order.refunded_cents / 100).toFixed(2)} refunded</>}
          </p>
         </div>
        </div>
        {refundingId !== order.id ? (
         <button onClick={() => { setRefundingId(order.id); setRefundRequestKey(newRefundRequestKey()); setRefundForm(initialRefundForm()) }}
          disabled={processing || accessRefreshing || Boolean(pendingRequest) || order.refundable_cents <= 0}
          className="btn-secondary min-h-11 text-sm !py-2 !px-4 gap-1.5 shrink-0 self-start sm:self-auto disabled:opacity-50 disabled:cursor-not-allowed">
          <RotateCcw className="w-4 h-4" /> {isCashOrder(order) ? 'Record cash already returned' : 'Refund'}
         </button>
        ) : (
         <button disabled={processing || accessRefreshing || Boolean(pendingRequest)} onClick={() => { setRefundingId(null); setRefundRequestKey(null) }} className="text-sm text-neutral-500 hover:text-neutral-700 shrink-0">Cancel</button>
        )}
       </div>

       {order.refunds?.filter(refund => refund.manual_record && refund.provider === 'door_cash').map(refund => <p key={refund.id} className="mt-3 break-words text-sm text-neutral-700">Cash return recorded: ${(refund.amount_cents / 100).toFixed(2)} · {refund.cash_return?.reference} · Returned {refund.cash_return?.returned_at} · Recorded {refund.recorded_at} · Organizer custody. No money transferred by HafaPass.</p>)}
       {refundingId === order.id && (
        <div className="mt-4 pt-4 border-t border-neutral-100">
         <div className="bg-amber-50 border border-amber-200 rounded-xl p-3 mb-4 flex items-start gap-2">
          <AlertTriangle className="w-4 h-4 text-amber-600 mt-0.5 shrink-0" />
          <p className="text-sm text-amber-700">{isCashOrder(order) ? 'The organizer holds door cash and must return it to the buyer first. This records physical cash already returned. HafaPass does not send money. Enter the receipt or repayment reference, when the cash was returned, and why.' : 'The original payment provider determines the outcome. Pending requests are not completed refunds. Unsupported terminal payments need a manager to arrange repayment.'}</p>
         </div>
         {isCashOrder(order) && <div className="mb-4 grid gap-3 sm:grid-cols-2">
          <div><label htmlFor={`cash-reference-${order.id}`} className="mb-1 block text-sm font-medium">Cash return reference</label>
           <input id={`cash-reference-${order.id}`} aria-invalid={cashInvalidField === `cash-reference-${order.id}` || undefined} aria-describedby={cashInvalidField === `cash-reference-${order.id}` ? 'refund-notice' : undefined} required maxLength={255} disabled={processing || accessRefreshing || Boolean(pendingRequest)} value={refundForm.cashReference} onChange={event => setRefundForm({ ...refundForm, cashReference: event.target.value })} className="input" /></div>
          <div><label htmlFor={`cash-returned-at-${order.id}`} className="mb-1 block text-sm font-medium">Cash returned at (your device time)</label>
           {pendingRequest ? <input id={`cash-returned-at-${order.id}`} disabled value={refundForm.cashReturnedAt} className="input" /> : <input id={`cash-returned-at-${order.id}`} type="datetime-local" step="1" aria-invalid={cashInvalidField === `cash-returned-at-${order.id}` || undefined} aria-describedby={cashInvalidField === `cash-returned-at-${order.id}` ? 'refund-notice' : undefined} required min={new Date(Date.parse(order.created_at) - new Date(order.created_at).getTimezoneOffset() * 60000).toISOString().slice(0, 19)} disabled={processing || accessRefreshing} value={refundForm.cashReturnedAt} onChange={event => setRefundForm({ ...refundForm, cashReturnedAt: event.target.value })} className="input" />}</div>
         </div>}
         <div className="flex gap-3 items-end flex-wrap">
          <div>
           <label htmlFor={`refund-type-${order.id}`} className="block text-sm font-medium text-neutral-700 mb-1.5">Type</label>
           <select id={`refund-type-${order.id}`} disabled={processing || accessRefreshing || Boolean(pendingRequest)} value={refundForm.type} onChange={e => setRefundForm({...refundForm, type: e.target.value})} className="input !py-2 text-sm w-32">
            <option value="full">Full</option>
            <option value="partial">Partial</option>
           </select>
          </div>
          {refundForm.type === 'partial' && (
           <div>
            <label htmlFor={`refund-amount-${order.id}`} className="block text-sm font-medium text-neutral-700 mb-1.5">Amount ($)</label>
            <input id={`refund-amount-${order.id}`} disabled={processing || accessRefreshing || Boolean(pendingRequest)} type="number" step="0.01" min="0.01" max={(order.refundable_cents / 100).toFixed(2)}
             value={refundForm.amount} onChange={e => setRefundForm({...refundForm, amount: e.target.value})}
             className="input !py-2 text-sm w-28" placeholder="0.00" />
           </div>
          )}
          <div className="flex-1 min-w-[200px]">
           <label htmlFor={`refund-reason-${order.id}`} className="block text-sm font-medium text-neutral-700 mb-1.5">{isCashOrder(order) ? 'Reason (required)' : 'Reason (optional)'}</label>
           <input id={`refund-reason-${order.id}`} aria-invalid={cashInvalidField === `refund-reason-${order.id}` || undefined} aria-describedby={cashInvalidField === `refund-reason-${order.id}` ? 'refund-notice' : undefined} disabled={processing || accessRefreshing || Boolean(pendingRequest)} value={refundForm.reason} onChange={e => setRefundForm({...refundForm, reason: e.target.value})}
            className="input !py-2 text-sm" placeholder="Customer request, event cancelled..." />
          </div>
          <button onClick={() => handleRefund(order.id)} disabled={processing || accessRefreshing || pendingRequest?.recoveryRequired || (refundForm.type === 'partial' && !refundForm.amount)}
           className="btn-primary text-sm !py-2.5 !bg-action-danger hover:!bg-action-danger-hover gap-1 disabled:opacity-50">
           {processing ? <Loader2 className="w-4 h-4 animate-spin" /> : <Check className="w-4 h-4" />}
           {pendingRequest?.financeReview ? 'Check saved refund status' : pendingRequest ? pendingRequest.payload.cash_return ? 'Retry saved cash return record' : 'Retry saved refund' : isCashOrder(order) ? 'Record cash already returned' : refundConfirmLabel(order, refundForm)}
          </button>
         </div>
        </div>
       )}
      </div>
     ))}
    </div>
   )}
   <OperationalPagination meta={orderMeta} page={listing.page} onPage={listing.goToPage} busy={processing || accessRefreshing} label="Order pages" />
  </div></EventWorkspace>
 )
}
