import { useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import AdminLayout from './AdminLayout'
import AdminSessionGate from './AdminSessionGate'
import OperationalPagination from '../../components/OperationalPagination'
import RefundReconciliationQueue from '../../components/RefundReconciliationQueue'
import apiClient from '../../api/client'
import { compactParams, readFilters, useAdminList } from './adminOperations'

const endpoint = '/admin/refund_reconciliation'
const statuses = [
  ['', 'All unresolved'], ['pending', 'Pending'], ['failed', 'Failed'], ['cancelled', 'Cancelled'], ['needs_manual', 'Needs a manual return'],
  ['waiting_on_pending_refund', 'Waiting on Stripe'], ['waiting_on_dispute', 'Waiting on a dispute'],
  ['request_unexecuted', 'Buyer request not yet refunded'], ['dispute_open', 'Open dispute'],
]

function AdminRefundReconciliationSession({ identity, resourcePath }) {
  const [searchParams, setSearchParams] = useSearchParams()
  const filters = readFilters(searchParams, ['status', 'age_days', 'event_id', 'page'])
  const [eventInput, setEventInput] = useState(filters.event_id)
  const [notice, setNotice] = useState('')
  const setFilter = changes => setSearchParams(compactParams({ ...filters, ...changes }), { replace: true })
  const list = useAdminList(identity, resourcePath, endpoint, compactParams({ ...filters, page: filters.page || 1 }))
  const items = list.data?.items || []
  const action = async (item, kind, payload) => {
    const request = list.beginRequest()
    if (!request) throw new Error('This page is no longer active.')
    try {
      await apiClient.post(`${endpoint}/${encodeURIComponent(item.type)}/${item.id}/${kind}`, payload, request.config)
      if (request.current()) {
        setNotice(`${item.order_reference || `Order #${item.order_id}`}: ${kind === 'manual_return' ? 'return recorded' : kind === 'unable' ? 'reason recorded; amount remains owed' : kind === 'resync' ? 'Stripe status checked' : 'refund retry requested'}.`)
        list.reload()
      }
    } catch (failure) {
      request.handleError(failure)
      throw failure
    } finally { request.release() }
  }

  return <AdminLayout>
    <p className="mb-5 max-w-3xl text-sm text-content-muted">Refunds that still need a confirmed outcome. Review the amount owed, take the next step, and keep manual return evidence with the record.</p>
    <div className="card mb-5 grid gap-3 p-4 sm:grid-cols-2 xl:grid-cols-3">
      <label className="block text-sm font-medium text-neutral-800">Status
        <select className="input mt-1" value={filters.status} onChange={event => setFilter({ status: event.target.value, page: '' })}>
          {statuses.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
        </select>
      </label>
      <label className="block text-sm font-medium text-neutral-800">Age
        <select className="input mt-1" value={filters.age_days} onChange={event => setFilter({ age_days: event.target.value, page: '' })}>
          <option value="">Any age</option><option value="1">At least 1 day</option><option value="3">At least 3 days</option><option value="7">At least 7 days</option>
        </select>
      </label>
      <form onSubmit={event => { event.preventDefault(); setFilter({ event_id: eventInput.trim(), page: '' }) }} className="flex items-end gap-2">
        <label className="min-w-0 flex-1 text-sm font-medium text-neutral-800">Event number
          <input className="input mt-1" type="number" min="1" inputMode="numeric" value={eventInput} onChange={event => setEventInput(event.target.value)} placeholder="All events" />
        </label>
        <button type="submit" className="btn-secondary min-h-11">Apply</button>
      </form>
    </div>
    {notice && <p role="status" className="mb-4 rounded-lg border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-900">{notice}</p>}
    {list.loading && !list.data ? <div role="status" className="flex justify-center py-12"><Loader2 aria-hidden="true" className="h-6 w-6 animate-spin text-brand-500" /><span className="sr-only">Loading refund issues</span></div>
      : list.error && !list.data ? <div role="alert" className="card p-5 text-sm text-red-700">{list.error} <button type="button" className="min-h-11 font-semibold underline" onClick={list.reload}>Try again</button></div>
        : <RefundReconciliationQueue items={items} admin onAction={action} busy={list.loading} />}
    {list.error && list.data && <p role="alert" className="mt-3 text-sm text-red-700">{list.error} <button type="button" className="font-semibold underline" onClick={list.reload}>Try again</button></p>}
    <OperationalPagination meta={list.data?.meta && { ...list.data.meta, total_count: list.data.meta.total_count ?? list.data.meta.total }} page={Number(filters.page) || 1} onPage={page => setFilter({ page: String(page) })} busy={list.loading} label="Refund issue pages" />
  </AdminLayout>
}

export default function AdminRefundReconciliationPage() {
  return <AdminSessionGate resourcePath={endpoint} Session={AdminRefundReconciliationSession} />
}
