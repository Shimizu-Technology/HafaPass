import { useState, useEffect, useCallback, useRef } from 'react'
import { Link } from 'react-router-dom'
import { Loader2, Calendar, Users, DollarSign, Ticket, ArrowRight } from 'lucide-react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'
import AdminAccessRecovery from '../../components/AdminAccessRecovery'
import { usePlatformIdentity, usePlatformVisit, usePlatformRequests } from '../../hooks/usePlatformContext'
import { StaggerContainer, StaggerItem } from '../../components/ui/ScrollReveal'

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

function AdminDashboardSession({ identity }) {
  const { beginRequest } = usePlatformRequests(identity, '/admin')
  const generation = useRef(0)
  const pendingRead = useRef(null)
  const [data, setData] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const refresh = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    pendingRead.current?.abort()
    pendingRead.current = request
    const read = ++generation.current
    const current = () => request.current() && read === generation.current
    setLoading(true); setError('')
    try {
      const response = await apiClient.get('/admin/dashboard', request.config)
      if (current()) setData(response.data)
    } catch (failure) {
      if (!current() || request.handleError(failure)) return
      setError('Unable to load the administrator dashboard. Please try again.')
    } finally {
      request.release()
      if (current()) setLoading(false)
    }
  }, [beginRequest])
  useEffect(() => { refresh(); return () => pendingRead.current?.abort() }, [refresh])

  if (loading) {
    return (
      <AdminLayout>
        <div className="flex justify-center py-20">
          <Loader2 className="w-8 h-8 text-brand-500 animate-spin" />
        </div>
      </AdminLayout>
    )
  }

  if (error || !data) return <AdminLayout><section role="alert" className="rounded-xl border border-neutral-200 bg-white p-5"><p className="text-neutral-700">{error || 'Unable to load the administrator dashboard.'}</p><button type="button" onClick={refresh} className="btn-primary mt-4">Retry dashboard</button></section></AdminLayout>

  const totalEvents = Object.values(data.total_events).reduce((a, b) => a + b, 0)
  const totalUsers = Object.values(data.total_users).reduce((a, b) => a + b, 0)
  const revenue = (data.total_revenue_cents / 100).toLocaleString('en-US', { style: 'currency', currency: 'USD' })
  const financials = data.financials || {}
  const formatMoney = (value = 0) => (value / 100).toLocaleString('en-US', { style: 'currency', currency: 'USD' })
  const signals = data.operational_signals || {}
  const operationalIssueCount = (signals.failed_messages_last_hour || 0) + (signals.stale_message_events || 0) +
    (signals.failed_payment_webhooks || 0) + (signals.open_reconciliation_exceptions || 0) +
    (signals.unknown_card_present_results || 0)

  return (
    <AdminLayout>
      <StaggerContainer className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 mb-8">
        <StaggerItem><StatCard label="Total Events" value={totalEvents} icon={Calendar} color="bg-brand-500" /></StaggerItem>
        <StaggerItem><StatCard label="Total Users" value={totalUsers} icon={Users} color="bg-indigo-500" /></StaggerItem>
        <StaggerItem><StatCard label="Revenue" value={revenue} icon={DollarSign} color="bg-emerald-500" /></StaggerItem>
        <StaggerItem><StatCard label="Tickets Sold" value={data.total_tickets_sold} icon={Ticket} color="bg-coral-500" /></StaggerItem>
      </StaggerContainer>

      <div className="grid grid-cols-2 lg:grid-cols-5 gap-3 mb-8" aria-label="Financial ledger summary">
        {[
          ['Gross sales', financials.gross_cents],
          ['Discounts', financials.discount_cents],
          ['Refunds', financials.refund_cents],
          ['Platform fees', financials.fee_cents],
          ['Payout ready', financials.payout_ready_cents],
        ].map(([label, value]) => (
          <div key={label} className="rounded-xl border border-neutral-200/60 bg-white/70 p-4">
            <p className="text-xs font-medium text-neutral-500">{label}</p>
            <p className="mt-1 text-lg font-bold text-neutral-900">{formatMoney(value)}</p>
          </div>
        ))}
      </div>

      {data.open_reconciliation_exceptions > 0 && (
        <div className="mb-8 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900" role="status">
          {data.open_reconciliation_exceptions} payment reconciliation {data.open_reconciliation_exceptions === 1 ? 'exception requires' : 'exceptions require'} review.
        </div>
      )}

      <div className={`mb-8 rounded-xl border px-4 py-3 text-sm ${operationalIssueCount > 0 ? 'border-red-200 bg-red-50 text-red-900' : 'border-emerald-200 bg-emerald-50 text-emerald-900'}`} role="status">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <span>{operationalIssueCount > 0 ? `${operationalIssueCount} operational signal${operationalIssueCount === 1 ? '' : 's'} require review across messages, webhooks, reconciliation, or card-present results.` : 'No persisted operational failure signals require review.'}</span>
          <Link to="/support" className="font-semibold underline">Open support console</Link>
        </div>
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


export default function AdminDashboardPage() {
  const identity = usePlatformIdentity('admin')
  const visit = usePlatformVisit('/admin')
  if (!visit.active) return null
  if (identity.authorityDenied) return <AdminAccessRecovery key={identity.accountKey} identity={identity} />
  if (!identity.ready) return <p role="status">Checking account access…</p>
  return <AdminDashboardSession key={`${identity.accountKey}:${visit.generation}`} identity={identity} />
}
