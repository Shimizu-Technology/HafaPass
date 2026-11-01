import { useCallback, useEffect, useId, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import AdminLayout from './AdminLayout'
import AdminSessionGate from './AdminSessionGate'
import Dialog from '../../components/Dialog'
import OperationalSearch from '../../components/OperationalSearch'
import OperationalPagination from '../../components/OperationalPagination'
import apiClient from '../../api/client'
import { adminLabel } from './adminLabels'
import { compactParams, foldCell, foldRow, foldTable, formatDateTime, money, mutationErrorMessage, readFilters, statusTone, useAdminList } from './adminOperations'
import { reconciliationCodeGuidance, reconciliationCodeLabel } from './reconciliationCodes'

const endpoint = '/admin/reconciliation_exceptions'
const STATUSES = [['open', 'Open'], ['resolved', 'Resolved'], ['all', 'All']]
const plural = (count, word) => `${count} ${word}${count === 1 ? '' : 's'}`
const orderLink = order => `/admin/orders?search=${encodeURIComponent(`#${order.id}`)}`
const tone = { ...statusTone, resolved: 'bg-emerald-50 text-emerald-800 ring-emerald-200' }

function Amounts({ issue }) {
  if (issue.late_capture_owed_cents != null) return <span>{money(issue.late_capture_owed_cents, issue.payment?.currency)} owed to the buyer</span>
  if (issue.expected_amount_cents == null && issue.actual_amount_cents == null) return <span className="text-content-muted">No amount recorded</span>
  return <span>
    {issue.expected_amount_cents != null && <span className="block">Expected {money(issue.expected_amount_cents, issue.expected_currency)}</span>}
    {issue.actual_amount_cents != null && <span className="block">Received {money(issue.actual_amount_cents, issue.actual_currency)}</span>}
  </span>
}

function Holds({ issue }) {
  if (issue.status !== 'open') return <span className="text-content-muted">Nothing (resolved)</span>
  if (!issue.blocks_payouts) return <span className="text-content-muted">No payouts (not linked to an order)</span>
  return <span className="text-amber-950">All payouts for {issue.organization.name} and the statement for {issue.event.title}</span>
}

// The open exceptions that freeze payouts, grouped by organization. One open
// exception on any order holds every payout for that organization.
function PayoutBlocks({ blocks, onShow, activeOrganization }) {
  if (!blocks) return null
  const organizations = blocks.organizations || []
  return <section aria-labelledby="payout-blocks-heading" className="mb-5 rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950">
    <h2 id="payout-blocks-heading" className="font-semibold">Payouts on hold</h2>
    <p className="mt-1">Any open exception linked to an order holds every payout for that organization and stops its event statement from being finalized.</p>
    {organizations.length === 0 ? <p className="mt-2">No organization payouts are held by open exceptions.</p>
      : <ul className="mt-3 space-y-3">
        {organizations.map(entry => <li key={entry.organization.id} className="rounded-lg border border-amber-200 bg-white p-3 text-neutral-900">
          <p className="font-semibold [overflow-wrap:anywhere]">{entry.organization.name}: all payouts held by {plural(entry.open_count, 'open exception')}</p>
          <p className="mt-1 text-neutral-700 [overflow-wrap:anywhere]">Statements blocked: {entry.events.map(event => `${event.title} (${event.open_count})`).join(', ')}</p>
          {String(activeOrganization) !== String(entry.organization.id) && <button type="button" onClick={() => onShow(entry.organization.id)} className="mt-1 inline-flex min-h-11 items-center font-semibold text-brand-700 underline underline-offset-2">
            Show these exceptions<span className="sr-only"> for {entry.organization.name}</span>
          </button>}
        </li>)}
      </ul>}
    {blocks.unlinked_open_count > 0 && <p className="mt-3">{plural(blocks.unlinked_open_count, 'open exception')} {blocks.unlinked_open_count === 1 ? 'is' : 'are'} not linked to an order and {blocks.unlinked_open_count === 1 ? 'does' : 'do'} not hold payouts.</p>}
  </section>
}

function ExceptionDialog({ id, beginRequest, onClose, onChanged }) {
  const titleId = useId()
  const [issue, setIssue] = useState(null)
  const [loadError, setLoadError] = useState('')
  const [note, setNote] = useState('')
  const [confirmRefund, setConfirmRefund] = useState(false)
  const [confirmed, setConfirmed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const load = useCallback(() => {
    const request = beginRequest()
    if (!request) return
    setLoadError('')
    apiClient.get(`${endpoint}/${id}`, request.config)
      .then(response => { if (request.current()) setIssue(response.data.reconciliation_exception) })
      .catch(failure => { if (!request.handleError(failure) && request.current()) setLoadError('This exception could not be loaded.') })
      .finally(() => request.release())
  }, [beginRequest, id])
  useEffect(load, [load])

  const act = async (path, payload, message) => {
    const request = beginRequest()
    if (!request) return
    setBusy(true)
    setError('')
    try {
      const response = await apiClient.post(`${endpoint}/${id}/${path}`, payload, request.config)
      if (!request.current()) return
      setIssue(response.data.reconciliation_exception)
      setConfirmRefund(false)
      setConfirmed(false)
      setNote('')
      onChanged(message(response.data))
    } catch (failure) {
      if (request.handleError(failure) || !request.current()) return
      setError(mutationErrorMessage(failure))
    } finally { request.release(); setBusy(false) }
  }

  // Codes that could hide unrecorded money need an explicit confirmation and
  // a longer evidence note; the server enforces the same rule.
  const confirmation = issue?.resolve_confirmation
  const resolve = submitEvent => {
    submitEvent.preventDefault()
    const text = note.trim()
    if (!text) { setError('Add a note explaining how this was reconciled.'); return }
    if (confirmation && !confirmed) { setError('Tick the confirmation to resolve without moving money.'); return }
    if (confirmation && text.length < confirmation.evidence_note_minimum) { setError(`Describe the evidence you checked (at least ${confirmation.evidence_note_minimum} characters).`); return }
    act('resolve', confirmation ? { note: text, [confirmation.flag]: true } : { note: text }, () => `Exception #${id} resolved.`)
  }

  const actions = issue?.actions || []
  return <Dialog labelledBy={titleId} busy={busy} onClose={onClose} className="max-w-2xl">
    <h2 id={titleId} className="text-lg font-semibold text-neutral-900">Exception #{id}</h2>
    {loadError ? <p role="alert" className="mt-3 text-sm text-red-800">{loadError} <button type="button" onClick={load} className="min-h-11 font-semibold underline">Try again</button></p>
      : !issue ? <div className="flex justify-center py-8"><Loader2 aria-label="Loading exception" className="h-6 w-6 animate-spin text-brand-500" /></div>
        : <div className="mt-3 space-y-4 text-sm text-neutral-800 [overflow-wrap:anywhere]">
          <div>
            <p className="font-semibold text-neutral-900">{reconciliationCodeLabel(issue.code)}</p>
            <p className="font-mono text-xs text-content-muted">{issue.code}</p>
            <p className="mt-2">{reconciliationCodeGuidance(issue.code)}</p>
          </div>
          <dl className="grid gap-x-4 gap-y-2 sm:grid-cols-[10rem_1fr]">
            <dt className="font-medium text-neutral-900">Status</dt><dd><span className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ring-1 ${tone[issue.status]}`}>{adminLabel(issue.status)}</span>{issue.resolved_at && <span className="ml-2 text-content-muted">{formatDateTime(issue.resolved_at)}</span>}</dd>
            <dt className="font-medium text-neutral-900">Recorded</dt><dd>{formatDateTime(issue.created_at)}</dd>
            <dt className="font-medium text-neutral-900">Holds</dt><dd><Holds issue={issue} /></dd>
            <dt className="font-medium text-neutral-900">Amount</dt><dd><Amounts issue={issue} /></dd>
            <dt className="font-medium text-neutral-900">Order</dt><dd>{issue.order ? <><Link to={orderLink(issue.order)} className="font-medium text-brand-700 underline underline-offset-2">Order #{issue.order.id}</Link> · {issue.order.buyer_name} · {issue.order.buyer_email} · {adminLabel(issue.order.status)}</> : 'Not linked to an order'}</dd>
            {issue.event && <><dt className="font-medium text-neutral-900">Event</dt><dd>{issue.event.title} ({adminLabel(issue.event.status)}) · {issue.organization.name}</dd></>}
            {issue.payment && <><dt className="font-medium text-neutral-900">Payment</dt><dd>{issue.payment.provider} {issue.payment.provider_environment || ''} · {money(issue.payment.amount_cents, issue.payment.currency)} · {adminLabel(issue.payment.status)}<span className="block font-mono text-xs text-content-muted">{issue.payment.provider_payment_id}</span></dd></>}
            {issue.webhook_event_id && <><dt className="font-medium text-neutral-900">Webhook record</dt><dd>#{issue.webhook_event_id}</dd></>}
          </dl>
          {Object.keys(issue.details || {}).length > 0 && <div>
            <h3 className="font-semibold text-neutral-900">Recorded details</h3>
            <dl className="mt-1 grid gap-x-4 gap-y-1 sm:grid-cols-[10rem_1fr]">{Object.entries(issue.details).map(([key, value]) => <div key={key} className="contents"><dt className="text-content-muted">{adminLabel(key)}</dt><dd className="font-mono text-xs">{String(value)}</dd></div>)}</dl>
          </div>}
          {issue.history?.length > 0 && <div>
            <h3 className="font-semibold text-neutral-900">History</h3>
            <ul className="mt-1 space-y-1">{issue.history.map(entry => <li key={entry.id}>{formatDateTime(entry.occurred_at)} · {adminLabel(entry.action.split('.').at(-1))} · {entry.actor?.email || adminLabel(entry.source)}{entry.note && <span className="block whitespace-pre-wrap text-neutral-700">{entry.note}</span>}</li>)}</ul>
          </div>}
          {error && <p role="alert" className="rounded-lg border border-red-200 bg-red-50 p-3 text-red-800">{error}</p>}
          {actions.includes('refund_buyer') && <div className="rounded-lg border border-neutral-200 p-3">
            {confirmRefund ? <>
              <p>Refund {money(issue.late_capture_owed_cents, issue.payment?.currency)} to the buyer's card? This uses the same refund as the automatic retry, so it is never sent twice. The buyer gets a refund email.</p>
              <div className="mt-3 flex flex-wrap gap-2">
                <button type="button" disabled={busy} className="btn-primary" onClick={() => act('refund_buyer', {}, data => `Exception #${id}: refund ${data.refund.status === 'succeeded' ? 'sent' : 'requested'}.`)}>{busy ? 'Refunding…' : 'Yes, refund buyer'}</button>
                <button type="button" disabled={busy} className="btn-secondary" onClick={() => setConfirmRefund(false)}>Cancel</button>
              </div>
            </> : <button type="button" className="btn-primary" onClick={() => setConfirmRefund(true)}>Refund buyer</button>}
          </div>}
          {actions.includes('fraud_refund') && <Link to={orderLink(issue.order)} className="inline-flex min-h-11 items-center font-semibold text-brand-700 underline underline-offset-2">Open the order to cancel tickets and refund as fraud</Link>}
          {actions.includes('verify_external_refund') && <Link to={`/admin/refund_reconciliation?event_id=${issue.event.id}`} className="inline-flex min-h-11 items-center font-semibold text-brand-700 underline underline-offset-2">Verify the Stripe refund in Refund issues</Link>}
          {issue.resolve_blocked_reason && <p className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-amber-950"><span className="font-semibold">Cannot resolve with a note yet. </span>{issue.resolve_blocked_reason}</p>}
          {actions.includes('resolve') && <form noValidate onSubmit={resolve} className="border-t border-neutral-200 pt-4">
            <label className="block font-medium text-neutral-900">
              {confirmation ? 'Evidence note' : 'Resolution note'} <span className="text-red-700">*</span>
              <textarea rows={3} value={note} maxLength={2000} onChange={changeEvent => setNote(changeEvent.target.value)} className="input mt-1" />
            </label>
            <p className="mt-1 text-xs text-content-muted">{confirmation ? `Use the action above when money needs to be recorded or refunded. Resolve here only if it does not, and say what you checked in Stripe (at least ${confirmation.evidence_note_minimum} characters).` : 'Say what you checked and what you changed.'} Resolving only closes this record; it does not move money.{issue.late_capture_owed_cents > 0 ? ' The buyer is still owed this payment; refund them first unless it was returned outside HåfaPass.' : ''}</p>
            {confirmation && <label className="mt-3 flex min-h-11 items-start gap-2 text-neutral-900">
              <input type="checkbox" checked={confirmed} onChange={changeEvent => setConfirmed(changeEvent.target.checked)} className="mt-1 h-4 w-4" />
              <span>{confirmation.label}</span>
            </label>}
            <button type="submit" disabled={busy} className="btn-secondary mt-3">{busy ? 'Saving…' : confirmation ? 'Resolve without moving money' : 'Resolve with note'}</button>
          </form>}
        </div>}
    <div className="mt-6 flex justify-end"><button type="button" disabled={busy} onClick={onClose} className="btn-secondary">Close</button></div>
  </Dialog>
}

function AdminReconciliationExceptionsSession({ identity, resourcePath }) {
  const [searchParams, setSearchParams] = useSearchParams()
  const filters = readFilters(searchParams, ['status', 'code', 'organization_id', 'q', 'page'])
  const status = filters.status || 'open'
  const setFilter = changes => setSearchParams(compactParams({ ...filters, ...changes }), { replace: true })
  const list = useAdminList(identity, resourcePath, endpoint, compactParams({ ...filters, status, page: filters.page || 1 }))
  const [selected, setSelected] = useState(null)
  const [notice, setNotice] = useState('')
  const issues = list.data?.reconciliation_exceptions || []
  const counts = list.data?.status_counts || {}
  const codes = Object.entries(list.data?.open_code_counts || {})
  const activeOrganization = list.data?.payout_blocks?.organizations?.find(entry => String(entry.organization.id) === filters.organization_id)?.organization
  const filtered = filters.code || filters.organization_id || filters.q

  return <AdminLayout>
    <p className="mb-4 max-w-3xl text-sm text-content-muted">Payment records HåfaPass could not match automatically. Review each one against Stripe, use the action offered where there is a safe one, and resolve it with a note. Resolving closes the record; it never moves money by itself, so it is unavailable while a late capture still owes the buyer, and needs an explicit confirmation for fraud warnings and unverified refunds.</p>
    {notice && <p role="status" className="mb-4 rounded-lg border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-900">{notice}</p>}
    <PayoutBlocks blocks={list.data?.payout_blocks} activeOrganization={filters.organization_id} onShow={id => setFilter({ organization_id: String(id), status: 'open', page: '' })} />
    <div className="mb-4 flex flex-wrap gap-2" role="group" aria-label="Filter exceptions by status">
      {STATUSES.map(([value, label]) => <button key={value} type="button" aria-pressed={status === value} onClick={() => setFilter({ status: value === 'open' ? '' : value, page: '' })}
        className={`min-h-11 rounded-full px-4 text-sm font-medium ring-1 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus ${status === value ? 'bg-neutral-900 text-white ring-neutral-900' : 'bg-white text-neutral-700 ring-neutral-200 hover:bg-neutral-50'}`}>
        {label}{value !== 'all' && list.data ? ` (${counts[value] || 0})` : ''}
      </button>)}
    </div>
    <div className="mb-4 flex flex-wrap items-end gap-3">
      <label className="text-sm font-medium text-neutral-900">Code
        <select value={filters.code} onChange={changeEvent => setFilter({ code: changeEvent.target.value, page: '' })} className="input mt-1 block min-w-[16rem]">
          <option value="">All codes</option>
          {filters.code && !codes.some(([code]) => code === filters.code) && <option value={filters.code}>{reconciliationCodeLabel(filters.code)}</option>}
          {codes.map(([code, count]) => <option key={code} value={code}>{reconciliationCodeLabel(code)} ({count} open)</option>)}
        </select>
      </label>
      {filters.organization_id && <p className="flex min-h-11 items-center gap-2 text-sm text-neutral-800">
        Organization: {activeOrganization?.name || `#${filters.organization_id}`}
        <button type="button" onClick={() => setFilter({ organization_id: '', page: '' })} className="min-h-11 font-semibold text-brand-700 underline">Clear organization</button>
      </p>}
    </div>
    <OperationalSearch label="Find an exception" hint="Search by order number, code or Stripe payment ID." query={filters.q} onSearch={q => setFilter({ q, page: '' })} busy={list.loading} />
    <div className="card overflow-hidden" aria-busy={list.loading}>
      {list.loading && !list.data ? <div className="flex justify-center py-12"><Loader2 aria-label="Loading exceptions" className="h-6 w-6 animate-spin text-brand-500" /></div>
        : list.error && !list.data ? <div role="alert" className="p-5 text-sm text-red-700">{list.error} <button type="button" onClick={list.reload} className="min-h-11 rounded px-2 font-semibold underline">Try again</button></div>
          : !issues.length ? <div className="px-5 py-10 text-center">
            <p className="font-medium text-neutral-900">{filtered ? 'No exceptions match these filters.' : status === 'open' ? 'No open reconciliation exceptions.' : 'No exceptions recorded.'}</p>
            <p className="mt-1 text-sm text-content-muted">{filtered ? 'Clear the filters or choose another status.' : 'Exceptions appear here when a payment, refund or fee cannot be matched automatically.'}</p>
          </div>
            : <table className={foldTable}>
              <thead><tr className="border-b border-neutral-100 text-left text-content-muted">
                <th scope="col" className="px-3 py-3 font-medium">Recorded</th><th scope="col" className="px-3 py-3 font-medium">Exception</th>
                <th scope="col" className="px-3 py-3 font-medium">Order and event</th><th scope="col" className="px-3 py-3 font-medium">Amount</th>
                <th scope="col" className="px-3 py-3 font-medium">Holds up</th><th scope="col" className="px-3 py-3 font-medium"><span className="sr-only">Actions</span></th>
              </tr></thead>
              <tbody>
                {issues.map(issue => <tr key={issue.id} className={foldRow}>
                  <td data-label="Recorded" className={foldCell}><span><span className="block text-neutral-900">{formatDateTime(issue.created_at)}</span><span className="block text-xs text-content-muted">#{issue.id}</span></span></td>
                  <td data-label="Exception" className={foldCell}><span><span className="block font-medium text-neutral-900">{reconciliationCodeLabel(issue.code)}</span><span className="block font-mono text-xs text-content-muted">{issue.code}</span><span className={`mt-1 inline-flex rounded-full px-2 py-0.5 text-xs font-medium ring-1 ${tone[issue.status]}`}>{adminLabel(issue.status)}</span></span></td>
                  <td data-label="Order" className={foldCell}>{issue.order ? <span className="min-w-0">
                    <Link to={orderLink(issue.order)} className="font-medium text-brand-700 underline underline-offset-2 hover:text-brand-900">Order #{issue.order.id}</Link>
                    {issue.event && <span className="block text-xs text-content-muted [overflow-wrap:anywhere]">{issue.event.title} · {issue.organization.name}</span>}
                  </span> : <span className="text-content-muted">No order</span>}</td>
                  <td data-label="Amount" className={foldCell}><Amounts issue={issue} /></td>
                  <td data-label="Holds up" className={foldCell}><Holds issue={issue} /></td>
                  <td data-label="Actions" className={foldCell}><button type="button" onClick={() => { setNotice(''); setSelected(issue.id) }} className="btn-secondary min-h-11 whitespace-nowrap">Review<span className="sr-only"> exception #{issue.id}</span></button></td>
                </tr>)}
              </tbody>
            </table>}
    </div>
    <OperationalPagination meta={list.data?.meta} page={Number(filters.page) || 1} onPage={page => setFilter({ page: String(page) })} busy={list.loading} label="Exception pages" />
    {selected && <ExceptionDialog id={selected} beginRequest={list.beginRequest} onClose={() => setSelected(null)} onChanged={message => { setNotice(message); list.reload() }} />}
  </AdminLayout>
}

export default function AdminReconciliationExceptionsPage() {
  return <AdminSessionGate resourcePath={endpoint} Session={AdminReconciliationExceptionsSession} />
}
