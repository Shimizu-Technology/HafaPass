import { useState, useEffect } from 'react'
import { Link } from 'react-router-dom'
import { Loader2, Calendar, Users, DollarSign, Ticket, ArrowRight } from 'lucide-react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'

function StatCard({ label, value, icon: Icon, color }) {
  return (
    <div className="bg-white/70 backdrop-blur-sm rounded-xl border border-neutral-200/50 p-6 shadow-soft">
      <div className="flex items-center justify-between mb-3">
        <span className="text-sm font-medium text-neutral-500">{label}</span>
        <div className={`w-10 h-10 rounded-xl flex items-center justify-center ${color}`}>
          <Icon className="w-5 h-5 text-white" />
        </div>
      </div>
      <p className="text-3xl font-bold text-neutral-900">{value}</p>
    </div>
  )
}

export default function AdminDashboardPage() {
  const [data, setData] = useState(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    apiClient.get('/admin/dashboard')
      .then(res => setData(res.data))
      .catch(console.error)
      .finally(() => setLoading(false))
  }, [])

  if (loading) {
    return (
      <AdminLayout>
        <div className="flex justify-center py-20">
          <Loader2 className="w-8 h-8 text-brand-500 animate-spin" />
        </div>
      </AdminLayout>
    )
  }

  if (!data) return <AdminLayout><p className="text-neutral-500">Failed to load dashboard.</p></AdminLayout>

  const totalEvents = Object.values(data.total_events).reduce((a, b) => a + b, 0)
  const totalUsers = Object.values(data.total_users).reduce((a, b) => a + b, 0)
  const revenue = (data.total_revenue_cents / 100).toLocaleString('en-US', { style: 'currency', currency: 'USD' })

  return (
    <AdminLayout>
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 mb-8">
        <StatCard label="Total Events" value={totalEvents} icon={Calendar} color="bg-brand-500" />
        <StatCard label="Total Users" value={totalUsers} icon={Users} color="bg-indigo-500" />
        <StatCard label="Revenue" value={revenue} icon={DollarSign} color="bg-emerald-500" />
        <StatCard label="Tickets Sold" value={data.total_tickets_sold} icon={Ticket} color="bg-coral-500" />
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Recent Events */}
        <div className="bg-white/70 backdrop-blur-sm rounded-xl border border-neutral-200/50 shadow-soft overflow-hidden">
          <div className="flex items-center justify-between p-5 border-b border-neutral-100">
            <h2 className="font-semibold text-neutral-900">Recent Events</h2>
            <Link to="/admin/events" className="text-sm text-brand-500 hover:text-brand-600 flex items-center gap-1">
              View all <ArrowRight className="w-3.5 h-3.5" />
            </Link>
          </div>
          <div className="divide-y divide-neutral-100">
            {data.recent_events.map(event => (
              <Link key={event.id} to={`/events/${event.slug}`} className="flex items-center justify-between p-4 hover:bg-neutral-50/50 transition-colors">
                <div>
                  <p className="text-sm font-medium text-neutral-900">{event.title}</p>
                  <p className="text-xs text-neutral-500">{event.organizer_name}</p>
                </div>
                <span className={`text-xs px-2.5 py-1 rounded-full font-medium ${
                  event.status === 'published' ? 'bg-emerald-50 text-emerald-600' :
                  event.status === 'draft' ? 'bg-neutral-100 text-neutral-600' :
                  'bg-red-50 text-red-600'
                }`}>{event.status}</span>
              </Link>
            ))}
            {data.recent_events.length === 0 && (
              <p className="p-4 text-sm text-neutral-400">No events yet.</p>
            )}
          </div>
        </div>

        {/* Recent Orders */}
        <div className="bg-white/70 backdrop-blur-sm rounded-xl border border-neutral-200/50 shadow-soft overflow-hidden">
          <div className="flex items-center justify-between p-5 border-b border-neutral-100">
            <h2 className="font-semibold text-neutral-900">Recent Orders</h2>
            <Link to="/admin/orders" className="text-sm text-brand-500 hover:text-brand-600 flex items-center gap-1">
              View all <ArrowRight className="w-3.5 h-3.5" />
            </Link>
          </div>
          <div className="divide-y divide-neutral-100">
            {data.recent_orders.map(order => (
              <div key={order.id} className="flex items-center justify-between p-4">
                <div>
                  <p className="text-sm font-medium text-neutral-900">{order.buyer_name}</p>
                  <p className="text-xs text-neutral-500">{order.event_title}</p>
                </div>
                <div className="text-right">
                  <p className="text-sm font-semibold text-neutral-900">${(order.total_cents / 100).toFixed(2)}</p>
                  <span className={`text-xs font-medium ${
                    order.status === 'completed' ? 'text-emerald-600' :
                    order.status === 'pending' ? 'text-amber-600' :
                    'text-red-600'
                  }`}>{order.status}</span>
                </div>
              </div>
            ))}
            {data.recent_orders.length === 0 && (
              <p className="p-4 text-sm text-neutral-400">No orders yet.</p>
            )}
          </div>
        </div>
      </div>
    </AdminLayout>
  )
}
