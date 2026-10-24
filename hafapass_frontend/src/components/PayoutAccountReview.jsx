import { useId, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import apiClient from '../api/client'
import Dialog from './Dialog'
import PaymentReadinessReviewDialog from './PaymentReadinessReviewDialog'
import { mutationErrorMessage } from '../pages/admin/adminOperations'
import { payoutReviewLabel } from '../utils/payoutLabels'
import { taxClassificationLabel } from '../utils/taxInformation'

const controls = {
  payee_matches: 'The payee name matches the W-9 legal name or business name.',
  details_complete: 'The mailing address or bank details look complete.',
  organization_confirmed: 'I’m approving this payout method for this organization.',
}

function dateString(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`
}

function nextReviewDate() {
  const now = new Date()
  const next = new Date(now.getFullYear() + 1, now.getMonth(), 1)
  next.setDate(Math.min(now.getDate(), new Date(next.getFullYear(), next.getMonth() + 1, 0).getDate()))
  return dateString(next)
}

// Only allowlisted display fields: never render account_number or a full TIN.
export function PayoutAccountDetails({ account, includeTax = false }) {
  const details = account.payout_details || {}
  const tax = account.tax_information || {}
  const fields = account.provider === 'check'
    ? [['Pay to', details.payee_name], ['Delivery', details.delivery_method === 'pickup' ? 'Pickup' : 'Mail'], ['Address or pickup note', details.delivery_method === 'pickup' ? details.pickup_note : details.mailing_address], ['Memo', details.memo]]
    : account.provider === 'manual'
      ? [['Bank', details.bank_name], ['Account holder', details.account_holder_name], ['Account', details.masked_account]] : []
  if (includeTax) fields.push(['W-9 certified', tax.w9_on_file ? 'Yes' : 'No'], ['Legal name', tax.legal_name], ['Business name', tax.business_name], ['Tax classification', taxClassificationLabel(tax.tax_classification)], ['TIN', tax.masked_tin])
  return <dl className="mt-3 grid min-w-0 gap-3 text-sm sm:grid-cols-2">{fields.filter(([, value]) => value).map(([label, value]) => <div key={label} className="min-w-0 [overflow-wrap:anywhere]"><dt className="text-content-muted">{label}</dt><dd className="whitespace-pre-line font-medium text-neutral-900">{value}</dd></div>)}</dl>
}

function PayoutReviewDialog({ account, action, beginRequest, onClose, onSaved, onRefresh }) {
  const titleId = useId()
  const [checked, setChecked] = useState({})
  const [note, setNote] = useState('')
  const [reviewBy, setReviewBy] = useState(nextReviewDate)
  const [busy, setBusy] = useState(false)
  const [stale, setStale] = useState(false)
  const saving = useRef(false)
  const [error, setError] = useState('')
  const review = account.payout_review
  const approving = action === 'approve'
  const ready = approving ? review.can_approve && !review.missing?.length && Object.keys(controls).every(key => checked[key]) && reviewBy > dateString(new Date()) : Boolean(note.trim())
  const submit = async event => {
    event.preventDefault()
    if (!ready || stale || saving.current || !review.review_state_digest) return
    const request = beginRequest()
    if (!request) return
    saving.current = true
    setBusy(true); setError('')
    try {
      await apiClient.post(`/admin/connected_accounts/${account.id}/${approving ? 'approve_payout_method' : 'request_payout_changes'}`, {
        ...(approving ? { controls: Object.fromEntries(Object.keys(controls).map(key => [key, true])), review_by: reviewBy } : {}),
        note: note.trim() || null, expected_digest: review.review_state_digest,
      }, request.config)
      if (request.current()) onSaved(approving ? 'Payout method approved.' : 'Changes requested. The organizer can see your note.')
    } catch (failure) {
      if (!request.current() || request.handleError(failure)) return
      if (failure.response?.status === 409) setStale(true)
      setError(failure.response?.status === 409 ? 'The payout details changed. Close this dialog and refresh before reviewing again.' : mutationErrorMessage(failure))
    } finally { request.release(); saving.current = false; setBusy(false) }
  }
  return <Dialog labelledBy={titleId} busy={busy} onClose={onClose} className="max-w-xl">
    <form onSubmit={submit} className="min-w-0 [overflow-wrap:anywhere]">
      <h2 id={titleId} className="text-lg font-semibold text-neutral-900">{approving ? 'Approve payout method' : 'Ask for changes'}</h2>
      <p className="mt-2 text-sm text-neutral-700">{account.organization_name}. {approving ? 'Confirm the details below. Your approval is recorded in the audit log; it does not send money.' : 'Tell the organizer what to correct. This note will be visible in their payout settings.'}</p>
      <p className="mt-3 text-sm text-neutral-800">{account.provider === 'check' ? `Check payable to ${account.payout_details?.payee_name || 'Not provided'}` : `Bank transfer · ${account.payout_details?.bank_name || 'Not provided'} · ${account.payout_details?.masked_account || 'No account'}`}. W-9: {account.tax_information?.legal_name || 'Not certified'}.</p>
      {approving && <fieldset disabled={busy} className="mt-5 space-y-3"><legend className="mb-2 text-sm font-semibold">Confirm your review</legend>{Object.entries(controls).map(([key, label]) => <label key={key} className="flex min-h-11 items-start gap-3 text-sm"><input type="checkbox" checked={!!checked[key]} onChange={event => setChecked(value => ({ ...value, [key]: event.target.checked }))} className="mt-1 h-4 w-4 shrink-0 accent-brand-600" />{label}</label>)}</fieldset>}
      <label className="mt-4 block text-sm font-medium">{approving ? 'Note (optional, visible to organizer)' : 'What needs to change? (required)'}<textarea required={!approving} disabled={busy} value={note} onChange={event => setNote(event.target.value)} rows={3} maxLength={500} className="input mt-1" /></label>
      {approving && <label className="mt-4 block text-sm font-medium">Review again by<input type="date" required min={dateString(new Date(Date.now() + 86400000))} disabled={busy} value={reviewBy} onChange={event => setReviewBy(event.target.value)} className="input mt-1" /><span className="mt-1 block text-xs text-content-muted">Defaults to 12 months from today.</span></label>}
      <details className="mt-4 rounded-lg border border-neutral-200 px-3"><summary tabIndex={0} className="min-h-11 cursor-pointer py-3 text-sm font-semibold">Review payout and W-9 details</summary><div className="pb-3"><PayoutAccountDetails account={account} includeTax /></div></details>
      {error && <p role="alert" className="mt-4 rounded-lg bg-red-50 p-3 text-sm text-red-800">{error}</p>}
      <div className="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end"><button type="button" onClick={onClose} disabled={busy} className="btn-secondary">Cancel</button>{stale && <button type="button" onClick={() => { onClose(); onRefresh() }} className="btn-secondary">Close and refresh</button>}<button type="submit" disabled={busy || stale || !ready || !review.review_state_digest} className="btn-primary">{busy ? 'Saving…' : approving ? 'Approve payout method' : 'Send changes request'}</button></div>
    </form>
  </Dialog>
}

export function PayoutAccountReviewCard({ account, beginRequest, onChanged }) {
  const reasonsId = useId()
  const [action, setAction] = useState(null)
  const [notice, setNotice] = useState('')
  const review = account.payout_review
  const manual = review?.manual === true && ['check', 'manual'].includes(account.provider)
  const missing = review?.missing || []
  const blocked = !review?.can_approve || missing.length > 0 || !review.review_state_digest
  return <article className="min-w-0 rounded-xl border border-neutral-200 bg-white p-4 [overflow-wrap:anywhere]">
    <h3 className="font-semibold text-neutral-900">{account.organization_name || 'Organization'} · {({ check: 'Check', manual: 'Bank transfer', paypal: 'PayPal', stripe: 'Stripe' })[account.provider] || 'Payout method'}</h3>
    {account.owner_email && <p className="mt-1 text-sm text-content-muted">{account.owner_email}</p>}
    {account.organization_id && <Link className="inline-flex min-h-11 items-center text-sm font-semibold text-brand-700 underline" to={`/admin/organizations/${account.organization_id}`}>Open organization</Link>}
    <p className="mt-2 text-sm font-semibold text-neutral-800">{payoutReviewLabel(account)}</p>
    {review?.note && <p className="mt-2 whitespace-pre-line text-sm text-neutral-700">Note to organizer: {review.note}</p>}
    {review?.review_by && <p className="mt-1 text-sm text-content-muted">Review again by {review.review_by}</p>}
    <PayoutAccountDetails account={account} includeTax />
    {missing.length > 0 && <div id={reasonsId} className="mt-3 text-sm text-amber-900"><p className="font-semibold">Before approval:</p><ul className="list-disc space-y-1 pl-5">{missing.map((item, index) => <li key={index}>{item}</li>)}</ul></div>}
    {manual && <>
      {blocked && !missing.length && <p id={reasonsId} className="mt-3 text-sm text-amber-900">{!review.review_state_digest ? 'Refresh to load the current review details.' : review.status === 'approved' ? 'This payout method is already approved.' : 'This payout method is not ready for approval. Check the organization’s setup.'}</p>}
      <div className="mt-4 flex flex-wrap gap-3"><button type="button" disabled={blocked} aria-describedby={blocked ? reasonsId : undefined} onClick={() => setAction('approve')} className="btn-primary">Approve payout method</button><button type="button" disabled={!review.review_state_digest} onClick={() => setAction('changes')} className="btn-secondary">Ask for changes</button></div>
    </>}
    <details className="mt-4 border-t border-neutral-200 pt-2"><summary className="min-h-11 cursor-pointer py-3 text-sm font-semibold text-neutral-700">Advanced</summary><PaymentReadinessReviewDialog account={account} onComplete={onChanged} /></details>
    {notice && <p role="status" className="mt-3 text-sm font-medium text-emerald-800">{notice}</p>}
    {action && <PayoutReviewDialog key={`${account.id}:${review.review_state_digest}:${action}`} account={account} action={action} beginRequest={beginRequest} onClose={() => setAction(null)} onRefresh={onChanged} onSaved={message => { setAction(null); setNotice(message); onChanged() }} />}
  </article>
}

export default function PayoutAccountReviewQueue({ queue, accounts, beginRequest, onChanged }) {
  const titleId = useId()
  const items = accounts || queue?.items || []
  return <section aria-labelledby={titleId} className="mb-6 min-w-0 rounded-2xl border border-neutral-200 bg-white/70 p-5 sm:p-6">
    <div className="flex flex-wrap items-center justify-between gap-3"><h2 id={titleId} className="text-lg font-semibold text-neutral-900">{accounts ? 'Payout accounts' : `Payout setups awaiting approval (${queue?.count || 0})`}</h2><button type="button" onClick={onChanged} className="btn-secondary min-h-11 text-sm">Refresh payout {accounts ? 'accounts' : 'setups'}</button></div>
    <p className="mt-1 text-sm text-content-muted">Review the payee, payout details and W-9 together before approving.</p>
    <div className="mt-4 space-y-4">{items.map(account => <PayoutAccountReviewCard key={account.id} account={account} beginRequest={beginRequest} onChanged={onChanged} />)}</div>
    {!items.length && <p className="mt-4 text-sm text-neutral-700">{accounts ? 'No payout accounts saved yet.' : 'No payout setups are waiting for approval.'}</p>}
  </section>
}
