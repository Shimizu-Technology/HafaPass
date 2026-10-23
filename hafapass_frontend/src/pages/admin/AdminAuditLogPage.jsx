import { useId, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { ChevronDown, Loader2 } from 'lucide-react'
import AdminLayout from './AdminLayout'
import AdminSessionGate from './AdminSessionGate'
import OperationalSearch from '../../components/OperationalSearch'
import OperationalPagination from '../../components/OperationalPagination'
import { adminLabel } from './adminLabels'
import { auditChanges, compactParams, formatDateTime, readFilters, useAdminList } from './adminOperations'

const FILTERS = ['q', 'area', 'from', 'to', 'target_type', 'target_id', 'organization_id', 'page']
const MAX_VALUE_LENGTH = 160

const display = value => {
  if (value === undefined) return '—'
  if (value === null || value === '') return 'empty'
  const text = typeof value === 'string' ? value : JSON.stringify(value)
  return text.length > MAX_VALUE_LENGTH ? `${text.slice(0, MAX_VALUE_LENGTH)}…` : text
}

const actionLabel = action => {
  const [area, ...rest] = String(action).split('.')
  return `${adminLabel(area)}: ${adminLabel(rest.join(' ').replaceAll('.', ' ')) || 'event'}`
}

function Entry({ entry }) {
  const [open, setOpen] = useState(false)
  const panelId = useId()
  const changes = auditChanges(entry.before_data, entry.after_data)
  const metadata = entry.metadata && Object.keys(entry.metadata).length ? entry.metadata : null
  return (
    <li className="border-b border-neutral-100 last:border-b-0">
      <div className="grid gap-2 px-4 py-3 md:grid-cols-[11rem_minmax(0,1fr)_minmax(0,14rem)_auto] md:items-start md:gap-4">
        <p className="text-xs text-content-muted md:pt-0.5 md:text-sm"><time dateTime={entry.occurred_at}>{formatDateTime(entry.occurred_at)}</time></p>
        <div className="min-w-0">
          <p className="font-medium text-neutral-900">{actionLabel(entry.action)}</p>
          <p className="font-mono text-xs text-content-muted [overflow-wrap:anywhere]">{entry.action}</p>
          <p className="mt-1 text-sm text-neutral-700">
            {entry.target.type} #{entry.target.id}{entry.organization ? ` · ${entry.organization.name}` : ''}
            {changes.length > 0 && <span className="text-content-muted"> · {changes.length} {changes.length === 1 ? 'field' : 'fields'} changed</span>}
          </p>
        </div>
        <p className="min-w-0 text-sm text-neutral-700 [overflow-wrap:anywhere]">{entry.actor ? (entry.actor.name ? `${entry.actor.name} (${entry.actor.email})` : entry.actor.email) : 'System'}</p>
        <button type="button" aria-expanded={open} aria-controls={panelId} onClick={() => setOpen(value => !value)}
          className="inline-flex min-h-11 items-center gap-1 justify-self-start rounded-lg px-2 text-sm font-semibold text-brand-700 hover:bg-neutral-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus">
          Details<span className="sr-only"> for entry {entry.id}</span>
          <ChevronDown aria-hidden="true" className={`h-4 w-4 transition-transform duration-150 ease-out-strong motion-reduce:transition-none ${open ? 'rotate-180' : ''}`} />
        </button>
      </div>
      {open && <div id={panelId} className="space-y-3 bg-neutral-50 px-4 py-3 text-sm">
        {changes.length > 0 ? (
          <dl className="space-y-1.5">
            {changes.map(change => (
              <div key={change.key} className="grid gap-1 sm:grid-cols-[12rem_minmax(0,1fr)]">
                <dt className="font-mono text-xs text-neutral-700 [overflow-wrap:anywhere]">{change.key}</dt>
                <dd className="min-w-0 text-neutral-900 [overflow-wrap:anywhere]"><span className="text-content-muted line-through decoration-neutral-400">{display(change.before)}</span> <span aria-hidden="true">→</span><span className="sr-only">changed to</span> {display(change.after)}</dd>
              </div>
            ))}
          </dl>
        ) : <p className="text-content-muted">No before/after values recorded.</p>}
        {metadata && <details>
          <summary className="inline-flex min-h-11 cursor-pointer items-center font-medium text-neutral-800">Recorded context</summary>
          <pre className="max-h-64 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-white p-3 text-xs text-neutral-800 ring-1 ring-neutral-200">{JSON.stringify(metadata, null, 2)}</pre>
        </details>}
        <p className="text-xs text-content-muted">Entry #{entry.id}{entry.request_id ? ` · request ${entry.request_id}` : ''}</p>
      </div>}
    </li>
  )
}

function AdminAuditLogSession({ identity, resourcePath }) {
  const [searchParams, setSearchParams] = useSearchParams()
  const filters = readFilters(searchParams, FILTERS)
  const setFilter = changes => setSearchParams(compactParams({ ...filters, ...changes }), { replace: true })
  const list = useAdminList(identity, resourcePath, '/admin/audit_logs', compactParams({ ...filters, page: filters.page || 1 }))
  const entries = list.data?.audit_logs || []
  const filtered = FILTERS.some(name => name !== 'page' && filters[name])
  const scopeQuery = new URLSearchParams(compactParams({ ...filters, target_type: '', target_id: '', organization_id: '', page: '' }))

  return (
    <AdminLayout>
      <p className="mb-5 max-w-3xl text-sm text-content-muted">Recorded activity, newest first. Entry identities cannot be changed or deleted. Personal details may be redacted for privacy or retention.</p>
      {(filters.target_type || filters.organization_id) && <div className="mb-4 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-brand-200 bg-brand-50 px-4 py-3 text-sm text-brand-900">
        <p>Showing entries for {filters.target_type ? `${filters.target_type}${filters.target_id ? ` #${filters.target_id}` : ''}` : `organization #${filters.organization_id}`}</p>
        <Link to={`?${scopeQuery}`} className="min-h-11 content-center font-semibold underline underline-offset-2">Show all entries</Link>
      </div>}
      <OperationalSearch label="Search the audit log" hint="Search by action, administrator email, record type or request ID." query={filters.q} onSearch={q => setFilter({ q, page: '' })} busy={list.loading} />
      <div className="mb-4 flex flex-wrap items-end gap-3">
        <label className="text-sm font-medium text-neutral-900">
          Area
          <select value={filters.area} onChange={event => setFilter({ area: event.target.value, page: '' })} className="input mt-1 !w-auto !py-2">
            <option value="">All areas</option>
            {(list.data?.areas || (filters.area ? [filters.area] : [])).map(area => <option key={area} value={area}>{adminLabel(area)}</option>)}
          </select>
        </label>
        <label className="text-sm font-medium text-neutral-900">
          From
          <input type="date" value={filters.from} max={filters.to || undefined} onChange={event => setFilter({ from: event.target.value, page: '' })} className="input mt-1 !w-auto !py-2" />
        </label>
        <label className="text-sm font-medium text-neutral-900">
          To
          <input type="date" value={filters.to} min={filters.from || undefined} onChange={event => setFilter({ to: event.target.value, page: '' })} className="input mt-1 !w-auto !py-2" />
        </label>
        {filtered && <button type="button" onClick={() => setSearchParams({}, { replace: true })} className="btn-ghost !px-3">Clear all filters</button>}
      </div>
      <div className="card overflow-hidden" aria-busy={list.loading}>
        {list.loading && !list.data ? <div className="flex justify-center py-12"><Loader2 aria-label="Loading audit log" className="h-6 w-6 animate-spin text-brand-500" /></div>
          : list.error && !list.data ? <div role="alert" className="p-5 text-sm text-red-700">{list.error} <button type="button" onClick={list.reload} className="min-h-11 rounded px-2 font-semibold underline">Try again</button></div>
            : !entries.length ? <div className="px-5 py-10 text-center">
              <p className="font-medium text-neutral-900">{filtered ? 'No entries match these filters.' : 'No audit entries yet.'}</p>
              {filtered && <p className="mt-1 text-sm text-content-muted">Try a wider date range or clear the search.</p>}
            </div>
              : <>
                <div aria-hidden="true" className="hidden border-b border-neutral-100 px-4 py-3 text-sm font-medium text-content-muted md:grid md:grid-cols-[11rem_minmax(0,1fr)_minmax(0,14rem)_auto] md:gap-4"><span>When</span><span>Action and record</span><span>By</span><span className="w-20" /></div>
                <ul aria-label="Audit entries">{entries.map(entry => <Entry key={entry.id} entry={entry} />)}</ul>
              </>}
      </div>
      {list.error && list.data && <p role="alert" className="mt-3 text-sm text-red-700">{list.error} <button type="button" onClick={list.reload} className="min-h-11 font-semibold underline">Try again</button></p>}
      <OperationalPagination meta={list.data?.meta} page={Number(filters.page) || 1} onPage={page => setFilter({ page: String(page) })} busy={list.loading} label="Audit log pages" />
    </AdminLayout>
  )
}

export default function AdminAuditLogPage() {
  return <AdminSessionGate resourcePath="/admin/audit-log" Session={AdminAuditLogSession} />
}
