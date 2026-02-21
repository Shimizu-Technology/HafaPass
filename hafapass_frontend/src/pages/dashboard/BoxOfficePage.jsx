import { useState, useEffect, useCallback } from 'react'
import { useParams, Link } from 'react-router-dom'
import { Loader2, ShoppingCart, CreditCard, Banknote, Plus, Minus, ArrowLeft, CheckCircle2 } from 'lucide-react'
import apiClient from '../../api/client'
import QRCode from '../../components/QRCode'

export default function BoxOfficePage() {
  const { id } = useParams()
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

  const fetchEvent = useCallback(async () => {
    try {
      const res = await apiClient.get(`/organizer/events/${id}`)
      setEvent(res.data)
      // Initialize quantities to 0
      const initial = {}
      res.data.ticket_types?.forEach(tt => { initial[tt.id] = 0 })
      setQuantities(initial)
    } catch {
      setError('Failed to load event.')
    } finally {
      setLoading(false)
    }
  }, [id])

  const fetchSummary = useCallback(async () => {
    try {
      const res = await apiClient.get(`/organizer/events/${id}/box_office/summary`)
      setSummary(res.data)
    } catch { /* ignore */ }
  }, [id])

  useEffect(() => { fetchEvent(); fetchSummary() }, [fetchEvent, fetchSummary])

  const updateQty = (ttId, delta) => {
    setQuantities(prev => ({
      ...prev,
      [ttId]: Math.max(0, (prev[ttId] || 0) + delta)
    }))
  }

  const totalItems = Object.values(quantities).reduce((s, q) => s + q, 0)
  const totalCents = event?.ticket_types?.reduce((s, tt) => s + (quantities[tt.id] || 0) * tt.price_cents, 0) || 0

  const handleSale = async () => {
    if (totalItems === 0) return
    setSubmitting(true)
    setLastOrder(null)

    const line_items = Object.entries(quantities)
      .filter(([, qty]) => qty > 0)
      .map(([ttId, qty]) => ({ ticket_type_id: parseInt(ttId), quantity: qty }))

    try {
      const res = await apiClient.post(`/organizer/events/${id}/box_office`, {
        line_items,
        payment_method: paymentMethod,
        buyer_name: buyerName || undefined,
        buyer_email: buyerEmail || undefined
      })
      setLastOrder(res.data)
      // Reset form
      const reset = {}
      event.ticket_types?.forEach(tt => { reset[tt.id] = 0 })
      setQuantities(reset)
      setBuyerName('')
      setBuyerEmail('')
      fetchSummary()
      fetchEvent() // refresh availability
    } catch (err) {
      alert(err.response?.data?.error || 'Failed to process sale.')
    } finally {
      setSubmitting(false)
    }
  }

  if (loading) return <div className="flex justify-center py-20"><Loader2 className="w-8 h-8 text-brand-500 animate-spin" /></div>
  if (error) return <div className="max-w-2xl mx-auto px-4 py-8 text-center text-red-600">{error}</div>

  return (
    <div className="max-w-4xl mx-auto px-4 py-8">
      {/* Header */}
      <div className="mb-6 flex items-center justify-between">
        <Link to={`/dashboard/events/${id}/edit`} className="text-brand-500 hover:text-brand-700 text-sm font-medium flex items-center gap-1">
          <ArrowLeft className="w-4 h-4" /> Back to Event
        </Link>
      </div>

      <div className="flex items-center gap-3 mb-8">
        <ShoppingCart className="w-6 h-6 text-brand-600" />
        <div>
          <h1 className="text-2xl font-bold text-neutral-900 font-display">Box Office</h1>
          <p className="text-sm text-neutral-500">{event.title}</p>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
        {/* Left: Ticket Selection */}
        <div className="lg:col-span-2 space-y-4">
          <h2 className="text-lg font-semibold text-neutral-900">Select Tickets</h2>

          {event.ticket_types?.map(tt => {
            const available = tt.quantity_available - tt.quantity_sold
            return (
              <div key={tt.id} className="flex items-center justify-between p-4 sm:p-5 bg-white border border-neutral-200 rounded-xl">
                <div className="min-w-0 mr-4">
                  <p className="font-medium text-neutral-900 truncate">{tt.name}</p>
                  <p className="text-sm text-neutral-500">
                    ${(tt.price_cents / 100).toFixed(2)} · {available} left
                  </p>
                </div>
                <div className="flex items-center gap-3 shrink-0">
                  <button
                    onClick={() => updateQty(tt.id, -1)}
                    disabled={!quantities[tt.id]}
                    className="w-11 h-11 sm:w-12 sm:h-12 flex items-center justify-center rounded-xl bg-neutral-100 hover:bg-neutral-200 disabled:opacity-30 transition"
                  >
                    <Minus className="w-5 h-5" />
                  </button>
                  <span className="w-10 text-center text-xl font-semibold tabular-nums">{quantities[tt.id] || 0}</span>
                  <button
                    onClick={() => updateQty(tt.id, 1)}
                    disabled={(quantities[tt.id] || 0) >= available}
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
                placeholder="Name"
                value={buyerName}
                onChange={e => setBuyerName(e.target.value)}
                className="px-4 py-2.5 rounded-xl border border-neutral-300 text-sm focus:outline-none focus:ring-2 focus:ring-brand-500/20 focus:border-brand-500"
              />
              <input
                type="email"
                placeholder="Email"
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
                onClick={() => setPaymentMethod('door_cash')}
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
                className={`flex-1 flex items-center justify-center gap-2 px-4 py-3 rounded-xl border-2 text-sm font-medium transition ${
                  paymentMethod === 'door_card'
                    ? 'border-brand-500 bg-brand-50 text-brand-700'
                    : 'border-neutral-200 text-neutral-600 hover:border-neutral-300'
                }`}
              >
                <CreditCard className="w-5 h-5" /> Card at Door
              </button>
            </div>
          </div>

          {/* Process Sale Button */}
          <button
            onClick={handleSale}
            disabled={totalItems === 0 || submitting}
            className="w-full mt-6 py-4 rounded-xl bg-brand-600 text-white font-semibold text-lg hover:bg-brand-700 disabled:opacity-40 disabled:cursor-not-allowed transition flex items-center justify-center gap-2"
          >
            {submitting ? (
              <><Loader2 className="w-5 h-5 animate-spin" /> Processing...</>
            ) : (
              <>Process Sale · ${(totalCents / 100).toFixed(2)} ({totalItems} ticket{totalItems !== 1 ? 's' : ''})</>
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
                      <QRCode value={ticket.qr_code} size={120} />
                    </div>
                    <p className="text-xs text-center text-neutral-400 mt-1 font-mono">{ticket.qr_code}</p>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
