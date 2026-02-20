import { useState, useEffect, useCallback } from 'react'
import { Loader2, Search, ChevronLeft, ChevronRight, ChevronDown, ChevronUp } from 'lucide-react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'

const orderStatuses = ['', 'pending', 'completed', 'refunded', 'cancelled', 'partially_refunded']

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
                  <>
                    <tr key={order.id} className="hover:bg-neutral-50/50 transition-colors cursor-pointer" onClick={() => setExpanded(expanded === order.id ? null : order.id)}>
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
                      <td className="px-4 py-3 text-right font-semibold text-neutral-900">${(order.total_cents / 100).toFixed(2)}</td>
                      <td className="px-4 py-3">
                        <span className={`text-xs px-2 py-1 rounded-full font-medium ${statusBadge(order.status)}`}>{order.status.replace('_', ' ')}</span>
                      </td>
                      <td className="px-4 py-3 text-neutral-500 hidden lg:table-cell">{new Date(order.created_at).toLocaleDateString()}</td>
                    </tr>
                    {expanded === order.id && (
                      <tr key={`${order.id}-detail`}>
                        <td colSpan={8} className="px-4 py-3 bg-neutral-50/50">
                          <div className="pl-8">
                            <p className="text-xs font-medium text-neutral-500 mb-2">Tickets</p>
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
                            </div>
                          </div>
                        </td>
                      </tr>
                    )}
                  </>
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
