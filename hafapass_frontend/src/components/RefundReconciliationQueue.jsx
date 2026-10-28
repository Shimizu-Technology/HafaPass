import { useId, useState } from 'react'
import Dialog from './Dialog'
import { fromEventLocalInput, toEventLocalInput } from '../utils/eventTime'
import { adminLabel } from '../pages/admin/adminLabels'
import { errorMessage, foldCell, foldRow, foldTable, money, statusTone } from '../pages/admin/adminOperations'

const ageLabel = seconds => {
  const hours = Math.max(0, Math.floor(Number(seconds || 0) / 3600))
  if (hours < 1) return 'Less than 1 hour'
  if (hours < 24) return `${hours} ${hours === 1 ? 'hour' : 'hours'}`
  const days = Math.floor(hours / 24)
  return `${days} ${days === 1 ? 'day' : 'days'}`
}

const returnKind = item => {
  if (['cash', 'door_cash'].includes(item.manual_type)) return 'cash'
  if (['card', 'door_card'].includes(item.manual_type)) return 'card'
  return null
}

const actionLabel = (action, item) => {
  if (action === 'retry') return item.type === 'request' ? 'Issue refund' : 'Retry refund'
  if (action === 'resync') return 'Check Stripe status'
  if (action === 'manual_return') return `Record ${returnKind(item)} return`
  return 'Mark unable to refund'
}

const needsVerification = item => item.type === 'exception' || item.buyer_amount_unverified

function availableActions(item, admin, canRecordCash) {
  // Verification can reconcile existing operations, but must not invite another
  // return or label an unknown buyer balance as an unpaid refund.
  if (needsVerification(item)) return admin && (item.type === 'exception' || (item.type === 'refund' && item.status === 'pending')) ? ['resync'] : []
  const actions = []
  if (admin && ((['refund', 'cancellation'].includes(item.type) && ['failed', 'cancelled'].includes(item.status)) || (item.type === 'request' && item.status === 'request_unexecuted'))) actions.push('retry')
  if (admin && ((item.type === 'refund' && item.status === 'pending') || item.type === 'exception')) actions.push('resync')
  if ((canRecordCash && returnKind(item) === 'cash') || (admin && returnKind(item))) actions.push('manual_return')
  if (admin) actions.push('unable')
  return actions
}

const issueLabel = status => ({
  request_unexecuted: 'Buyer request not refunded',
  waiting_on_pending_refund: 'Waiting for Stripe',
  waiting_on_dispute: 'Waiting for dispute',
  dispute_open: 'Dispute open',
  provider_review: 'External refund needs verification',
})[status] || adminLabel(status)

function VerificationAmount({ item }) {
  return <>
    <strong className="block text-neutral-900">Buyer balance needs verification</strong>
    {item.type !== 'exception' ? <span className="block text-content-muted">Recorded liability: {money(item.amount_cents)}</span>
      : item.provider_amount_kind === 'aggregate' ? <span className="block text-content-muted">
        {item.provider_reported_amount_cents == null ? 'Provider returned total is unknown.' : `Stripe reports ${money(item.provider_reported_amount_cents)} returned in total.`}
        {item.provider_verification_amount_cents != null && <span className="block">{money(item.provider_verification_amount_cents)} not yet matched to booked refunds.</span>}
      </span> : <span className="block text-content-muted">{item.provider_reported_amount_cents == null
        ? 'Provider operation amount is unknown.' : `Provider operation amount: ${money(item.provider_reported_amount_cents)}. Outcome needs verification.`}</span>}
  </>
}

function ActionDialog({ item, action, onClose, onAction, busy }) {
  const titleId = useId()
  const [reference, setReference] = useState('')
  const [returnedAt, setReturnedAt] = useState(() => toEventLocalInput(new Date(), 'Pacific/Guam'))
  const [note, setNote] = useState('')
  const [reason, setReason] = useState('')
  const [error, setError] = useState('')
  const manual = action === 'manual_return'
  const unable = action === 'unable'
  const submit = async event => {
    event.preventDefault()
    const returned = manual ? fromEventLocalInput(returnedAt, 'Pacific/Guam') : null
    if (manual && (!reference.trim() || !note.trim() || !returned || returned > new Date())) {
      setError('Enter a reference, a return date no later than today, and a note.')
      return
    }
    if (unable && !reason.trim()) { setError('Explain why the buyer cannot be refunded yet.'); return }
    setError('')
    try {
      await onAction(item, action, manual ? { reference: reference.trim(), returned_at: returned.toISOString(), note: note.trim() }
        : unable ? { reason: reason.trim() } : {})
      onClose()
    } catch (failure) {
      setError(errorMessage(failure, 'This action could not be completed. Check the refund status and try again.'))
    }
  }
  return <Dialog labelledBy={titleId} onClose={onClose} busy={busy} className="max-w-lg">
    <form noValidate onSubmit={submit}>
      <h2 id={titleId} className="text-lg font-semibold text-neutral-900">{actionLabel(action, item)} for order {item.order_reference || `#${item.order_id}`}</h2>
      {needsVerification(item) ? <div className="mt-2 text-sm text-neutral-700"><VerificationAmount item={item} />
        <p className="mt-2">Check existing Stripe operations to establish the buyer balance. This check does not send another refund.</p>
      </div> : <p className="mt-2 text-sm text-neutral-700">{money(item.amount_cents)} is still owed to the buyer. {manual
        ? 'Return the money to the buyer first, then record the evidence here.'
        : unable ? 'This keeps the amount visible as an outstanding liability.'
          : action === 'retry' ? item.type === 'request' ? 'Issue the approved buyer request once and confirm its outcome.' : 'Check the earlier attempt before retrying. The original refund must not be duplicated.'
            : 'Read the latest refund outcome from Stripe.'}</p>}
      {manual && <div className="mt-4 space-y-3">
        <label className="block text-sm font-medium text-neutral-800">{returnKind(item) === 'card' ? 'Card provider return reference' : 'Cash return reference'}
          <input className="input mt-1" value={reference} maxLength={255} onChange={event => setReference(event.target.value)} required /></label>
        <label className="block text-sm font-medium text-neutral-800">Returned at (Guam time)
          <input className="input mt-1" type="datetime-local" value={returnedAt} onChange={event => setReturnedAt(event.target.value)} required /></label>
        <label className="block text-sm font-medium text-neutral-800">How the return was confirmed
          <textarea className="input mt-1" value={note} maxLength={1000} onChange={event => setNote(event.target.value)} required /></label>
      </div>}
      {unable && <label className="mt-4 block text-sm font-medium text-neutral-800">Why the refund cannot be completed
        <textarea className="input mt-1" value={reason} maxLength={1000} onChange={event => setReason(event.target.value)} required /></label>}
      {error && <p role="alert" className="mt-3 text-sm text-red-700">{error}</p>}
      <div className="mt-5 flex flex-wrap gap-2">
        <button type="button" className="btn-secondary" disabled={busy} onClick={onClose}>Cancel</button>
        <button type="submit" className="btn-primary" disabled={busy}>{busy ? 'Working…' : actionLabel(action, item)}</button>
      </div>
    </form>
  </Dialog>
}

export default function RefundReconciliationQueue({ items, admin = false, canRecordCash = false, onAction, busy = false }) {
  const [selected, setSelected] = useState(null)
  const [acting, setActing] = useState(false)
  const submit = async (item, action, payload) => {
    setActing(true)
    try { await onAction(item, action, payload) }
    finally { setActing(false) }
  }
  if (!items.length) return <div className="card px-5 py-10 text-center"><p className="font-medium text-neutral-900">No unresolved refunds match this view.</p><p className="mt-1 text-sm text-content-muted">New issues will appear here until they are resolved.</p></div>
  return <>
    <div className="card overflow-hidden" aria-busy={busy || acting}>
      <table className={foldTable}>
        <thead><tr className="border-b border-neutral-100 text-left text-content-muted">
          <th scope="col" className="px-3 py-3 font-medium">Order and buyer</th><th scope="col" className="px-3 py-3 font-medium">Event and organizer</th>
          <th scope="col" className="px-3 py-3 font-medium">Buyer balance</th><th scope="col" className="px-3 py-3 font-medium">Issue</th><th scope="col" className="px-3 py-3 font-medium">Age</th>
          <th scope="col" className="px-3 py-3 font-medium">Next step</th><th scope="col" className="px-3 py-3 font-medium">Actions</th>
        </tr></thead>
        <tbody>{items.map(item => <tr key={`${item.type}:${item.id}`} className={foldRow}>
          <td data-label="Order" className={foldCell}><span className="min-w-0"><strong className="block text-neutral-900">{item.order_reference || `Order #${item.order_id}`}</strong><span className="block [overflow-wrap:anywhere] text-content-muted">{item.buyer_name || item.buyer_email || 'Buyer details unavailable'}</span>{item.buyer_name && item.buyer_email && <span className="block [overflow-wrap:anywhere] text-content-muted">{item.buyer_email}</span>}</span></td>
          <td data-label="Event" className={foldCell}><span className="min-w-0"><span className="block [overflow-wrap:anywhere] text-neutral-900">{item.event_title || `Event #${item.event_id}`}</span><span className="block [overflow-wrap:anywhere] text-content-muted">{item.organization_name}</span></span></td>
          <td data-label="Buyer balance" className={foldCell}><span>{needsVerification(item) ? <VerificationAmount item={item} /> : <strong className="text-neutral-900">{money(item.amount_cents)}</strong>}</span></td>
          <td data-label="Issue" className={foldCell}><span><span className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ring-1 ${statusTone[item.status] || 'bg-amber-50 text-amber-900 ring-amber-200'}`}>{issueLabel(item.status)}</span><span className="mt-1 block [overflow-wrap:anywhere] text-content-muted">{item.reason}</span>{item.organizer_already_paid && <span className="mt-1 block font-semibold text-red-700">{needsVerification(item) ? 'Organizer was already paid; verify recovery exposure' : 'Organizer was already paid; recover from organizer'}</span>}{item.unable_reason && <span className="mt-1 block [overflow-wrap:anywhere] font-medium text-red-700">Manual review: {item.unable_reason}</span>}</span></td>
          <td data-label="Age" className={foldCell}><span className={Number(item.age_seconds) > 3 * 86400 ? 'font-semibold text-red-700' : 'text-neutral-700'}>{ageLabel(item.age_seconds)}</span></td>
          <td data-label="Next step" className={foldCell}><span className="[overflow-wrap:anywhere] text-neutral-700">{item.next_action || 'Review this refund'}</span></td>
          <td data-label="Actions" className={foldCell}><div className="flex flex-wrap gap-2">{availableActions(item, admin, canRecordCash).map(action => <button key={action} type="button" disabled={busy || acting} onClick={() => setSelected({ item, action })} className="btn-secondary min-h-11 text-sm disabled:opacity-50">{actionLabel(action, item)}</button>)}</div></td>
        </tr>)}</tbody>
      </table>
    </div>
    {selected && <ActionDialog item={selected.item} action={selected.action} busy={acting} onAction={submit} onClose={() => setSelected(null)} />}
  </>
}
