import { formatPlatformDateTime } from '../../utils/eventTime'
import useOperationalListing from '../../hooks/useOperationalListing'
import OperationalSearch from '../../components/OperationalSearch'
import OperationalPagination from '../../components/OperationalPagination'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import EventWorkspace from '../../components/EventWorkspace'
import { useState, useEffect, useCallback, useRef } from 'react'
import { useParams } from 'react-router-dom'
import { RotateCcw, DollarSign, Loader2, AlertTriangle, Check } from 'lucide-react'
import apiClient from '../../api/client'
import TestPaymentBadge from '../../components/TestPaymentBadge'
import SupportLink from '../../components/SupportLink'
import RefundReconciliationQueue from '../../components/RefundReconciliationQueue'
import RefundTicketChecklist from './RefundTicketChecklist'
import { formatDollars, partialRefundCents, pluralize, refundConfirmLabel, ticketCountLabel } from '../../utils/eventToolFormat'

const newRefundRequestKey = () => globalThis.crypto?.randomUUID?.() || `refund-${Date.now()}-${Math.random()}`
const needsFinanceReview = (data, request) => data?.finance_review_required === true || (request?.financeReview && data?.finance_review_required !== false)

const isCashOrder = order => order?.payment_method === 'door_cash' && order?.payment_provider === 'door_cash'
const initialRefundForm = request => ({
 amount: request?.payload?.amount_cents ? String(request.payload.amount_cents / 100) : '',
 reason: request?.payload?.reason || '', type: request?.payload?.ticket_ids ? 'tickets' : request?.payload?.amount_cents ? 'partial' : 'full',
 ticketIds: request?.payload?.ticket_ids || [],
 cashReference: request?.payload?.cash_return?.reference || '',
 cashReturnedAt: request?.payload?.cash_return?.returned_at || '',
})

const readSavedRefund = (key, { legacy = false } = {}) => {
 try {
  const raw = legacy ? window.sessionStorage.getItem(key) : window.localStorage.getItem(key) ?? window.sessionStorage.getItem(key)
  if (raw === null) return null
  const request = JSON.parse(raw)
  const payload = request?.payload
  const valid = typeof request?.key === 'string' && request.key.trim() && Number.isSafeInteger(request.orderId) && request.orderId > 0
   && payload && typeof payload === 'object' && !Array.isArray(payload)
   && (payload.reason == null || typeof payload.reason === 'string')
   && (!Object.hasOwn(payload, 'cash_return') || (typeof payload.cash_return?.reference === 'string' && payload.cash_return.reference.trim() && typeof payload.cash_return?.returned_at === 'string' && Number.isFinite(Date.parse(payload.cash_return.returned_at))))
   && (!Object.hasOwn(payload, 'amount_cents') || payload.amount_cents == null || (Number.isSafeInteger(payload.amount_cents) && payload.amount_cents > 0))
   && (!Object.hasOwn(payload, 'preserve_tickets') || (payload.preserve_tickets === true && Number.isSafeInteger(payload.amount_cents)))
   && (!Object.hasOwn(payload, 'ticket_ids') || (!Object.hasOwn(payload, 'amount_cents') && Array.isArray(payload.ticket_ids)
    && payload.ticket_ids.length > 0 && payload.ticket_ids.every(id => Number.isSafeInteger(id) && id > 0)
    && new Set(payload.ticket_ids).size === payload.ticket_ids.length))
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
 const [canRecordCash, setCanRecordCash] = useState(false)
 const [accessRefreshing, setAccessRefreshing] = useState(false)
 const importedLegacyKey = useRef(null)
 const [contextError, setContextError] = useState('')
 const [pendingRequest, setPendingRequest] = useState(() => readSavedRefund(storageKey))
 const [notice, setNotice] = useState('')
 const [cashInvalidField, setCashInvalidField] = useState(null)
 const [loadError, setLoadError] = useState('')
 const [orders, setOrders] = useState([])
 const [queueItems, setQueueItems] = useState([])
 const [queueMeta, setQueueMeta] = useState(null)
 const [queuePage, setQueuePage] = useState(1)
 const [queueError, setQueueError] = useState('')
 const listing = useOperationalListing(`refunds:${identity.owner}:${identity.organizationId}:${eventId}`)
 const [orderMeta, setOrderMeta] = useState(null)
 const [loading, setLoading] = useState(true)
 const loadGeneration = useRef(0)
 const [refundingId, setRefundingId] = useState(pendingRequest?.orderId || null)
 const [refundForm, setRefundForm] = useState(() => initialRefundForm(pendingRequest?.recoveryRequired ? null : pendingRequest))
 const [refundOptions, setRefundOptions] = useState(null)
 const [optionsError, setOptionsError] = useState(false)
 const [optionsAttempt, setOptionsAttempt] = useState(0)
 const [eventTimeZone, setEventTimeZone] = useState()
 const [processing, setProcessing] = useState(false)
 const withdrawAccess = useCallback(message => {
  ++accessEpoch.current
  authorizedEvent.current = false
  setCanRecordCash(false)
  requests.current.forEach(request => request.controller.abort())
  // The durable financial operation is retained unchanged. Access refusal is
  // not a provider verdict and cannot clear or replace its original identity.
  setOrders([]); setQueueItems([]); setQueueMeta(null); setRefundingId(null)
  setRefundOptions(null)
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
  setQueueError('')
  setContextError('')
  setProcessing(false)
  authorizedEvent.current = false
  setCanRecordCash(false)
  setAccessRefreshing(true)
  setOrders([])
  setQueueItems([])
  setQueueMeta(null)
  try {
   const eventResponse = await requestApi('get', `/organizer/events/${eventId}`)
   if (!canApply()) return
   if (String(eventResponse.data.id) !== String(eventId) || eventResponse.data.organization_id == null || (identity.organizationId != null && String(eventResponse.data.organization_id) !== String(identity.organizationId))) {
    throw new Error('Event authorization does not match this page')
   }
   if (eventResponse.data.permissions?.refund !== true || eventResponse.data.permissions?.view_finance !== true) throw new Error('Refund access is not available for your role')
   authorizedEvent.current = true
   setEventTimeZone(eventResponse.data.timezone)
   setCanRecordCash(eventResponse.data.permissions.refund === true)
   try {
    const legacy = readSavedRefund(legacyStorageKey, { legacy: true })
    const cached = readSavedRefund(storageKey)
    if (cached?.recoveryRequired || legacy?.recoveryRequired) {
     setPendingRequest({ recoveryRequired: true })
     setRefundingId(null)
     setRefundForm(initialRefundForm())
    } else if (cached || legacy) {
     const saved = cached || legacy
     window.localStorage.setItem(storageKey, JSON.stringify(saved))
     window.sessionStorage.removeItem(storageKey)
     setPendingRequest(saved)
     setRefundingId(saved.orderId)
     setRefundForm(initialRefundForm(saved))
    }
    if (legacy?.key && legacy.key === (cached || legacy)?.key) importedLegacyKey.current = legacy.key
   } catch {
    setPendingRequest({ recoveryRequired: true })
    setRefundingId(null)
    setRefundForm(initialRefundForm())
   }
   const res = await requestApi('get', `/organizer/events/${eventId}/orders`, { params: { q: listing.q, page: listing.page } })
      if (!canApply()) return
   setOrders(res.data.orders || [])
   setOrderMeta(res.data.meta || null)
   try {
    const queue = await requestApi('get', '/organizer/refund_reconciliation', { params: { event_id: eventId, page: queuePage } })
    if (!canApply()) return
    setQueueItems(queue.data.items || [])
    setQueueMeta(queue.data.meta || null)
   } catch {
    if (canApply()) setQueueError('Refund issues could not be loaded. Try again.')
   }
  } catch {
   if (canApply()) {
    if (authorizedEvent.current) setLoadError('Orders could not be loaded. Please try again.')
    else setContextError('This event could not be authorized for the selected organization. Retry before viewing or processing refunds.')
   }
  } finally { if (canApply()) { setLoading(false); setAccessRefreshing(false) } }
 }, [eventId, requestApi, current, identity.organizationId, legacyStorageKey, storageKey, listing.q, listing.page, queuePage])

 useEffect(() => { fetchOrders() }, [fetchOrders])

 const openOrder = orders.find(order => order.id === refundingId && !order.external_refund_verification_required)

 useEffect(() => {
  if (!openOrder || pendingRequest || accessRefreshing) return

  let active = true
  setOptionsError(false)
  requestApi('get', `/organizer/events/${eventId}/orders/${openOrder.id}/refund_options`).then(({ data }) => {
   if (!active) return
   if (data.order_id !== openOrder.id || !Array.isArray(data.tickets)) throw new Error('Ticket availability could not be read')
   const selectableCount = data.tickets.filter(ticket => ticket.selectable).length
   setRefundOptions(data)
   setRefundForm(form => ({ ...form, type: data.is_free_order || selectableCount > 1 ? 'tickets' : 'full', ticketIds: [] }))
  }).catch(() => { if (active) setOptionsError(true) })
  return () => { active = false }
 }, [accessRefreshing, eventId, openOrder, optionsAttempt, pendingRequest, requestApi])

 const recordQueueReturn = async (item, action, payload) => {
  if (action !== 'manual_return' || !authorizedEvent.current) throw new Error('This action is not available.')
  const response = await requestApi('post', `/organizer/refund_reconciliation/${encodeURIComponent(item.type)}/${item.id}/manual_return`, payload)
  if (current()) {
   setNotice('Manual return recorded. The buyer was repaid outside HåfaPass.')
   await fetchOrders()
  }
  return response
 }

 const verificationBlocksNewReturn = order => order.external_refund_verification_required === true
  && !(pendingRequest?.orderId === order.id && !pendingRequest.recoveryRequired)
 const selectableTickets = refundOptions?.tickets.filter(ticket => ticket.selectable) || []
 const selectedTickets = selectableTickets.filter(ticket => refundForm.ticketIds.includes(ticket.id) || (refundOptions.is_free_order && refundForm.type === 'full'))
 const selectedAmount = selectedTickets.reduce((total, ticket) => total + ticket.refundable_cents, 0)
 const includesPass = selectedTickets.some(ticket => ticket.is_pass_parent)
 const cancellationTarget = includesPass
  ? 'QR codes for the selected tickets and their pass nights'
  : pluralize(selectedTickets.length, refundOptions?.is_free_order ? 'selected free QR code' : 'selected QR code')
 const inventoryTarget = includesPass ? 'the selected tickets' : selectedTickets.length === 1 ? 'it' : 'them'
 const isTicketRequest = refundForm.type === 'tickets' || refundOptions?.is_free_order
 const customAmountLimit = openOrder && refundOptions ? Math.min(refundOptions.refundable_cents, openOrder.refundable_cents) - 1 : 0
 const partialAmountError = !pendingRequest && refundForm.type === 'partial' ? partialRefundCents(refundForm.amount, customAmountLimit).error : null
 const blockedSelection = isTicketRequest && (!selectedTickets.length || selectedAmount > refundOptions.refundable_cents)
 const selectMode = type => setRefundForm(form => ({ ...form, type }))
 const toggleTicket = id => setRefundForm(form => ({
  ...form, ticketIds: form.ticketIds.includes(id) ? form.ticketIds.filter(ticketId => ticketId !== id) : [...form.ticketIds, id],
 }))
 const closeRefundPanel = () => {
  setRefundingId(null)
  setRefundOptions(null)
  setOptionsError(false)
 }

 const savePending = request => window.localStorage.setItem(storageKey, JSON.stringify(request))
 const clearPending = request => {
  window.localStorage.removeItem(storageKey)
  window.sessionStorage.removeItem(storageKey)
  if (importedLegacyKey.current === request.key) window.sessionStorage.removeItem(legacyStorageKey)
  setPendingRequest(null)
  setRefundingId(null)
  setRefundOptions(null)
  setRefundForm(initialRefundForm())
 }

 const handleRefund = async (orderId) => {
  if (!current() || !authorizedEvent.current || pendingRequest?.recoveryRequired || (pendingRequest && pendingRequest.orderId !== orderId)) return
  if (processing || accessRefreshing) return
  const selectedOrder = orders.find(order => order.id === orderId)
  if (!pendingRequest && (!selectedOrder || selectedOrder.external_refund_verification_required === true ||
   refundOptions?.order_id !== orderId || refundOptions.unavailable_reason || blockedSelection || partialAmountError)) return
  // Another tab may have saved an operation since this form was opened.
  if (!pendingRequest && readSavedRefund(storageKey)) {
   fetchOrders()
   return
  }
  const epoch = accessEpoch.current
  const canApply = () => current() && epoch === accessEpoch.current
  setProcessing(true)
  setNotice('')
  let request = pendingRequest
  try {
   const payload = { reason: refundForm.reason || null }
   setCashInvalidField(null)
   if (!pendingRequest && isCashOrder(selectedOrder)) {
    const returnedAt = new Date(refundForm.cashReturnedAt)
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
   if (!pendingRequest && refundForm.type === 'partial') {
    payload.amount_cents = partialRefundCents(refundForm.amount, customAmountLimit).cents
    payload.preserve_tickets = true
   }
   if (!pendingRequest && isTicketRequest) payload.ticket_ids = selectedTickets.map(ticket => ticket.id)
   // Allocate a key for the submitted selection. Retries always use the saved payload and key.
   request ||= { orderId, key: newRefundRequestKey(), payload }
   savePending(request)
   setPendingRequest(request)
   const response = await requestApi('post', `/organizer/events/${eventId}/orders/${orderId}/refund`, request.payload, {
    headers: { 'Idempotency-Key': request.key },
   })
   if (!canApply()) return
   const status = response.data.status
   request = { ...request, financeReview: Boolean(needsFinanceReview(response.data, request)) }
   savePending(request)
   setPendingRequest(request)
   if (request.financeReview) {
    // The persistent review banner owns this outcome, including after reload.
   } else if (status === 'pending') {
    setNotice('Refund pending — waiting for the payment provider. Retry this saved request to check its status; do not create another refund.')
   } else if (['succeeded', 'failed', 'cancelled'].includes(status)) {
    const data = response.data
    let message = `Refund ${status}. No refund has been confirmed.`
    if (status === 'succeeded') {
     if (data.free_ticket_cancellation) {
      const count = request.payload.ticket_ids.length
      message = `Cancelled ${pluralize(count, 'free ticket')} and returned ${count === 1 ? 'it' : 'them'} to inventory.`
     }
     else if (data.manual_record && data.provider === 'door_cash') message = 'Cash return recorded. The organizer returned physical cash; HåfaPass did not transfer money.'
     else if (data.refund_simulated) message = 'Test refund complete. No real money was returned.'
     else message = 'Refund confirmed by the payment provider.'
    }
    setNotice(message)
    clearPending(request)
   } else { setNotice('The refund outcome is not confirmed. Retry this saved request before starting another refund.') }
   fetchOrders()
  } catch (e) {
      if (!canApply()) return
   const data = e.response?.data
   if (request?.financeReview && data?.finance_review_required === false) {
    request = { ...request, financeReview: false }
    savePending(request)
    setPendingRequest(request)
   }
   if (needsFinanceReview(data, request)) {
    request = { ...request, financeReview: true }
    savePending(request)
    setPendingRequest(request)
   } else if (data?.reconciliation_required === false) {
    clearPending(request)
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
    <p className="mt-1 text-neutral-700">Return money or cancel tickets for a completed order.</p>
   </div>

   <section aria-labelledby="refund-issues-heading" className="mb-8">
    <h3 id="refund-issues-heading" className="mb-1 text-lg font-semibold text-neutral-900">Refunds needing follow-up</h3>
    <p className="mb-3 text-sm text-neutral-600">Review unresolved refund outcomes before returning money. Record a cash or card return only after you have returned the money.</p>
    {queueError && <p role="alert" className="mb-3 text-sm text-red-700">{queueError} <button type="button" className="min-h-11 font-semibold underline" onClick={fetchOrders}>Try again</button></p>}
    {!queueError && <RefundReconciliationQueue items={queueItems} canRecordCash={canRecordCash} onAction={recordQueueReturn} busy={accessRefreshing} />}
    <OperationalPagination meta={queueMeta && { ...queueMeta, total_count: queueMeta.total_count ?? queueMeta.total }} page={queuePage} onPage={setQueuePage} busy={accessRefreshing} label="Refund issue pages" />
   </section>

   <OperationalSearch label="Find an order" buttonLabel="Search orders" hint="Search by order reference, order number, buyer name or email." query={listing.q} onSearch={listing.search} busy={processing || accessRefreshing} />
   {accessRefreshing && <p role="status" className="mb-3 text-sm text-neutral-700">Loading orders…</p>}
   {notice && !pendingRequest?.financeReview && <p id="refund-notice" role="status" className="mb-4 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950">{notice}</p>}
   {pendingRequest?.financeReview && <div className="mb-4 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950" role="status">
    <p>The original refund request is saved. Contact support before starting another refund.</p>
    <SupportLink subject={`Refund review for order ${pendingRequest.orderId}`} className="inline-flex min-h-11 items-center font-semibold underline">Contact support</SupportLink>
   </div>}
   {pendingRequest?.recoveryRequired && <div role="alert" className="mb-4 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950"><p>A saved refund recovery record could not be safely read. Money actions are paused. Contact support to verify the original outcome before starting or retrying a refund.</p><SupportLink subject="Recover an unreadable refund request" className="mt-2 inline-flex min-h-11 items-center font-semibold underline">Contact support</SupportLink></div>}
   {pendingRequest && !pendingRequest.recoveryRequired && <p className="mb-4 break-words text-sm text-neutral-600">Saved refund for order #{pendingRequest.orderId}. The original refund request is saved. Contact support before starting another refund.</p>}
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
          <p className="font-medium text-neutral-900 break-words">{order.reference || `Order #${order.id}`} &middot; {order.buyer_name}<TestPaymentBadge order={order} /></p>
          <p className="text-sm text-neutral-600 break-words">
           {order.buyer_email} &middot; {ticketCountLabel(order.ticket_count)} &middot; ${(order.total_cents / 100).toFixed(2)}
           {order.refunded_cents > 0 && <> &middot; ${(order.refunded_cents / 100).toFixed(2)} refunded</>}
          </p>
         </div>
        </div>
        {refundingId !== order.id || verificationBlocksNewReturn(order) ? (
         <button type="button" aria-expanded={false} onClick={() => { closeRefundPanel(); setCashInvalidField(null); setRefundingId(order.id); setRefundForm(initialRefundForm()) }}
          disabled={processing || accessRefreshing || Boolean(pendingRequest) || (order.total_cents > 0 && order.refundable_cents <= 0) || verificationBlocksNewReturn(order)}
          aria-describedby={verificationBlocksNewReturn(order) ? `external-refund-review-${order.id}` : undefined}
          className="btn-secondary min-h-12 !px-4 gap-1.5 shrink-0 self-start sm:self-auto disabled:opacity-50 disabled:cursor-not-allowed">
          <RotateCcw className="w-4 h-4" aria-hidden="true" /> {isCashOrder(order) ? 'Record cash already returned' : order.total_cents === 0 ? 'Cancel free tickets' : 'Refund'}
         </button>
        ) : !pendingRequest && (
         <button type="button" aria-expanded="true" aria-controls={`refund-panel-${order.id}`} disabled={processing || accessRefreshing} onClick={closeRefundPanel} className="btn-secondary min-h-12 shrink-0 self-start">Close refund panel</button>
        )}
       </div>

       {order.external_refund_verification_required === true && <p id={`external-refund-review-${order.id}`} className="mt-3 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950">
        Refunds made outside HåfaPass need verification. Ask support to review the buyer balance before starting another return.{' '}
        <SupportLink subject={`Verify external refunds for order ${order.id}`} className="font-semibold underline">Contact support to verify refunds</SupportLink>
       </p>}
       {order.refunds?.filter(refund => refund.manual_record && refund.provider === 'door_cash').map(refund => <p key={refund.id} className="mt-3 break-words text-sm text-neutral-700">Cash return recorded: ${(refund.amount_cents / 100).toFixed(2)} · {refund.cash_return?.reference} · Returned {formatPlatformDateTime(refund.cash_return?.returned_at)} · Recorded {formatPlatformDateTime(refund.recorded_at)} · Organizer custody. No money transferred by HåfaPass.</p>)}
       {refundingId === order.id && !verificationBlocksNewReturn(order) && (
        <div id={`refund-panel-${order.id}`} className="mt-4 space-y-4 border-t border-neutral-200 pt-4 text-base">
         {pendingRequest ? (
          <>
           {refundForm.ticketIds.length > 0 && <p>{pluralize(refundForm.ticketIds.length, 'ticket')} in this saved request.</p>}
           {refundForm.reason && <p className="break-words">Saved reason · {refundForm.reason}</p>}
           {pendingRequest.payload.cash_return && <p className="break-words">Saved cash return reference {refundForm.cashReference} · {formatPlatformDateTime(refundForm.cashReturnedAt)}</p>}
           <button type="button" className="btn-secondary min-h-12" disabled={processing || accessRefreshing} onClick={() => handleRefund(order.id)}>
            {pendingRequest.financeReview || order.external_refund_verification_required ? 'Check saved refund status' : pendingRequest.payload.cash_return ? 'Retry saved cash return record' : 'Retry saved refund'}
           </button>
          </>
         ) : refundOptions?.order_id !== order.id ? (
          optionsError ? <p role="alert">Ticket availability could not be loaded. <button type="button" className="min-h-12 font-semibold underline" onClick={() => setOptionsAttempt(attempt => attempt + 1)}>Try again</button></p>
           : <p role="status">Checking which tickets can be refunded…</p>
         ) : (
          <>
           {refundOptions.unavailable_reason && <p role="status" className="rounded-lg bg-amber-50 p-3 text-amber-950">{refundOptions.unavailable_reason}</p>}
           <fieldset className="grid gap-2 sm:grid-cols-3" disabled={processing || accessRefreshing}>
            <legend className="mb-2 font-semibold text-neutral-900">How would you like to handle this order?</legend>
            {[['tickets', refundOptions.is_free_order ? 'Cancel specific free tickets' : 'Refund specific tickets'],
              ['full', refundOptions.is_free_order ? 'Cancel all unused tickets' : 'Full order refund'],
              ...(!refundOptions.is_free_order && customAmountLimit > 0 ? [['partial', 'Custom dollar amount']] : [])].map(([type, label]) => (
              <label key={type} className={`flex min-h-12 cursor-pointer items-center gap-2 rounded-lg border p-3 font-medium text-neutral-900 ${refundForm.type === type ? 'border-brand-700 bg-brand-50' : 'border-neutral-500'}`}>
               <input type="radio" name={`refund-mode-${order.id}`} checked={refundForm.type === type} onChange={() => selectMode(type)} className="h-5 w-5 shrink-0 accent-brand-700 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2" />
               {label}
              </label>
            ))}
           </fieldset>
           {refundForm.type === 'tickets' && <RefundTicketChecklist options={refundOptions} selectedIds={refundForm.ticketIds}
            timeZone={eventTimeZone} onToggle={toggleTicket} disabled={processing || accessRefreshing} />}
           {refundForm.type === 'partial' && <p>Returns money without cancelling any QR tickets (use for partial discounts or partially used passes).</p>}
           {refundForm.type === 'full' && !refundOptions.is_free_order && <p>Returns the remaining {formatDollars(refundOptions.refundable_cents)} and cancels the unused tickets on this order.</p>}
           {isTicketRequest && !refundOptions.unavailable_reason && (
            <div className="rounded-lg bg-neutral-100 p-3" aria-live="polite">
             <p className="font-semibold text-neutral-900">{selectedTickets.length} of {selectableTickets.length} {refundOptions.is_free_order ? 'free tickets selected' : `selected → ${formatDollars(selectedAmount)}`}</p>
             {selectedAmount > refundOptions.refundable_cents ? <p className="text-red-800">These tickets exceed the remaining {formatDollars(refundOptions.refundable_cents)}. Choose fewer tickets or enter a custom amount.</p> :
              selectedTickets.length > 0 && <p id={`refund-confirm-${order.id}`}>{refundOptions.is_free_order
               ? `Cancels the ${cancellationTarget} and returns ${inventoryTarget} to inventory.`
               : `Cancels the ${cancellationTarget} and ${isCashOrder(order) ? `records the ${formatDollars(selectedAmount)} already returned in cash.` : `refunds ${formatDollars(selectedAmount)} to the buyer's card.`}`}</p>}
            </div>
           )}
           {!refundOptions.unavailable_reason && <>
            {isCashOrder(order) && <>
             <div className="flex items-start gap-2 rounded-lg bg-amber-50 p-3 text-amber-950">
              <AlertTriangle className="mt-1 h-4 w-4 shrink-0" aria-hidden="true" />
              <p>The organizer holds door cash and must return it to the buyer first. HåfaPass does not send money. Enter the repayment reference, when you returned the cash, and why.</p>
             </div>
             <div className="grid gap-3 sm:grid-cols-2">
              <div><label htmlFor={`cash-reference-${order.id}`} className="mb-1 block font-medium">Cash return reference</label>
               <input id={`cash-reference-${order.id}`} aria-invalid={cashInvalidField === `cash-reference-${order.id}` || undefined} aria-describedby={cashInvalidField === `cash-reference-${order.id}` ? 'refund-notice' : undefined} required maxLength={255} disabled={processing || accessRefreshing} value={refundForm.cashReference} onChange={event => setRefundForm({ ...refundForm, cashReference: event.target.value })} className="input min-h-12 border-neutral-500 text-base hover:border-neutral-700 focus:border-brand-700 focus:ring-brand-700" /></div>
              <div><label htmlFor={`cash-returned-at-${order.id}`} className="mb-1 block font-medium">Cash returned at (your device time)</label>
               <input id={`cash-returned-at-${order.id}`} type="datetime-local" step="1" aria-invalid={cashInvalidField === `cash-returned-at-${order.id}` || undefined} aria-describedby={cashInvalidField === `cash-returned-at-${order.id}` ? 'refund-notice' : undefined} required min={new Date(Date.parse(order.created_at) - new Date(order.created_at).getTimezoneOffset() * 60000).toISOString().slice(0, 19)} disabled={processing || accessRefreshing} value={refundForm.cashReturnedAt} onChange={event => setRefundForm({ ...refundForm, cashReturnedAt: event.target.value })} className="input min-h-12 border-neutral-500 text-base hover:border-neutral-700 focus:border-brand-700 focus:ring-brand-700" /></div>
             </div>
            </>}
            <div className="grid gap-3 sm:grid-cols-2">
             {refundForm.type === 'partial' && <div>
              <label htmlFor={`refund-amount-${order.id}`} className="mb-1 block font-medium">Amount ($)</label>
              <input id={`refund-amount-${order.id}`} disabled={processing || accessRefreshing} type="text" inputMode="decimal"
               value={refundForm.amount} onChange={event => setRefundForm({ ...refundForm, amount: event.target.value })}
               aria-invalid={(Boolean(partialAmountError) && Boolean(refundForm.amount)) || undefined} aria-describedby={partialAmountError ? `refund-amount-error-${order.id}` : undefined}
               className="input min-h-12 border-neutral-500 text-base hover:border-neutral-700 focus:border-brand-700 focus:ring-brand-700" placeholder="0.00" />
              {partialAmountError && <p id={`refund-amount-error-${order.id}`} className="mt-2 text-red-800">{partialAmountError}</p>}
             </div>}
             <div>
              <label htmlFor={`refund-reason-${order.id}`} className="mb-1 block font-medium">{isCashOrder(order) ? 'Reason (required)' : 'Reason (optional)'}</label>
              <input id={`refund-reason-${order.id}`} aria-invalid={cashInvalidField === `refund-reason-${order.id}` || undefined} aria-describedby={cashInvalidField === `refund-reason-${order.id}` ? 'refund-notice' : undefined} disabled={processing || accessRefreshing} value={refundForm.reason} onChange={event => setRefundForm({ ...refundForm, reason: event.target.value })}
               className="input min-h-12 border-neutral-500 text-base hover:border-neutral-700 focus:border-brand-700 focus:ring-brand-700" placeholder="e.g. Buyer request" />
             </div>
            </div>
            <button type="button" onClick={() => handleRefund(order.id)} disabled={processing || accessRefreshing || blockedSelection || Boolean(partialAmountError)}
             aria-describedby={partialAmountError ? `refund-amount-error-${order.id}` : isTicketRequest && selectedTickets.length && !blockedSelection ? `refund-confirm-${order.id}` : undefined}
             className="btn-danger min-h-12 gap-2">
             {processing ? <Loader2 className="h-4 w-4 animate-spin" aria-hidden="true" /> : <Check className="h-4 w-4" aria-hidden="true" />}
             {isCashOrder(order) ? 'Record cash already returned' : refundOptions.is_free_order ? 'Cancel selected free tickets' : isTicketRequest
              ? selectedAmount > 0 ? `Refund ${formatDollars(selectedAmount)}` : 'Refund selected tickets'
              : refundConfirmLabel({ refundable_cents: refundForm.type === 'partial' ? customAmountLimit : refundOptions.refundable_cents }, refundForm)}
            </button>
           </>}
          </>
         )}
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
