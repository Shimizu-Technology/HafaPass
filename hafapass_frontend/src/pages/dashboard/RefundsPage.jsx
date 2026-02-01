import { useState, useEffect } from 'react'
import { useParams, Link } from 'react-router-dom'
import { ArrowLeft, RotateCcw, DollarSign, Loader2, AlertTriangle, Check } from 'lucide-react'
import apiClient from '../../api/client'

export default function RefundsPage() {
  const { id: eventId } = useParams()
  const [orders, setOrders] = useState([])
  const [loading, setLoading] = useState(true)
  const [refundingId, setRefundingId] = useState(null)
  const [refundForm, setRefundForm] = useState({ amount: '', reason: '', type: 'full' })
  const [processing, setProcessing] = useState(false)

  const fetchOrders = async () => {
    try {
      const res = await apiClient.get(`/organizer/events/${eventId}/stats`)
      setOrders(res.data.recent_orders || [])
    } catch (e) { console.error(e) }
    setLoading(false)
  }

  useEffect(() => { fetchOrders() }, [eventId])

  const handleRefund = async (orderId) => {
    setProcessing(true)
    try {
      const payload = { reason: refundForm.reason || null }
      if (refundForm.type === 'partial' && refundForm.amount) {
        payload.amount_cents = Math.round(parseFloat(refundForm.amount) * 100)
      }
      await apiClient.post(`/organizer/events/${eventId}/orders/${orderId}/refund`, payload)
      setRefundingId(null)
      setRefundForm({ amount: '', reason: '', type: 'full' })
      fetchOrders()
    } catch (e) {
      alert(e.response?.data?.error || 'Refund failed')
    }
    setProcessing(false)
  }

  if (loading) return <div className="flex justify-center py-20"><Loader2 className="w-8 h-8 text-brand-500 animate-spin" /></div>

  return (
    <div className="max-w-4xl mx-auto px-4 sm:px-6 py-8">
      <Link to={`/dashboard/events/${eventId}/analytics`} className="inline-flex items-center gap-1.5 text-neutral-500 hover:text-neutral-900 mb-6 text-sm font-medium transition-colors">
        <ArrowLeft className="w-4 h-4" /> Back to Analytics
      </Link>

      <div className="mb-8">
        <h1 className="text-2xl font-bold tracking-tight text-neutral-900">Refunds</h1>
        <p className="text-sm text-neutral-500 mt-1">Process full or partial refunds for completed orders</p>
      </div>

      {orders.length === 0 ? (
        <div className="card p-12 text-center">
          <DollarSign className="w-10 h-10 text-neutral-300 mx-auto mb-3" />
          <p className="text-neutral-500">No recent orders</p>
        </div>
      ) : (
        <div className="space-y-3">
          {orders.map(order => (
            <div key={order.id} className="card p-5">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-4">
                  <div className="w-10 h-10 rounded-xl bg-brand-50 flex items-center justify-center">
                    <DollarSign className="w-5 h-5 text-brand-500" />
                  </div>
                  <div>
                    <p className="font-medium text-neutral-900">Order #{order.id} &middot; {order.buyer_name}</p>
                    <p className="text-sm text-neutral-500">
                      {order.buyer_email} &middot; {order.ticket_count} ticket(s) &middot; ${(order.total_cents / 100).toFixed(2)}
                    </p>
                  </div>
                </div>
                {refundingId !== order.id ? (
                  <button onClick={() => setRefundingId(order.id)} className="btn-secondary text-xs !py-2 !px-3 gap-1 text-red-600 border-red-200 hover:bg-red-50">
                    <RotateCcw className="w-3 h-3" /> Refund
                  </button>
                ) : (
                  <button onClick={() => setRefundingId(null)} className="text-sm text-neutral-500 hover:text-neutral-700">Cancel</button>
                )}
              </div>

              {refundingId === order.id && (
                <div className="mt-4 pt-4 border-t border-neutral-100">
                  <div className="bg-amber-50 border border-amber-200 rounded-xl p-3 mb-4 flex items-start gap-2">
                    <AlertTriangle className="w-4 h-4 text-amber-600 mt-0.5 shrink-0" />
                    <p className="text-sm text-amber-700">This action cannot be undone. The refund will be processed through Stripe.</p>
                  </div>
                  <div className="flex gap-3 items-end flex-wrap">
                    <div>
                      <label className="block text-sm font-medium text-neutral-700 mb-1.5">Type</label>
                      <select value={refundForm.type} onChange={e => setRefundForm({...refundForm, type: e.target.value})} className="input !py-2 text-sm w-32">
                        <option value="full">Full</option>
                        <option value="partial">Partial</option>
                      </select>
                    </div>
                    {refundForm.type === 'partial' && (
                      <div>
                        <label className="block text-sm font-medium text-neutral-700 mb-1.5">Amount ($)</label>
                        <input type="number" step="0.01" min="0.01" max={(order.total_cents / 100).toFixed(2)}
                          value={refundForm.amount} onChange={e => setRefundForm({...refundForm, amount: e.target.value})}
                          className="input !py-2 text-sm w-28" placeholder="0.00" />
                      </div>
                    )}
                    <div className="flex-1 min-w-[200px]">
                      <label className="block text-sm font-medium text-neutral-700 mb-1.5">Reason (optional)</label>
                      <input value={refundForm.reason} onChange={e => setRefundForm({...refundForm, reason: e.target.value})}
                        className="input !py-2 text-sm" placeholder="Customer request, event cancelled..." />
                    </div>
                    <button onClick={() => handleRefund(order.id)} disabled={processing || (refundForm.type === 'partial' && !refundForm.amount)}
                      className="btn-primary text-sm !py-2.5 !bg-red-500 hover:!bg-red-600 gap-1 disabled:opacity-50">
                      {processing ? <Loader2 className="w-4 h-4 animate-spin" /> : <Check className="w-4 h-4" />}
                      Process Refund
                    </button>
                  </div>
                </div>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
