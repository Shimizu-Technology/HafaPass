import { useState, useEffect, useCallback, useId, useRef } from 'react'
import { Link } from 'react-router-dom'
import { Loader2, Calendar, Users, DollarSign, Ticket, ArrowRight, CircleAlert } from 'lucide-react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'
import AdminAccessRecovery from '../../components/AdminAccessRecovery'
import { usePlatformIdentity, usePlatformVisit, usePlatformRequests } from '../../hooks/usePlatformContext'
import { StaggerContainer, StaggerItem } from '../../components/ui/ScrollReveal'
import { adminLabel } from './adminLabels'
import Dialog from '../../components/Dialog'
import OrganizerVerificationQueue from './OrganizerVerificationQueue'
import { errorMessage } from './adminOperations'

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

// Production setup HåfaPass needs before it can sell or send email, each with
// a one-click approval that is recorded in the audit log.
function SetupRequired({ items, beginRequest, onApproved }) {
  const titleId = useId()
  const [confirming, setConfirming] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  if (!items?.length) return null

  const close = () => { if (!busy) { setConfirming(null); setError('') } }
  const approve = async () => {
    const request = beginRequest()
    if (!request) return
    setBusy(true)
    setError('')
    try {
      await apiClient.post(`/admin/platform_capabilities/${confirming.key}/quick_approve`, {}, request.config)
      if (!request.current()) return
      setConfirming(null)
      onApproved()
    } catch (failure) {
      if (request.handleError(failure) || !request.current()) return
      setError(errorMessage(failure, 'Nothing was approved. Check your connection and try again.'))
    } finally { request.release(); setBusy(false) }
  }

  return <div className="mb-8 space-y-3">
    {items.map(item => <div key={item.key} role="alert" className="flex flex-col gap-3 rounded-xl border border-red-300 bg-red-50 p-4 text-sm text-red-900 sm:flex-row sm:items-center sm:justify-between">
      <div className="flex min-w-0 items-start gap-2">
        <CircleAlert aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" />
        <div className="min-w-0">
          <p className="font-semibold [overflow-wrap:anywhere]">{item.message}</p>
          {!item.configured && item.help && <p className="mt-1 [overflow-wrap:anywhere]">{item.help}</p>}
        </div>
      </div>
      <button type="button" disabled={!item.configured} onClick={() => { setError(''); setConfirming(item) }} className="btn-danger min-h-11 shrink-0 text-sm">Approve now<span className="sr-only">: {item.label}</span></button>
    </div>)}
    {confirming && <Dialog labelledBy={titleId} busy={busy} onClose={close} className="max-w-md">
      <h2 id={titleId} className="text-lg font-semibold text-neutral-900">Approve {confirming.label}?</h2>
      <p className="mt-2 text-sm text-neutral-700">This records your approval in the audit log.</p>
      {error && <p role="alert" className="mt-3 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">{error}</p>}
      <div className="mt-6 flex flex-wrap justify-end gap-3">
        <button type="button" disabled={busy} onClick={close} className="btn-secondary">Cancel</button>
        <button type="button" disabled={busy} onClick={approve} className="btn-primary">{busy ? 'Approving…' : 'Approve'}</button>
      </div>
    </Dialog>}
  </div>
}

function AdminDashboardSession({ identity }) {
  const { beginRequest } = usePlatformRequests(identity, '/admin')
  const generation = useRef(0)
  const pendingRead = useRef(null)
  const [data, setData] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  // `quiet` keeps the current dashboard on screen while it reloads after a change.
  const refresh = useCallback(async ({ quiet = false } = {}) => {
    const request = beginRequest()
    if (!request) return
    pendingRead.current?.abort()
    pendingRead.current = request
    const read = ++generation.current
    const current = () => request.current() && read === generation.current
    if (!quiet) { setLoading(true); setError('') }
    try {
      const response = await apiClient.get('/admin/dashboard', request.config)
      if (current()) { setData(response.data); setError('') }
    } catch (failure) {
      if (!current() || request.handleError(failure)) return
      if (!quiet) setError('Unable to load the administrator dashboard. Please try again.')
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

  if (error || !data) return <AdminLayout><section role="alert" className="rounded-xl border border-neutral-200 bg-white p-5"><p className="text-neutral-700">{error || 'Unable to load the administrator dashboard.'}</p><button type="button" onClick={() => refresh()} className="btn-primary mt-4">Retry dashboard</button></section></AdminLayout>

  const totalEvents = Object.values(data.total_events).reduce((a, b) => a + b, 0)
  const totalUsers = Object.values(data.total_users).reduce((a, b) => a + b, 0)
  const grossRevenue = (data.total_revenue_cents / 100).toLocaleString('en-US', { style: 'currency', currency: 'USD' })
  const financials = data.financials || {}
  const revenue = data.platform_revenue || {}
  const formatMoney = (value = 0) => (value / 100).toLocaleString('en-US', { style: 'currency', currency: 'USD' })
  const signals = data.operational_signals || {}
  const operationalIssueCount = (signals.failed_messages_last_hour || 0) + (signals.stale_message_events || 0) +
    (signals.failed_payment_webhooks || 0) + (signals.open_reconciliation_exceptions || 0) +
    (signals.unknown_card_present_results || 0)

  const refreshQuietly = () => refresh({ quiet: true })

  return (
    <AdminLayout>
      <SetupRequired items={data.setup_required} beginRequest={beginRequest} onApproved={refreshQuietly} />

      <StaggerContainer className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 mb-8">
        <StaggerItem><StatCard label="Total Events" value={totalEvents} icon={Calendar} color="bg-brand-500" /></StaggerItem>
        <StaggerItem><StatCard label="Total Users" value={totalUsers} icon={Users} color="bg-indigo-500" /></StaggerItem>
        <StaggerItem><StatCard label="Revenue" value={grossRevenue} icon={DollarSign} color="bg-emerald-500" /></StaggerItem>
        <StaggerItem><StatCard label="Tickets Sold" value={data.total_tickets_sold} icon={Ticket} color="bg-accent-500" /></StaggerItem>
      </StaggerContainer>

      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 mb-4" aria-label="Financial ledger summary">
        {[
          ['Gross sales', financials.gross_cents],
          ['Discounts', financials.discount_cents],
          ['Refunds', financials.refund_cents],
          ['Payout ready', financials.payout_ready_cents],
        ].map(([label, value]) => (
          <div key={label} className="rounded-xl border border-neutral-200/60 bg-white/70 p-4">
            <p className="text-xs font-medium text-neutral-500">{label}</p>
            <p className="mt-1 text-lg font-bold text-neutral-900">{formatMoney(value)}</p>
          </div>
        ))}
      </div>

      {/* Platform fees exclude card processing. Processing HåfaPass covers (orders sold
          with the platform as bearer) reduces revenue; processing deducted from
          organizers (organizer-bearer and legacy orders) never does. */}
      <section aria-labelledby="platform-revenue-title" className="mb-8 rounded-xl border border-neutral-200/60 bg-white/70 p-4">
        <h2 id="platform-revenue-title" className="text-sm font-semibold text-neutral-900">HåfaPass platform revenue</h2>
        <dl className="mt-3 grid gap-3 sm:grid-cols-3">
          {[
            ['Platform fees collected', revenue.gross_platform_fee_cents, 'Service fees, less refunded fees'],
            ['Card processing covered by HåfaPass', revenue.platform_processing_fee_cents, 'On orders where HåfaPass pays processing'],
            ['Net platform revenue', revenue.net_platform_revenue_cents, 'Fees collected minus processing covered'],
          ].map(([label, value, hint], index) => (
            <div key={label} className={index === 2 ? 'rounded-lg bg-brand-50 p-3 ring-1 ring-brand-200' : 'rounded-lg p-3 ring-1 ring-neutral-200'}>
              <dt className="text-xs font-medium text-neutral-600">{label}</dt>
              <dd className="mt-1 text-lg font-bold text-neutral-900">{index === 1 && value > 0 ? '−' : ''}{formatMoney(value)}</dd>
              <dd className="text-xs text-neutral-600">{hint}</dd>
            </div>
          ))}
        </dl>
        <p className="mt-3 text-xs text-neutral-600">Card processing deducted from organizer proceeds (organizer-bearer and older orders): {formatMoney(revenue.organizer_processing_fee_cents)}. It is not HåfaPass revenue or cost.</p>
      </section>

      {(data.open_disputes > 0 || data.payouts_needing_reconciliation > 0) && (
        <div className="mb-8 flex flex-wrap gap-x-6 gap-y-2 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900" role="status">
          {data.open_disputes > 0 && <Link to="/admin/disputes?status=open" className="font-semibold underline">{data.open_disputes} open {data.open_disputes === 1 ? 'dispute' : 'disputes'}</Link>}
          {data.payouts_needing_reconciliation > 0 && <Link to="/admin/payouts" className="font-semibold underline">{data.payouts_needing_reconciliation} {data.payouts_needing_reconciliation === 1 ? 'payout awaits' : 'payouts await'} a recorded outcome</Link>}
        </div>
      )}

      {data.open_reconciliation_exceptions > 0 && (
        <div className="mb-8 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900" role="status">
          {data.open_reconciliation_exceptions} payment reconciliation {data.open_reconciliation_exceptions === 1 ? 'exception requires' : 'exceptions require'} review.
        </div>
      )}

      <div className={`mb-8 rounded-xl border px-4 py-3 text-sm ${operationalIssueCount > 0 ? 'border-red-200 bg-red-50 text-red-900' : 'border-emerald-200 bg-emerald-50 text-emerald-900'}`} role="status">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <span>{operationalIssueCount > 0 ? `${operationalIssueCount} operational ${operationalIssueCount === 1 ? 'issue needs' : 'issues need'} review (messages, payment updates, reconciliation or in-person card payments).` : 'No operational issues need review.'}</span>
          <Link to="/support" className="font-semibold underline">Open support console</Link>
        </div>
      </div>

      <OrganizerVerificationQueue awaiting={data.organizers_awaiting_verification} verified={data.verified_organizers} beginRequest={beginRequest} onChanged={refreshQuietly} />

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
                }`}>{adminLabel(event.status)}</span>
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
                  }`}>{adminLabel(order.status)}</span>
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
