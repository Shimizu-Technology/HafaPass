import { Fragment, useState, useEffect, useCallback } from 'react'
import { Loader2, Search, ChevronLeft, ChevronRight, ChevronDown, ChevronUp } from 'lucide-react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'

const orderStatuses = ['', 'pending', 'completed', 'refunded', 'cancelled', 'partially_refunded', 'expired']

const money = (cents = 0) => (cents / 100).toLocaleString('en-US', { style: 'currency', currency: 'USD' })

export default function AdminOrdersPage() {
  const [orders, setOrders] = useState([])
  const [meta, setMeta] = useState({})
  const [loading, setLoading] = useState(true)
  const [search, setSearch] = useState('')
  const [status, setStatus] = useState('')
  const [page, setPage] = useState(1)
  const [expanded, setExpanded] = useState(null)

  const fetchOrders = useCallback(() => {
    setLoading(true)
    const params = { page, per_page: 20 }
    if (search) params.search = search
    if (status) params.status = status
    apiClient.get('/admin/orders', { params })
      .then(res => { setOrders(res.data.orders); setMeta(res.data.meta) })
      .catch(console.error)
      .finally(() => setLoading(false))
  }, [page, search, status])

  useEffect(() => { fetchOrders() }, [fetchOrders])

  const statusBadge = (s) => {
    const styles = {
      completed: 'bg-emerald-50 text-emerald-600',
      pending: 'bg-amber-50 text-amber-600',
      refunded: 'bg-red-50 text-red-600',
      cancelled: 'bg-neutral-100 text-neutral-500',
      expired: 'bg-neutral-100 text-neutral-500',
      partially_refunded: 'bg-orange-50 text-orange-600',
    }
    return styles[s] || 'bg-neutral-100 text-neutral-600'
  }

  return (
    <AdminLayout>
      <div className="flex flex-col sm:flex-row gap-3 mb-6">
        <div className="relative flex-1">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-neutral-400" />
          <input
            type="text"
            placeholder="Search by buyer name or email..."
            value={search}
            onChange={e => { setSearch(e.target.value); setPage(1) }}
            className="w-full pl-10 pr-4 py-2.5 bg-white/70 border border-neutral-200/50 rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-brand-500/20 focus:border-brand-500"
          />
        </div>
        <select value={status} onChange={e => { setStatus(e.target.value); setPage(1) }} className="px-4 py-2.5 bg-white/70 border border-neutral-200/50 rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-brand-500/20">
          <option value="">All Statuses</option>
          {orderStatuses.filter(Boolean).map(s => <option key={s} value={s}>{s.replace('_', ' ')}</option>)}
        </select>
      </div>

      <div className="bg-white/70 backdrop-blur-sm rounded-xl border border-neutral-200/50 shadow-soft overflow-hidden">
        {loading ? (
          <div className="flex justify-center py-12"><Loader2 className="w-6 h-6 text-brand-500 animate-spin" /></div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-neutral-100 text-left text-neutral-500">
                  <th className="px-4 py-3 font-medium w-8"></th>
                  <th className="px-4 py-3 font-medium">Order</th>
                  <th className="px-4 py-3 font-medium">Buyer</th>
                  <th className="px-4 py-3 font-medium hidden md:table-cell">Event</th>
                  <th className="px-4 py-3 font-medium text-right">Tickets</th>
                  <th className="px-4 py-3 font-medium text-right">Total</th>
                  <th className="px-4 py-3 font-medium">Status</th>
                  <th className="px-4 py-3 font-medium hidden lg:table-cell">Date</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-neutral-100">
                {orders.map(order => (
                  <Fragment key={order.id}>
                    <tr className="hover:bg-neutral-50/50 transition-colors cursor-pointer" onClick={() => setExpanded(expanded === order.id ? null : order.id)}>
                      <td className="px-4 py-3">
                        {expanded === order.id ? <ChevronUp className="w-4 h-4 text-neutral-400" /> : <ChevronDown className="w-4 h-4 text-neutral-400" />}
                      </td>
                      <td className="px-4 py-3 font-mono text-xs text-neutral-500">#{order.id}</td>
                      <td className="px-4 py-3">
                        <p className="font-medium text-neutral-900">{order.buyer_name}</p>
                        <p className="text-xs text-neutral-500">{order.buyer_email}</p>
                      </td>
                      <td className="px-4 py-3 text-neutral-500 hidden md:table-cell">{order.event_title}</td>
                      <td className="px-4 py-3 text-right text-neutral-700">{order.tickets.length}</td>
                      <td className="px-4 py-3 text-right font-semibold text-neutral-900">{money(order.net_cents)}</td>
                      <td className="px-4 py-3">
                        <span className={`text-xs px-2 py-1 rounded-full font-medium ${statusBadge(order.status)}`}>{order.status.replace('_', ' ')}</span>
                      </td>
                      <td className="px-4 py-3 text-neutral-500 hidden lg:table-cell">{new Date(order.created_at).toLocaleDateString()}</td>
                    </tr>
                    {expanded === order.id && (
                      <tr key={`${order.id}-detail`}>
                        <td colSpan={8} className="px-4 py-3 bg-neutral-50/50">
                          <div className="pl-8 space-y-5">
                            <div>
                              <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500 mb-2">Financial ledger</p>
                              <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-2">
                                {[
                                  ['Gross', order.subtotal_cents],
                                  ['Discount', order.discount_cents],
                                  ['Fees', order.fee_cents],
                                  ['Refunds', order.refund_cents],
                                  ['Net', order.net_cents],
                                  ['Organizer', order.organizer_proceeds_cents],
                                ].map(([label, value]) => (
                                  <div key={label} className="rounded-lg border border-neutral-200 bg-white p-2.5">
                                    <p className="text-[10px] uppercase tracking-wide text-neutral-400">{label}</p>
                                    <p className="mt-1 font-semibold text-neutral-800">{money(value)}</p>
                                  </div>
                                ))}
                              </div>
                            </div>

                            <div>
                              <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500 mb-2">Immutable order items</p>
                              <div className="space-y-1">
                                {order.order_items.map(item => (
                                  <div key={item.id} className="grid grid-cols-[1fr_auto_auto] gap-4 rounded-lg bg-white px-3 py-2 text-xs text-neutral-600">
                                    <span><strong className="text-neutral-800">{item.name}</strong>{item.tier_name ? ` · ${item.tier_name}` : ''}</span>
                                    <span>{item.quantity} × {money(item.unit_price_cents)}</span>
                                    <span className="font-medium text-neutral-800">{money(item.subtotal_cents + item.fee_cents - item.discount_cents)}</span>
                                  </div>
                                ))}
                              </div>
                            </div>

                            <div className="grid md:grid-cols-2 gap-4">
                              <div>
                                <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500 mb-2">Payments & refunds</p>
                                <div className="space-y-1 text-xs text-neutral-600">
                                  {order.payments.map(payment => (
                                    <div key={`payment-${payment.id}`} className="flex justify-between rounded-lg bg-white px-3 py-2">
                                      <span>{payment.provider_payment_id || `Payment #${payment.id}`} · {payment.status}</span>
                                      <span>{money(payment.amount_cents)}</span>
                                    </div>
                                  ))}
                                  {order.refunds.map(refund => (
                                    <div key={`refund-${refund.id}`} className="flex justify-between rounded-lg bg-red-50/60 px-3 py-2 text-red-700">
                                      <span>{refund.provider_refund_id || `Refund #${refund.id}`} · {refund.status}</span>
                                      <span>−{money(refund.amount_cents)}</span>
                                    </div>
                                  ))}
                                  {order.payments.length === 0 && order.refunds.length === 0 && <p>No provider attempts recorded.</p>}
                                </div>
                              </div>
                              <div>
                                <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500 mb-2">Reconciliation</p>
                                {order.reconciliation_exceptions.length > 0 ? (
                                  <div className="space-y-1">
                                    {order.reconciliation_exceptions.map(exception => (
                                      <div key={exception.id} className="rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800">
                                        {exception.code.replaceAll('_', ' ')} · {exception.status}
                                      </div>
                                    ))}
                                  </div>
                                ) : <p className="text-xs text-emerald-600">No reconciliation exceptions.</p>}
                              </div>
                            </div>

                            <div>
                            <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500 mb-2">Tickets</p>
                            <div className="space-y-1">
                              {order.tickets.map(t => (
                                <div key={t.id} className="flex items-center gap-4 text-xs text-neutral-600">
                                  <span className="font-medium">{t.ticket_type}</span>
                                  <span>{t.attendee_name}</span>
                                  <span className={`px-1.5 py-0.5 rounded-full ${
                                    t.status === 'checked_in' ? 'bg-emerald-50 text-emerald-600' :
                                    t.status === 'cancelled' ? 'bg-red-50 text-red-600' :
                                    'bg-neutral-100 text-neutral-600'
                                  }`}>{t.status}</span>
                                </div>
                              ))}
                              {order.tickets.length === 0 && <p className="text-xs text-neutral-400">No entitlements issued yet.</p>}
                            </div>
                            </div>
                          </div>
                        </td>
                      </tr>
                    )}
                  </Fragment>
                ))}
              </tbody>
            </table>
            {orders.length === 0 && <p className="text-center py-8 text-neutral-400">No orders found.</p>}
          </div>
        )}
      </div>

      {meta.total_pages > 1 && (
        <div className="flex items-center justify-center gap-2 mt-6">
          <button onClick={() => setPage(p => Math.max(1, p - 1))} disabled={page === 1} className="p-2 rounded-xl border border-neutral-200/50 bg-white/70 disabled:opacity-40 hover:bg-neutral-50 transition-colors">
            <ChevronLeft className="w-4 h-4" />
          </button>
          <span className="text-sm text-neutral-600">Page {meta.page} of {meta.total_pages}</span>
          <button onClick={() => setPage(p => Math.min(meta.total_pages, p + 1))} disabled={page === meta.total_pages} className="p-2 rounded-xl border border-neutral-200/50 bg-white/70 disabled:opacity-40 hover:bg-neutral-50 transition-colors">
            <ChevronRight className="w-4 h-4" />
          </button>
        </div>
      )}
    </AdminLayout>
  )
}
