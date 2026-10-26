import { Link, useSearchParams } from 'react-router-dom'
import AdminLayout from './AdminLayout'
import AdminSessionGate from './AdminSessionGate'
import OperationalPagination from '../../components/OperationalPagination'
import { compactParams, formatDateTime, useAdminList } from './adminOperations'

const endpoint = '/admin/operations'
const historyCategory = 'external_message_receipts'
const categories = {
  failed_messages_last_hour: {
    label: 'Failed deliveries · last hour',
    guidance: 'Delivery records marked failed and updated within the last hour. Review the delivery history in Support before considering an existing safe retry.',
    link: '/support', linkLabel: 'Open delivery history in Support',
  },
  stale_message_events: {
    label: 'Unprocessed email receipts · over 5 minutes',
    guidance: 'Provider receipts awaiting processing or a linked HåfaPass delivery. Sent or delivered receipts do not mean an email failed. A receipt can arrive before its delivery is linked. Review the provider account, webhook configuration and delivery history; do not resend solely because a receipt is unlinked.',
    link: '/support', linkLabel: 'Compare HåfaPass delivery history',
  },
  failed_payment_webhooks: {
    label: 'Failed payment updates',
    guidance: 'Payment webhooks marked failed. Ask the payment operations owner to compare the original provider event with persisted payment state. This page does not retry updates or establish the payment outcome.',
  },
  open_reconciliation_exceptions: {
    label: 'Open reconciliation exceptions',
    guidance: 'All open reconciliation exceptions, including those outside buyer refunds. The refund queue covers refund work only. Give the local record number to the finance owner for other exceptions; preserve evidence before any repair.',
    link: '/admin/refund_reconciliation', linkLabel: 'Open refund issues (refund exceptions only)',
  },
  unknown_card_present_results: {
    label: 'Unknown in-person card results',
    guidance: 'Card attempts with an unknown result. Ask the event finance owner to check the original provider transaction and local order before taking another payment. An unknown result is not a failed charge.',
  },
  [historyCategory]: {
    label: 'Confirmed external email receipts',
    guidance: 'Retained receipts confirmed to belong to another application. These records are excluded from operational warnings while unmatched and error-free. A matching HåfaPass delivery or processing error returns them to review. Original receipts remain available for normal reconciliation.',
  },
}
const states = {
  no_linked_delivery: 'No linked delivery',
  awaiting_processing: 'Linked delivery · awaiting processing',
  processing_error: 'Processing error recorded',
  external_confirmed: 'Confirmed external · retained',
}

function Record({ item, receipt }) {
  return <li className="min-w-0 rounded-lg border border-neutral-200 bg-white p-4 [overflow-wrap:anywhere]">
    <p className="font-semibold text-neutral-900">Record #{item.id}</p>
    {receipt ? <>
      <p className="mt-1 text-sm text-neutral-800">{item.provider} · {item.event_type}</p>
      <p className={`mt-2 text-sm font-medium ${item.review_state === 'external_confirmed' ? 'text-neutral-800' : 'text-amber-950'}`}>{states[item.review_state] || 'Needs review'}</p>
      <p className="mt-1 text-sm text-neutral-700">{item.delivery_id ? `Linked delivery #${item.delivery_id}` : 'No HåfaPass delivery linked to this receipt.'} {item.processing_error ? 'Error details are restricted; ask the operations owner to inspect them securely.' : 'No processing error recorded.'}</p>
      <p className="mt-2 text-xs text-neutral-600">Received {formatDateTime(item.received_at)} · Provider time {formatDateTime(item.occurred_at)}</p>
    </> : <>
      <p className="mt-1 text-sm text-neutral-700">{item.provider && `${item.provider} · `}{String(item.status).replaceAll('_', ' ')}</p>
      {item.order_id && <p className="mt-1 text-sm text-neutral-700">Order #{item.order_id}{item.event_id ? ` · Event #${item.event_id}` : ''}</p>}
      <p className="mt-2 text-xs text-neutral-600">Recorded {formatDateTime(item.updated_at || item.created_at || item.initiated_at)}</p>
    </>}
  </li>
}

function OperationsSession({ identity, resourcePath }) {
  const [params, setParams] = useSearchParams()
  const category = params.get('category') || ''
  const requestedPage = Number(params.get('page'))
  const page = Number.isSafeInteger(requestedPage) && requestedPage > 0 ? requestedPage : 1
  const list = useAdminList(identity, resourcePath, endpoint, compactParams({ category, page }))
  // Old rows belong to their old category while a navigation is in flight.
  const data = list.data
  const selected = data?.category
  const content = categories[selected]
  const total = data ? Object.keys(categories).filter(key => key !== historyCategory).reduce((sum, key) => sum + (data.signals[key] || 0), 0) : null
  const showingCurrent = data && (!category || selected === category) && data.meta.page === page
  const navigate = (nextCategory, nextPage = 1) => setParams({ category: nextCategory, page: String(nextPage) })

  return <AdminLayout>
    <p className="mb-4 max-w-3xl text-sm text-neutral-700">Review the records counted by the dashboard. Counts can change as processing continues or time windows move. This page only reads records.</p>
    <div className="mb-5 flex flex-wrap items-center justify-between gap-3">
      <p role="status" className="text-sm text-neutral-700">{list.loading ? 'Loading operational records…' : data ? `${total} operational records need review. Checked ${formatDateTime(data.checked_at)}.` : 'Operational counts unavailable.'}</p>
      <button type="button" className="btn-secondary min-h-11" disabled={list.loading} onClick={list.reload}>Refresh operational records</button>
    </div>
    {list.error && <div role="alert" className="mb-5 rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-900">
      Operational records could not be loaded. {data && 'Previously loaded counts may be out of date.'}
      <button type="button" className="ml-2 inline-flex min-h-11 items-center font-semibold underline" onClick={list.reload}>Try again</button>
    </div>}
    {data && <>
      <div className="mb-5 grid gap-2 sm:grid-cols-2" aria-label="Operational categories">
        {Object.entries(categories).map(([key, entry]) => <button key={key} type="button" aria-pressed={selected === key} disabled={list.loading}
          className={`min-h-11 rounded-lg border p-3 text-left text-sm focus-visible:ring-2 focus-visible:ring-focus ${selected === key ? 'border-brand-300 bg-brand-50 text-brand-950' : 'border-neutral-200 bg-white text-neutral-800'}`}
          onClick={() => navigate(key)}>{entry.label}: <strong>{key === historyCategory ? (data.history_counts?.[key] || 0) : data.signals[key]}</strong></button>)}
      </div>
      {showingCurrent && !list.loading && !list.error && content && <section aria-labelledby="operational-category-heading">
        <h2 id="operational-category-heading" className="text-lg font-semibold text-neutral-900">{content.label} ({data.meta.total_count})</h2>
        <p className="mt-2 max-w-3xl text-sm text-neutral-700">{content.guidance}</p>
        {content.link && <Link className="mt-2 inline-flex min-h-11 items-center text-sm font-semibold text-brand-700 underline" to={content.link}>{content.linkLabel}</Link>}
        {data.items.length ? <ul className="mt-4 space-y-3">{data.items.map(item => <Record key={item.id} item={item} receipt={selected === 'stale_message_events' || selected === historyCategory} />)}</ul>
          : <p role="status" className="mt-4 rounded-lg border border-neutral-200 bg-white p-4 text-sm text-neutral-700">{data.meta.total_count > 0 ? 'No records on this page. Return to the first page or refresh.' : 'No records in this category. Other categories may still need review.'}</p>}
        <OperationalPagination meta={data.meta} page={page} onPage={next => navigate(selected, next)} busy={list.loading} label="Operational record pages" />
        {page > 1 && <button type="button" className="btn-secondary mt-3 min-h-11" onClick={() => navigate(selected)}>First page</button>}
      </section>}
    </>}
  </AdminLayout>
}

export default function AdminOperationsPage() {
  return <AdminSessionGate resourcePath={endpoint} Session={OperationsSession} />
}
