import { Link, useSearchParams } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import AdminLayout from './AdminLayout'
import AdminSessionGate from './AdminSessionGate'
import OperationalSearch from '../../components/OperationalSearch'
import OperationalPagination from '../../components/OperationalPagination'
import { adminLabel } from './adminLabels'
import { compactParams, foldCell, foldRow, foldTable, formatDate, money, readFilters, statusTone, useAdminList } from './adminOperations'

const STATUSES = ['open', 'won', 'lost']
const REASONS = {
  fraudulent: 'Fraudulent', product_not_received: 'Not received', duplicate: 'Duplicate charge', credit_not_processed: 'Refund not processed',
  subscription_canceled: 'Subscription canceled', product_unacceptable: 'Not as described', unrecognized: 'Unrecognized charge', general: 'General',
}

function AdminDisputesSession({ identity, resourcePath }) {
  const [searchParams, setSearchParams] = useSearchParams()
  const filters = readFilters(searchParams, ['status', 'q', 'page'])
  const setFilter = changes => setSearchParams(compactParams({ ...filters, ...changes }), { replace: true })
  const list = useAdminList(identity, resourcePath, '/admin/disputes', compactParams({ ...filters, page: filters.page || 1 }))
  const disputes = list.data?.disputes || []
  const counts = list.data?.status_counts || {}
  const filtered = filters.status || filters.q

  return (
    <AdminLayout>
      <p className="mb-5 max-w-3xl text-sm text-content-muted">Chargebacks reported by Stripe. Respond to them in the Stripe Dashboard; this list is read-only. A lost dispute is deducted from the organizer’s next settlement.</p>
      <div className="mb-4 flex flex-wrap gap-2" role="group" aria-label="Filter disputes by status">
        {['', ...STATUSES].map(status => (
          <button key={status || 'all'} type="button" aria-pressed={filters.status === status} onClick={() => setFilter({ status, page: '' })}
            className={`min-h-11 rounded-full px-4 text-sm font-medium ring-1 transition-[background-color,transform] duration-150 ease-out-strong active:scale-[0.97] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus ${filters.status === status ? 'bg-neutral-900 text-white ring-neutral-900' : 'bg-white text-neutral-700 ring-neutral-200 hover:bg-neutral-50'}`}>
            {status ? adminLabel(status) : 'All'}{status && list.data ? ` (${counts[status] || 0})` : ''}
          </button>
        ))}
      </div>
      <OperationalSearch label="Find a dispute" hint="Search by order number, buyer, event, organizer or Stripe dispute ID." query={filters.q} onSearch={q => setFilter({ q, page: '' })} busy={list.loading} />
      <div className="card overflow-hidden" aria-busy={list.loading}>
        {list.loading && !list.data ? <div className="flex justify-center py-12"><Loader2 aria-label="Loading disputes" className="h-6 w-6 animate-spin text-brand-500" /></div>
          : list.error && !list.data ? <div role="alert" className="p-5 text-sm text-red-700">{list.error} <button type="button" onClick={list.reload} className="min-h-11 rounded px-2 font-semibold underline">Try again</button></div>
            : !disputes.length ? <div className="px-5 py-10 text-center">
              <p className="font-medium text-neutral-900">{filtered ? 'No disputes match these filters.' : 'No disputes recorded.'}</p>
              <p className="mt-1 text-sm text-content-muted">{filtered ? 'Clear the search or choose another status.' : 'Disputes appear here when Stripe reports a chargeback.'}</p>
            </div>
              : <table className={foldTable}>
                <thead><tr className="border-b border-neutral-100 text-left text-content-muted">
                  <th scope="col" className="px-3 py-3 font-medium">Opened</th><th scope="col" className="px-3 py-3 font-medium">Order</th><th scope="col" className="px-3 py-3 font-medium">Event and organizer</th>
                  <th scope="col" className="px-3 py-3 text-right font-medium">Amount</th><th scope="col" className="px-3 py-3 font-medium">Status</th><th scope="col" className="px-3 py-3 font-medium">Reason</th>
                </tr></thead>
                <tbody>
                  {disputes.map(dispute => (
                    <tr key={dispute.id} className={foldRow}>
                      <td data-label="Opened" className={foldCell}><span><span className="block text-neutral-900">{formatDate(dispute.opened_at)}</span><span className="block font-mono text-xs text-content-muted [overflow-wrap:anywhere]">{dispute.provider_dispute_id}</span></span></td>
                      <td data-label="Order" className={foldCell}><span className="min-w-0">
                        <Link to={`/admin/orders?search=${encodeURIComponent(`#${dispute.order.id}`)}`} className="font-medium text-brand-700 underline underline-offset-2 hover:text-brand-900">Order #{dispute.order.id}</Link>
                        <span className="block text-xs text-content-muted [overflow-wrap:anywhere]">{dispute.order.buyer_name} · {dispute.order.buyer_email}</span>
                      </span></td>
                      <td data-label="Event" className={foldCell}><span className="min-w-0"><span className="block text-neutral-900 [overflow-wrap:anywhere]">{dispute.event.title}</span><span className="block text-xs text-content-muted [overflow-wrap:anywhere]">{dispute.organization.name}</span></span></td>
                      <td data-label="Amount" className={`${foldCell} md:text-right`}><span className="font-semibold text-neutral-900">{money(dispute.amount_cents, dispute.currency)}</span></td>
                      <td data-label="Status" className={foldCell}><span><span className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ring-1 ${statusTone[dispute.status]}`}>{adminLabel(dispute.status)}</span>{dispute.closed_at && <span className="block text-xs text-content-muted">Closed {formatDate(dispute.closed_at)}</span>}</span></td>
                      <td data-label="Reason" className={foldCell}><span className="text-neutral-700">{REASONS[dispute.reason] || adminLabel(dispute.reason) || 'Not given'}</span></td>
                    </tr>
                  ))}
                </tbody>
              </table>}
      </div>
      <OperationalPagination meta={list.data?.meta} page={Number(filters.page) || 1} onPage={page => setFilter({ page: String(page) })} busy={list.loading} label="Dispute pages" />
    </AdminLayout>
  )
}

export default function AdminDisputesPage() {
  return <AdminSessionGate resourcePath="/admin/disputes" Session={AdminDisputesSession} />
}
