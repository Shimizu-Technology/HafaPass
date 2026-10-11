import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import EventWorkspace from '../../components/EventWorkspace'
import { useState, useEffect, useCallback, useRef } from 'react'
import { useParams } from 'react-router-dom'
import { Loader2, ShoppingCart, CreditCard, Banknote, Plus, Minus, CheckCircle2 } from 'lucide-react'
import apiClient from '../../api/client'
import QRCode from '../../components/QRCode'
import useLaunchCapabilities from '../../hooks/useLaunchCapabilities'
import SeatSelector from '../../components/SeatSelector'

export default function BoxOfficePage() {
 const { id } = useParams()
 const identity = useOrganizerIdentity()
 const visit = useOrganizerPageVisit(`/dashboard/events/${id}/box-office`)
 if (!visit.active) return null
 if (!identity.ready) return <p role="status" className="p-6">Preparing your account…</p>
 return <BoxOfficePageSession key={`${identity.accountKey}:${identity.organizationId}:${id}:${visit.generation}`} id={id} identity={identity} />
}

function BoxOfficePageSession({ id, identity }) {
 const { current, beginRequest } = useOrganizerRequests(identity, `/dashboard/events/${id}/box-office`)
 const requestApi = useCallback(async (method, url, payload, options = {}) => {
  const request = beginRequest()
  if (!request) throw new DOMException('Page context changed', 'AbortError')
  try {
   const response = method === 'get' || method === 'delete'
    ? await apiClient[method](url, { ...payload, ...request.config })
    : await apiClient[method](url, payload, { ...options, ...request.config })
   if (!request.current()) throw new DOMException('Page context changed', 'AbortError')
   return response
  } finally { request.release() }
 }, [beginRequest])
  const capabilities = useLaunchCapabilities()
  const [event, setEvent] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [quantities, setQuantities] = useState({})
  const [buyerName, setBuyerName] = useState('')
  const [buyerEmail, setBuyerEmail] = useState('')
  const [paymentMethod, setPaymentMethod] = useState('door_cash')
  const [submitting, setSubmitting] = useState(false)
  const [lastOrder, setLastOrder] = useState(null)
  const [summary, setSummary] = useState(null)
  const eventLoadGeneration = useRef(0)
  const summaryLoadGeneration = useRef(0)
  const [cardAccount, setCardAccount] = useState(null)
  const [saleError, setSaleError] = useState(null)
  const [seatReservation, setSeatReservation] = useState(null)
  const [seatSelectorKey, setSeatSelectorKey] = useState(0)
  const legacyStorageKey = `hafapass:pending-box-office:${identity.owner}:${id}`
  const saleStorageKey = `hafapass:pending-box-office:v2:${identity.owner}:${identity.organizationId ?? 'default'}:${id}`
  const authorizedEvent = useRef(false)
  const [accessRefreshing, setAccessRefreshing] = useState(false)
  const importedLegacyKey = useRef(null)
  const [pendingSale, setPendingSale] = useState(() => {
    try { return JSON.parse(window.sessionStorage.getItem(saleStorageKey) || 'null') } catch { return null }
  })
  const pendingSaleRef = useRef(pendingSale)
  const saleLocked = submitting || accessRefreshing || Boolean(pendingSale)


  const fetchEvent = useCallback(async () => {
    const generation = ++eventLoadGeneration.current
    const canApply = () => current() && generation === eventLoadGeneration.current
    if (!current()) return
    setError(null)
    authorizedEvent.current = false
    setAccessRefreshing(true)
    try {
      const res = await requestApi('get', `/organizer/events/${id}`)
      if (!canApply()) return
      if (String(res.data.id) !== String(id) || res.data.organization_id == null || (identity.organizationId != null && String(res.data.organization_id) !== String(identity.organizationId))) {
        throw new Error('Event authorization does not match this page')
      }
      if (res.data.permissions?.box_office !== true) throw new Error('Box office access is not available for your role')
      authorizedEvent.current = true
      // Legacy operations have no organization namespace. Import only after
      // this bound event response proves their original event is accessible.
      try {
        const legacy = JSON.parse(window.sessionStorage.getItem(legacyStorageKey) || 'null')
        if (legacy?.key && legacy.payload && !pendingSaleRef.current) {
          window.sessionStorage.setItem(saleStorageKey, JSON.stringify(legacy))
          pendingSaleRef.current = legacy
          setPendingSale(legacy)
        }
        if (legacy?.key === pendingSaleRef.current?.key) importedLegacyKey.current = legacy.key
      } catch { /* A malformed saved operation is never submitted. */ }
      setEvent(res.data)
      // Initialize quantities to 0
      const initial = {}
      res.data.ticket_types?.forEach(tt => { initial[tt.id] = 0 })
      if (!pendingSaleRef.current) setQuantities(initial)
      else {
        const payload = pendingSaleRef.current.payload
        setQuantities(Object.fromEntries(payload.line_items.map(item => [item.ticket_type_id, item.quantity])))
        setBuyerName(payload.buyer_name || '')
        setBuyerEmail(payload.buyer_email || '')
        setPaymentMethod(payload.payment_method)
      }
    } catch {
      if (!canApply()) return
      setError('Failed to load event.')
    } finally {
      if (canApply()) { setLoading(false); setAccessRefreshing(false) }
    }
  }, [id, requestApi, current, identity.organizationId, legacyStorageKey, saleStorageKey])

  const fetchSummary = useCallback(async () => {
    const generation = ++summaryLoadGeneration.current
    const canApply = () => current() && generation === summaryLoadGeneration.current
    if (!current()) return
    try {
      const res = await requestApi('get', `/organizer/events/${id}/box_office/summary`)
      if (!canApply()) return
      setSummary(res.data)
    } catch {
      // The confirmed sale and saved operation remain independent of summary availability.
    }
  }, [id, requestApi, current])

  const fetchCardAccount = useCallback(async () => {
    try {
      const res = await requestApi('get', '/organizer/card_present_account')
      if (!current()) return
      setCardAccount(res.data)
    } catch {
      if (!current()) return
      setCardAccount({ status: 'unavailable', payment_ready: false })
    }
  }, [requestApi, current])

  useEffect(() => { fetchEvent(); fetchSummary(); fetchCardAccount() }, [fetchCardAccount, fetchEvent, fetchSummary])

  const updateQty = (ttId, delta) => {
    setQuantities(prev => ({
      ...prev,
      [ttId]: Math.max(0, (prev[ttId] || 0) + delta)
    }))
  }

  const totalItems = Object.values(quantities).reduce((s, q) => s + q, 0)
  const totalCents = seatReservation
    ? seatReservation.seats.reduce((sum, seat) => sum + seat.price_cents, 0)
    : event?.ticket_types?.reduce((s, tt) => s + (quantities[tt.id] || 0) * tt.price_cents, 0) || 0

  const handleSale = async () => {
    if (!current() || !authorizedEvent.current) return
    if (submitting || (!pendingSaleRef.current && totalItems === 0)) return
    const recoveringSavedSale = Boolean(pendingSaleRef.current)
    setSubmitting(true)
    setLastOrder(null)
    setSaleError(null)

    const line_items = Object.entries(quantities)
      .filter(([, qty]) => qty > 0)
      .map(([ttId, qty]) => ({ ticket_type_id: parseInt(ttId), quantity: qty }))

    try {
      let sale = pendingSaleRef.current
      if (!sale) {
        sale = {
          key: `box-office-${crypto.randomUUID()}`,
          payload: {
            line_items,
            seat_hold_token: seatReservation?.seatHoldToken,
            payment_method: paymentMethod,
            buyer_name: buyerName || undefined,
            buyer_email: buyerEmail || undefined,
          },
          total_cents: totalCents,
          created_at: new Date().toISOString(),
        }
        // Persist before recording the sale: a lost response or reload keeps the same cash or card identity.
        window.sessionStorage.setItem(saleStorageKey, JSON.stringify(sale))
        pendingSaleRef.current = sale
        setPendingSale(sale)
      }
      const res = await requestApi('post', `/organizer/events/${id}/box_office`, sale.payload, { headers: { 'Idempotency-Key': sale.key } })
      if (!current()) return
      setLastOrder(res.data)
      window.sessionStorage.removeItem(saleStorageKey)
      if (importedLegacyKey.current === pendingSaleRef.current?.key) window.sessionStorage.removeItem(legacyStorageKey)
      pendingSaleRef.current = null
      setPendingSale(null)
      // Reset form
      const reset = {}
      event.ticket_types?.forEach(tt => { reset[tt.id] = 0 })
      setQuantities(reset)
      setBuyerName('')
      setBuyerEmail('')
      setSeatReservation(null)
      setSeatSelectorKey(value => value + 1)
      fetchSummary()
      fetchEvent() // refresh availability
    } catch (err) {
      if (!current()) return
      const data = err.response?.data
      const uncertain = (recoveringSavedSale && data?.reconciliation_required !== false) || !err.response || err.response.status >= 500 || [408, 409, 429].includes(err.response.status) || Boolean(data?.reconciliation_required)
      setSaleError({
        message: data?.error || (uncertain ? 'The connection was interrupted. This sale may have completed. Retry this saved sale or ask a manager to verify its outcome.' : 'Failed to process sale.'),
        reconciliationRequired: uncertain,
        orderId: data?.order_id,
      })
      if (!uncertain) {
        window.sessionStorage.removeItem(saleStorageKey)
      if (importedLegacyKey.current === pendingSaleRef.current?.key) window.sessionStorage.removeItem(legacyStorageKey)
        pendingSaleRef.current = null
        setPendingSale(null)
      }
    } finally {
      if (current()) setSubmitting(false)
    }
  }

  if (loading) return <div className="flex justify-center py-20"><Loader2 className="w-8 h-8 text-brand-500 animate-spin" /></div>
  if (error) return <div role="alert" className="max-w-2xl mx-auto px-4 py-8 text-center text-red-700"><p>{error}</p><button type="button" onClick={fetchEvent} className="btn-primary mt-4">Retry event</button></div>

  return (
    <EventWorkspace eventId={id} event={event}><div className="max-w-4xl mx-auto">
      {/* Header */}

      <div className="flex items-center gap-3 mb-8">
        <ShoppingCart className="w-6 h-6 text-brand-600" />
        <div>
          <h2 className="text-2xl font-bold text-neutral-900 font-display">Box Office</h2>
          <p className="text-sm text-neutral-500">{event.title}</p>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
        {/* Left: Ticket Selection */}
        <div className="lg:col-span-2 space-y-4">
          {pendingSale && <div className="rounded-xl border border-amber-300 bg-amber-50 p-4 text-sm text-amber-950" role="status">
            <p className="font-semibold">A saved sale needs confirmation</p>
            <p className="mt-1">Retry uses the original sale and payment identity. Do not create another sale or collect another payment until its outcome is confirmed.</p>
            <p className="mt-2 break-all font-mono text-xs">Reference: {pendingSale.key}</p>
          </div>}
          <h2 className="text-lg font-semibold text-neutral-900">Select Tickets</h2>

          {event.assigned_seating ? (
            <div className="rounded-2xl border border-neutral-200 bg-white p-4 sm:p-5">
              {saleLocked ? <p className="text-sm text-neutral-600">Seat selection is locked while the saved sale is being confirmed.</p> : <SeatSelector
                key={seatSelectorKey}
                event={event}
                source="box_office"
                reserveLabel="Hold seats for this sale"
                onReserved={(reservation) => {
                  const next = {}
                  event.ticket_types?.forEach(ticketType => { next[ticketType.id] = 0 })
                  reservation.lineItems.forEach(item => { next[item.ticket_type_id] = item.quantity })
                  setQuantities(next)
                  setSeatReservation(reservation)
                }}
              />}
              {seatReservation && (
                <div className="mt-4 rounded-xl border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-900" role="status">
                  <p className="font-semibold">Seats held for this sale</p>
                  <p className="mt-1">{seatReservation.seats.map(seat => seat.display_label).join(', ')}</p>
                </div>
              )}
            </div>
          ) : event.ticket_types?.map(tt => {
            const available = tt.door_available_quantity ?? (tt.quantity_available == null ? Number.MAX_SAFE_INTEGER : tt.quantity_available - tt.quantity_sold)
            return (
              <div key={tt.id} className="flex items-center justify-between p-4 sm:p-5 bg-white border border-neutral-200 rounded-xl">
                <div className="min-w-0 mr-4">
                  <p className="font-medium text-neutral-900 truncate">{tt.name}</p>
                  <p className="text-sm text-neutral-500">
                    ${(tt.price_cents / 100).toFixed(2)} · {available === Number.MAX_SAFE_INTEGER ? 'Unlimited' : `${available} at door`}
                  </p>
                </div>
                <div className="flex items-center gap-3 shrink-0">
                  <button
                    onClick={() => updateQty(tt.id, -1)}
                    aria-label={`Remove ${tt.name}`}
                    disabled={saleLocked || !quantities[tt.id]}
                    className="w-11 h-11 sm:w-12 sm:h-12 flex items-center justify-center rounded-xl bg-neutral-100 hover:bg-neutral-200 disabled:opacity-30 transition"
                  >
                    <Minus className="w-5 h-5" />
                  </button>
                  <span className="w-10 text-center text-xl font-semibold tabular-nums">{quantities[tt.id] || 0}</span>
                  <button
                    onClick={() => updateQty(tt.id, 1)}
                    aria-label={`Add ${tt.name}`}
                    disabled={saleLocked || (quantities[tt.id] || 0) >= available}
                    className="w-11 h-11 sm:w-12 sm:h-12 flex items-center justify-center rounded-xl bg-brand-500 text-white hover:bg-brand-600 disabled:opacity-30 transition"
                  >
                    <Plus className="w-5 h-5" />
                  </button>
                </div>
              </div>
            )
          })}

          {/* Buyer Info (optional) */}
          <div className="mt-6">
            <h2 className="text-lg font-semibold text-neutral-900 mb-3">Buyer Info (Optional)</h2>
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <input
                type="text"
                aria-label="Buyer name" disabled={saleLocked} placeholder="Name"
                value={buyerName}
                onChange={e => setBuyerName(e.target.value)}
                className="px-4 py-2.5 rounded-xl border border-neutral-300 text-sm focus:outline-none focus:ring-2 focus:ring-brand-500/20 focus:border-brand-500"
              />
              <input
                type="email"
                aria-label="Buyer email" disabled={saleLocked} placeholder="Email"
                value={buyerEmail}
                onChange={e => setBuyerEmail(e.target.value)}
                className="px-4 py-2.5 rounded-xl border border-neutral-300 text-sm focus:outline-none focus:ring-2 focus:ring-brand-500/20 focus:border-brand-500"
              />
            </div>
          </div>

          {/* Payment Method */}
          <div className="mt-6">
            <h2 className="text-lg font-semibold text-neutral-900 mb-3">Payment Method</h2>
            <div className="grid grid-cols-2 gap-3">
              <button
                disabled={saleLocked} onClick={() => setPaymentMethod('door_cash')}
                className={`flex-1 flex items-center justify-center gap-2 px-4 py-3 rounded-xl border-2 text-sm font-medium transition ${
                  paymentMethod === 'door_cash'
                    ? 'border-brand-500 bg-brand-50 text-brand-700'
                    : 'border-neutral-200 text-neutral-600 hover:border-neutral-300'
                }`}
              >
                <Banknote className="w-5 h-5" /> Cash
              </button>
              <button
                onClick={() => setPaymentMethod('door_card')}
                disabled={saleLocked || !capabilities.door_card || !cardAccount?.payment_ready}
                className={`flex-1 flex items-center justify-center gap-2 px-4 py-3 rounded-xl border-2 text-sm font-medium transition ${
                  paymentMethod === 'door_card'
                    ? 'border-brand-500 bg-brand-50 text-brand-700'
                    : 'border-neutral-200 text-neutral-600 hover:border-neutral-300'
                } disabled:cursor-not-allowed disabled:opacity-40`}
              >
                <CreditCard className="w-5 h-5" /> Card at Door
              </button>
            </div>
            {(!capabilities.door_card || !cardAccount?.payment_ready) && (
              <p className="mt-2 text-xs text-amber-700">Card sales stay disabled until a Bank of Hawaii Clover merchant and terminal are verified by HafaPass. Never record a card sale manually.</p>
            )}
          </div>

          {saleError && (
            <div className={`rounded-xl border p-4 text-sm ${saleError.reconciliationRequired ? 'border-amber-300 bg-amber-50 text-amber-900' : 'border-red-200 bg-red-50 text-red-800'}`}>
              <p className="font-semibold">{saleError.reconciliationRequired ? paymentMethod === 'door_card' ? 'Do not charge the card again' : 'Do not record another cash sale' : 'Sale not completed'}</p>
              <p className="mt-1">{saleError.message}</p>
              {saleError.orderId && <p className="mt-1 font-mono text-xs">Order #{saleError.orderId}</p>}
              {saleError.reconciliationRequired && <p className="mt-2">Use Retry saved sale to check the original sale, or ask a manager to compare {paymentMethod === 'door_card' ? 'the terminal receipt' : 'the cash sale records'}. The saved reference survives a reload in this tab.</p>}
            </div>
          )}

          {/* Process Sale Button */}
          <button
            onClick={handleSale}
            disabled={submitting || (!pendingSale && (totalItems === 0 || (event.assigned_seating && !seatReservation)))}
            className="w-full mt-6 py-4 rounded-xl bg-brand-600 text-white font-semibold text-lg hover:bg-brand-700 disabled:opacity-40 disabled:cursor-not-allowed transition flex items-center justify-center gap-2"
          >
            {submitting ? (
              <><Loader2 className="w-5 h-5 animate-spin" /> {paymentMethod === 'door_card' ? 'Waiting for terminal…' : 'Processing…'}</>
            ) : (
              <>{pendingSale ? 'Retry saved sale' : 'Process Sale'} · ${((pendingSale?.total_cents ?? totalCents) / 100).toFixed(2)} ({totalItems} ticket{totalItems !== 1 ? 's' : ''})</>
            )}
          </button>
        </div>

        {/* Right: Summary + Last Order */}
        <div className="space-y-6">
          {/* Session Summary */}
          {summary && (
            <div className="p-5 bg-white border border-neutral-200 rounded-xl">
              <h3 className="text-sm font-semibold text-neutral-500 uppercase tracking-wider mb-3">Door Sales Summary</h3>
              <div className="space-y-2">
                <div className="flex justify-between">
                  <span className="text-sm text-neutral-600">Total Orders</span>
                  <span className="font-semibold">{summary.total_orders}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-sm text-neutral-600">Total Tickets</span>
                  <span className="font-semibold">{summary.total_tickets}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-sm text-neutral-600">Cash</span>
                  <span className="font-semibold">${((summary.by_payment_method?.door_cash || 0) / 100).toFixed(2)}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-sm text-neutral-600">Card</span>
                  <span className="font-semibold">${((summary.by_payment_method?.door_card || 0) / 100).toFixed(2)}</span>
                </div>
                <div className="flex justify-between pt-2 border-t border-neutral-100">
                  <span className="text-sm font-medium text-neutral-900">Total Revenue</span>
                  <span className="font-bold text-brand-600">${((summary.total_revenue_cents || 0) / 100).toFixed(2)}</span>
                </div>
              </div>
            </div>
          )}

          {/* Last Order */}
          {lastOrder && (
            <div className="p-5 bg-emerald-50 border border-emerald-200 rounded-xl">
              <div className="flex items-center gap-2 mb-3">
                <CheckCircle2 className="w-5 h-5 text-emerald-600" />
                <h3 className="text-sm font-semibold text-emerald-800">Sale Complete!</h3>
              </div>
              <p className="text-sm text-emerald-700 mb-2">{lastOrder.buyer_name} · ${(lastOrder.total_cents / 100).toFixed(2)}</p>
              <div className="space-y-3">
                {lastOrder.tickets?.map(ticket => (
                  <div key={ticket.id} className="bg-white p-3 rounded-lg border border-emerald-100">
                    <p className="text-xs text-neutral-500 mb-1">{ticket.ticket_type.name}</p>
                    <div className="flex justify-center">
                      <QRCode value={ticket.scan_credential} size={120} />
                    </div>
                    <p className="text-xs text-center text-neutral-400 mt-1 font-mono">HP-T{ticket.id}</p>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      </div>
    </div></EventWorkspace>
  )
}
