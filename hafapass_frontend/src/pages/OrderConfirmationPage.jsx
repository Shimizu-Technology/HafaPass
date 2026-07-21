import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom'
import { AlertTriangle, CheckCircle, ChevronRight, Clock3, Download, Loader2, Mail, RefreshCw } from 'lucide-react'
import apiClient from '../api/client'
import SEO from '../components/SEO'
import { formatEventDate, formatEventTime } from '../utils/eventTime'
import { clearActiveCheckout, getOrderAccess, orderAccessHeaders, saveOrderAccess } from '../utils/orderAccess'

const finalStatuses = new Set(['completed', 'partially_refunded', 'refunded', 'cancelled', 'expired'])

export default function OrderConfirmationPage() {
  const { id } = useParams()
  const location = useLocation()
  const navigate = useNavigate()
  const [order, setOrder] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [resendState, setResendState] = useState('idle')
  const [decisionState, setDecisionState] = useState('idle')
  const [cancellingTicketId, setCancellingTicketId] = useState(null)
  const [rotatingTicketId, setRotatingTicketId] = useState(null)
  const [transferringTicketId, setTransferringTicketId] = useState(null)
  const [ticketActionError, setTicketActionError] = useState(null)

  useEffect(() => {
    const params = new URLSearchParams(location.search)
    const token = params.get('guest_token')
    if (!token) return
    saveOrderAccess(id, token)
    params.delete('guest_token')
    navigate({ pathname: location.pathname, search: params.toString() ? `?${params}` : '' }, { replace: true })
  }, [id, location.pathname, location.search, navigate])

  const fetchOrder = useCallback(async () => {
    try {
      const response = await apiClient.get(`/orders/${id}`, { headers: orderAccessHeaders(id) })
      setOrder(response.data)
      setError(null)
      if (response.data.event?.slug) clearActiveCheckout(response.data.event.slug)
    } catch (err) {
      setError(err.response?.status === 404
        ? 'We could not securely open this order. Use the recovery page with your order reference and email.'
        : 'Unable to refresh this order right now. Please try again.')
    } finally {
      setLoading(false)
    }
  }, [id])

  useEffect(() => {
    fetchOrder()
  }, [fetchOrder, location.search])

  useEffect(() => {
    if (!order || finalStatuses.has(order.status)) return undefined
    const interval = window.setInterval(fetchOrder, 3000)
    return () => window.clearInterval(interval)
  }, [fetchOrder, order])

  const formatPrice = (cents = 0) => cents === 0 ? 'Free' : `$${(cents / 100).toFixed(2)}`
  const event = order?.event
  const isProcessing = order && !finalStatuses.has(order.status)
  const ticketsAvailable = ['completed', 'partially_refunded', 'refunded', 'cancelled'].includes(order?.status) && order?.tickets?.length > 0
  const change = order?.latest_event_change
  const refundNeedsRetry = change?.response === 'refund_requested' && order?.tickets?.some(ticket => (
    ticket.status === 'issued' && ticket.refundable_cents >= 0
  ))
  const canRespondToChange = change && (!change.response || refundNeedsRetry) && ['cancelled', 'postponed', 'rescheduled'].includes(change.change_type)
  const decisionBusy = ['accepted', 'refund_requested'].includes(decisionState)
  const orderHeaders = useMemo(() => orderAccessHeaders(id), [id])

  async function resend() {
    setResendState('sending')
    try {
      await apiClient.post(`/orders/${id}/resend`, {}, { headers: orderHeaders })
      setResendState('sent')
    } catch (err) {
      setResendState(err.response?.status === 429 ? 'cooldown' : 'error')
    }
  }

  async function respondToChange(decision) {
    setDecisionState(decision)
    try {
      await apiClient.post(`/orders/${id}/event_change_response`, {
        event_change_id: change.id,
        decision,
      }, {
        headers: {
          ...orderHeaders,
          ...(decision === 'refund_requested' ? { 'Idempotency-Key': crypto.randomUUID() } : {}),
        },
      })
      await fetchOrder()
      setDecisionState('done')
    } catch {
      setDecisionState('error')
    }
  }

  async function cancelTicket(ticket) {
    if (!window.confirm(`Cancel this ${ticket.ticket_type.name} ticket? This cannot be undone.`)) return
    setCancellingTicketId(ticket.id)
    try {
      await apiClient.post(`/orders/${id}/tickets/${ticket.id}/cancel`, {}, {
        headers: { ...orderHeaders, 'Idempotency-Key': crypto.randomUUID() },
      })
      await fetchOrder()
    } finally {
      setCancellingTicketId(null)
    }
  }

  async function rotateTicket(ticket) {
    if (!window.confirm('Replace this ticket’s entry QR? Any saved copy of the old QR will stop working.')) return
    setRotatingTicketId(ticket.id)
    try {
      await apiClient.post(`/orders/${id}/tickets/${ticket.id}/rotate_scan`, {}, { headers: orderHeaders })
    } finally {
      setRotatingTicketId(null)
    }
  }

  async function transferTicket(ticket) {
    const recipientEmail = window.prompt('Enter the recipient email address. They must sign in with this email to accept the ticket.')
    if (!recipientEmail) return
    setTransferringTicketId(ticket.id)
    setTicketActionError(null)
    try {
      await apiClient.post(`/orders/${id}/tickets/${ticket.id}/transfer`, { recipient_email: recipientEmail }, { headers: orderHeaders })
      window.alert('Transfer invitation sent. You retain control until the recipient accepts it.')
    } catch (err) {
      setTicketActionError(err.response?.data?.error || 'Unable to transfer this ticket.')
    } finally {
      setTransferringTicketId(null)
    }
  }

  if (loading) return <div className="flex min-h-[60vh] items-center justify-center"><Loader2 className="h-8 w-8 animate-spin text-brand-500" /></div>

  if (error || !order) {
    return (
      <div className="mx-auto max-w-lg px-4 py-16">
        <div className="card p-8 text-center">
          <AlertTriangle className="mx-auto mb-3 h-10 w-10 text-amber-500" />
          <p className="mb-5 text-neutral-700">{error}</p>
          <Link to="/orders/recover" className="btn-primary">Recover my order</Link>
        </div>
      </div>
    )
  }

  return (
    <div className="min-h-screen bg-neutral-50">
      <SEO title={`Order ${order.reference}`} />
      <div className="mx-auto max-w-2xl px-4 py-8 sm:px-6">
        <div className="mb-7 text-center">
          <div className={`mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-full ${isProcessing ? 'bg-amber-100' : 'bg-emerald-100'}`}>
            {isProcessing ? <Clock3 className="h-8 w-8 text-amber-700" /> : <CheckCircle className="h-8 w-8 text-emerald-700" />}
          </div>
          <h1 className="text-3xl font-bold tracking-tight text-neutral-950">
            {isProcessing ? 'Payment is processing' : order.status === 'cancelled' || order.status === 'expired' ? 'Order closed' : 'Your order is confirmed'}
          </h1>
          <p className="mt-2 text-neutral-500">Order {order.reference} · {order.buyer_email}</p>
          {isProcessing && <p className="mt-2 text-sm text-amber-700">This page refreshes automatically. Do not submit another payment.</p>}
        </div>

        {change && (
          <section className="mb-6 rounded-2xl border border-amber-200 bg-amber-50 p-5">
            <h2 className="font-semibold text-amber-950">Event {change.change_type}</h2>
            <p className="mt-1 text-sm text-amber-900">{change.reason || 'The organizer changed this event. Review the updated details below.'}</p>
            {change.response && <p className="mt-3 text-sm font-medium text-amber-950">Your response: {change.response.replace('_', ' ')}</p>}
            {canRespondToChange && (
              <div className="mt-4 flex flex-col gap-2 sm:flex-row">
                {!change.response && (
                  <button className="btn-secondary" disabled={decisionBusy} onClick={() => respondToChange('accepted')}>Keep my tickets</button>
                )}
                <button className="rounded-xl border border-red-300 bg-white px-4 py-2.5 text-sm font-semibold text-red-700" disabled={decisionBusy} onClick={() => respondToChange('refund_requested')}>{refundNeedsRetry ? 'Retry refund' : 'Request refund'}</button>
              </div>
            )}
            {decisionState === 'error' && <p className="mt-3 text-sm text-red-700">We could not save that choice. Please try again.</p>}
          </section>
        )}

        <section className="card mb-6 overflow-hidden">
          <div className="border-b border-neutral-100 p-5 sm:p-6">
            <p className="text-xs font-semibold uppercase tracking-wider text-brand-600">{event.status}</p>
            <h2 className="mt-1 text-xl font-bold text-neutral-950">{event.title}</h2>
            <p className="mt-2 text-sm text-neutral-600">{formatEventDate(event.starts_at, event.timezone, { weekday: 'long' })} · {formatEventTime(event.starts_at, event.timezone)}</p>
            <p className="text-sm text-neutral-500">{event.venue_name}{event.venue_address ? ` · ${event.venue_address}` : ''}</p>
          </div>
          <div className="space-y-2 p-5 text-sm sm:p-6">
            {order.order_items.map(item => (
              <div key={item.id} className="flex justify-between gap-4"><span>{item.name} × {item.quantity}</span><span>{formatPrice(item.subtotal_cents)}</span></div>
            ))}
            <div className="flex justify-between border-t border-neutral-100 pt-3 text-neutral-600"><span>Service fee</span><span>{formatPrice(order.service_fee_cents)}</span></div>
            {order.discount_cents > 0 && <div className="flex justify-between text-emerald-700"><span>Discount</span><span>−{formatPrice(order.discount_cents)}</span></div>}
            <div className="flex justify-between pt-1 text-lg font-bold text-neutral-950"><span>Total</span><span>{formatPrice(order.total_cents)}</span></div>
            {order.refunded_cents > 0 && <div className="flex justify-between text-sm font-medium text-red-700"><span>Refunded</span><span>−{formatPrice(order.refunded_cents)}</span></div>}
          </div>
        </section>

        {ticketsAvailable && (
          <section className="card mb-6 p-5 sm:p-6">
            <div className="mb-4 flex items-center justify-between">
              <h2 className="font-semibold text-neutral-950">Tickets ({order.tickets.length})</h2>
              {['completed', 'partially_refunded'].includes(order.status) && (
                <button onClick={resend} disabled={resendState === 'sending'} className="inline-flex items-center gap-1.5 text-sm font-semibold text-brand-600"><Mail className="h-4 w-4" /> Resend</button>
              )}
            </div>
            {resendState === 'sent' && <p className="mb-3 text-sm text-emerald-700">A fresh confirmation was queued for delivery.</p>}
            {resendState === 'cooldown' && <p className="mb-3 text-sm text-amber-700">A message was sent recently. Please wait two minutes.</p>}
            {resendState === 'error' && <p className="mb-3 text-sm text-red-700">Unable to resend right now.</p>}
            {ticketActionError && <p className="mb-3 text-sm text-red-700">{ticketActionError}</p>}
            <div className="divide-y divide-neutral-100">
              {order.tickets.map(ticket => (
                <div key={ticket.id} className="flex items-center justify-between gap-3 py-3">
                  <div className="min-w-0 flex-1">
                    <p className="truncate font-medium text-neutral-900">{ticket.ticket_type.name}</p>
                    <p className="text-xs capitalize text-neutral-500">{ticket.attendee_name || 'New holder'} · {ticket.status.replace('_', ' ')}</p>
                  </div>
                  <div className="flex items-center gap-2">
                    {ticket.status === 'issued' && (
                      <button onClick={() => rotateTicket(ticket)} disabled={rotatingTicketId === ticket.id} className="text-xs font-semibold text-neutral-600">{rotatingTicketId === ticket.id ? 'Refreshing…' : 'Refresh QR'}</button>
                    )}
                    {ticket.status === 'issued' && (ticket.refundable_cents === 0 || ['cancelled', 'postponed'].includes(event.status)) && (
                      <button onClick={() => cancelTicket(ticket)} disabled={cancellingTicketId === ticket.id} className="text-xs font-semibold text-red-600">{cancellingTicketId === ticket.id ? 'Cancelling…' : ticket.refundable_cents > 0 ? 'Refund' : 'Cancel'}</button>
                    )}
                    {ticket.status === 'issued' && event.transfers_enabled !== false && (
                      <button onClick={() => transferTicket(ticket)} disabled={transferringTicketId === ticket.id} className="text-xs font-semibold text-brand-600">{transferringTicketId === ticket.id ? 'Sending…' : 'Transfer'}</button>
                    )}
                    {ticket.status === 'issued' && !order.ticket_access_blocked && (
                      <Link to={`/tickets/${encodeURIComponent(ticket.display_credential)}?order=${id}`} aria-label="Download ticket"><Download className="h-4 w-4 text-neutral-500" /></Link>
                    )}
                    {ticket.display_credential && <Link to={`/tickets/${encodeURIComponent(ticket.display_credential)}?order=${id}`} aria-label="View ticket"><ChevronRight className="h-5 w-5 text-neutral-400" /></Link>}
                  </div>
                </div>
              ))}
            </div>
          </section>
        )}

        <div className="flex items-center justify-center gap-5 text-sm font-medium">
          <button onClick={fetchOrder} className="inline-flex items-center gap-1.5 text-neutral-600"><RefreshCw className="h-4 w-4" /> Refresh</button>
          <Link to="/events" className="text-brand-600">Browse events</Link>
          {!getOrderAccess(id) && <Link to="/my-tickets" className="text-brand-600">My tickets</Link>}
        </div>
      </div>
    </div>
  )
}
