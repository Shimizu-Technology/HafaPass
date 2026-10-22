import { useId, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'
import AdminSessionGate from './AdminSessionGate'
import Dialog from '../../components/Dialog'
import OperationalSearch from '../../components/OperationalSearch'
import OperationalPagination from '../../components/OperationalPagination'
import { adminLabel } from './adminLabels'
import {
  compactParams, errorMessage, foldCell, foldRow, foldTable, formatDate, formatDateTime, money, readFilters, statusTone, useAdminList,
} from './adminOperations'

const PAYOUT_STATUSES = ['pending', 'processing', 'held', 'paid', 'failed', 'reversed']
const OUTCOMES = {
  paid: { label: 'Paid', body: 'The money reached the organizer’s bank account.' },
  failed: { label: 'Failed', body: 'The transfer did not complete. The amount becomes available to pay out again.' },
  reversed: { label: 'Reversed', body: 'A transfer was returned or clawed back after it was sent.' },
}
// Manual entries only. The sign comes from the kind, so admins always enter a positive amount.
const ADJUSTMENT_KINDS = {
  manual_credit: { label: 'Credit the organizer', sign: 1, body: 'Adds to what the organizer is owed.' },
  manual_debit: { label: 'Debit the organizer', sign: -1, body: 'Takes from what the organizer is owed.' },
  reserve_hold: { label: 'Hold in reserve', sign: -1, body: 'Holds back part of the balance, for example against chargeback risk.' },
  reserve_release: { label: 'Release reserve', sign: 1, body: 'Returns previously reserved money to the balance.' },
}
const ADJUSTMENT_LABELS = {
  ...Object.fromEntries(Object.entries(ADJUSTMENT_KINDS).map(([kind, option]) => [kind, option.label.replace(' the organizer', '')])),
  dispute_loss: 'Dispute loss', dispute_recovery: 'Dispute recovery', processing_fee: 'Processing fee', payout_reversal: 'Payout reversal',
}

const Badge = ({ status }) => <span className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ring-1 ${statusTone[status] || 'bg-neutral-100 text-neutral-700 ring-neutral-200'}`}>{adminLabel(status)}</span>
const nowForInput = () => {
  const now = new Date()
  now.setSeconds(0, 0)
  return new Date(now.getTime() - now.getTimezoneOffset() * 60000).toISOString().slice(0, 16)
}
const placeholderReference = value => !value || value.startsWith('sim_') || value.startsWith('manual_po_')

function ReconcileDialog({ payout, beginRequest, onClose, onSaved }) {
  const titleId = useId()
  const [outcome, setOutcome] = useState(payout.allowed_outcomes[0])
  const [transferId, setTransferId] = useState(placeholderReference(payout.provider_payout_id) ? '' : payout.provider_payout_id)
  const [reference, setReference] = useState('')
  const [confirmedAt, setConfirmedAt] = useState(nowForInput)
  const [reason, setReason] = useState('')
  const [acknowledged, setAcknowledged] = useState(false)
  const [sentBeforeCancellation, setSentBeforeCancellation] = useState(false)
  const [cancellationReason, setCancellationReason] = useState('')
  const buyerRefundsUnresolved = payout.cancellation_refunds_unresolved || payout.outstanding_buyer_balance_cents > 0
  const needsCancellationConfirmation = payout.event_cancelled && buyerRefundsUnresolved
  const nonCancellationLiability = !payout.event_cancelled && buyerRefundsUnresolved
  const [errors, setErrors] = useState({})
  const [busy, setBusy] = useState(false)
  const keepsTransferId = payout.status === 'paid'
  // Organizers are paid by check from Shimizu Technology's business account:
  // the check number is the transfer ID and the date on the check is the
  // confirmation time.
  const isCheck = payout.provider === 'check'
  // The payee shown is the one this payout was approved for. If the organizer
  // changed it since, the API refuses "Paid" until the change is approved.
  const payeeChanged = isCheck && payout.payee_changed === true
  const [payeeConfirmed, setPayeeConfirmed] = useState(false)
  const taxApprovalChanged = payout.tax_approval_changed === true
  const legacyTaxPayee = !payout.tax_information_snapshot || Object.keys(payout.tax_information_snapshot).length === 0
  const [taxPayeeConfirmed, setTaxPayeeConfirmed] = useState(false)
  const [legacyPayeeName, setLegacyPayeeName] = useState('')
  const [legacyEvidenceNote, setLegacyEvidenceNote] = useState('')
  const [legacyPayeeConfirmed, setLegacyPayeeConfirmed] = useState(false)
  const describePayee = payee => payee ? `${payee.payee_name}${payee.delivery_method === 'pickup' ? ` · Pickup${payee.pickup_note ? ` — ${payee.pickup_note}` : ''}` : ` · Mail to ${payee.mailing_address}`}${payee.memo ? ` · Memo: ${payee.memo}` : ''}` : ''

  const submit = async event => {
    event.preventDefault()
    const found = {}
    const confirmed = new Date(confirmedAt)
    if (outcome === 'paid' && placeholderReference(transferId.trim())) found.transfer = isCheck ? 'Enter the check number.' : 'Enter the real bank or provider transfer ID.'
    if (!reference.trim()) found.reference = 'Enter the confirmation reference, such as the bank statement line.'
    if (Number.isNaN(confirmed.getTime())) found.confirmedAt = 'Enter when the outcome was confirmed.'
    else if (confirmed > new Date()) found.confirmedAt = 'The confirmation time cannot be in the future.'
    else if (confirmed < new Date(payout.created_at)) found.confirmedAt = 'The confirmation time must be after the payout was requested.'
    if (!reason.trim()) found.reason = 'Explain how you confirmed this outcome.'
    if (outcome === 'paid' && nonCancellationLiability) found.form = 'Resolve outstanding buyer refunds before recording this payout as paid.'
    if (outcome === 'paid' && needsCancellationConfirmation) {
      if (!sentBeforeCancellation) found.sentBeforeCancellation = 'Confirm the payout was sent before the cancellation.'
      if (!cancellationReason.trim()) found.cancellationReason = 'Explain why you are recording this payout while buyer refunds remain outstanding.'
    }
    if (payout.conflict && !acknowledged) found.conflict = 'Confirm you reviewed the provider conflict.'
    if (outcome === 'paid' && payeeChanged && !payeeConfirmed) found.payee = 'Confirm you wrote this check to the approved payee shown above.'
    if (outcome === 'paid' && legacyTaxPayee) {
      if (!legacyPayeeName.trim()) found.legacyPayeeName = 'Enter the payee who was actually paid.'
      if (!legacyEvidenceNote.trim()) found.legacyEvidenceNote = 'Enter a check number, bank reference, or other evidence note.'
      if (!legacyPayeeConfirmed) found.legacyPayee = 'Confirm this legacy payout was already sent to the payee entered here.'
    } else if (outcome === 'paid' && taxApprovalChanged && !taxPayeeConfirmed) found.taxPayee = 'Confirm the payout was already sent to the approved tax payee shown above.'
    setErrors(found)
    if (Object.keys(found).length) return
    const request = beginRequest()
    if (!request) return
    setBusy(true)
    try {
      const evidence = { reference: reference.trim(), reason: reason.trim(), confirmed_at: confirmed.toISOString(),
        ...(outcome === 'paid' && payeeChanged && payeeConfirmed ? { approved_payee_confirmed: true } : {}),
        ...(outcome === 'paid' && !legacyTaxPayee && taxApprovalChanged && taxPayeeConfirmed ? { approved_tax_payee_confirmed: true } : {}),
        ...(outcome === 'paid' && legacyTaxPayee ? { legacy_payee_name: legacyPayeeName.trim(), legacy_evidence_note: legacyEvidenceNote.trim(), legacy_payee_confirmed: true } : {}),
        ...(outcome === 'paid' && needsCancellationConfirmation ? { sent_before_cancellation_confirmed: true, cancellation_payout_reason: cancellationReason.trim() } : {}) }
      if (payout.conflict) evidence.conflict_audit_id = payout.conflict.audit_id
      const body = { status: outcome, evidence }
      if (transferId.trim() && !keepsTransferId) body.provider_payout_id = transferId.trim()
      await apiClient.patch(`/admin/payouts/${payout.id}`, body, request.config)
      if (request.current()) onSaved(`Payout #${payout.id} recorded as ${OUTCOMES[outcome].label.toLowerCase()}.`)
    } catch (failure) {
      if (request.handleError(failure) || !request.current()) return
      setErrors({ form: errorMessage(failure, 'The outcome was not recorded. Check your connection and try again.') })
    } finally { request.release(); setBusy(false) }
  }

  const fieldError = name => errors[name] && <p id={`reconcile-${name}-error`} className="mt-1 text-sm text-red-700">{errors[name]}</p>
  return (
    <Dialog labelledBy={titleId} busy={busy} onClose={onClose} className="max-w-xl">
      <form noValidate onSubmit={submit}>
        <h2 id={titleId} className="text-lg font-semibold text-neutral-900">Record outcome for payout #{payout.id}</h2>
        <p className="mt-1 text-sm text-content-muted">{money(payout.amount_cents, payout.currency)} to {payout.organization.name} for {payout.event.title}. Record only what the bank or provider has confirmed; your name and evidence go into the audit log.</p>
        {needsCancellationConfirmation && <div className="mt-3 rounded-lg border border-red-300 bg-red-50 p-3 text-sm text-red-900">
          <p className="font-semibold">{payout.outstanding_buyer_balance_cents > 0 ? `${money(payout.outstanding_buyer_balance_cents, payout.currency)} remains owed to buyers for this cancelled event.` : 'Buyer refunds are still pending for this cancelled event.'}</p>
          {outcome === 'paid' && <><label className="mt-3 flex items-start gap-2"><input type="checkbox" checked={sentBeforeCancellation} onChange={event => setSentBeforeCancellation(event.target.checked)} className="mt-0.5 h-4 w-4" />This payout was already sent before the cancellation</label>{fieldError('sentBeforeCancellation')}
            <label className="mt-3 block">Reason for recording an already sent payout<textarea value={cancellationReason} onChange={event => setCancellationReason(event.target.value)} maxLength={1000} className="input mt-1" /></label>{fieldError('cancellationReason')}</>}
        </div>}
        {nonCancellationLiability && <p className="mt-3 rounded-lg border border-red-300 bg-red-50 p-3 text-sm text-red-900">Buyer refunds remain unresolved. Resolve them before recording this payout as paid.</p>}
        {isCheck && payout.payee && <p className="mt-2 rounded-lg border border-neutral-200 bg-neutral-50 p-3 text-sm text-neutral-800 [overflow-wrap:anywhere]">Approved payee: <strong>{describePayee(payout.payee)}</strong></p>}
        {payeeChanged && <div className="mt-2 rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-950 [overflow-wrap:anywhere]">
          <p className="font-semibold">The payee on file is different from the approved payee above.</p>
          {payout.current_payee && <p className="mt-1">Now on file: {describePayee(payout.current_payee)}. Write and record this check only to the approved payee.</p>}
          {outcome === 'paid' && <label className="mt-2 flex min-h-11 items-start gap-2 font-medium">
            <input type="checkbox" checked={payeeConfirmed} onChange={event => setPayeeConfirmed(event.target.checked)} aria-describedby={errors.payee ? 'reconcile-payee-error' : undefined} className="mt-0.5 h-4 w-4 accent-brand-700" />
            I wrote this check to the approved payee shown above
          </label>}
          {fieldError('payee')}
        </div>}
        {legacyTaxPayee && outcome === 'paid' && <div className="mt-2 rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-950 [overflow-wrap:anywhere]">
          <p className="font-semibold">No W-9 was on file when this payout was created.</p>
          <label className="mt-2 block font-medium">Payee actually paid
            <input value={legacyPayeeName} onChange={event => setLegacyPayeeName(event.target.value)} maxLength={255} aria-invalid={!!errors.legacyPayeeName} className="input mt-1" />
          </label>
          {fieldError('legacyPayeeName')}
          <label className="mt-2 block font-medium">Evidence note or reference
            <input value={legacyEvidenceNote} onChange={event => setLegacyEvidenceNote(event.target.value)} maxLength={500} aria-invalid={!!errors.legacyEvidenceNote} className="input mt-1" />
          </label>
          {fieldError('legacyEvidenceNote')}
          <label className="mt-2 flex min-h-11 items-start gap-2 font-medium">
            <input type="checkbox" checked={legacyPayeeConfirmed} onChange={event => setLegacyPayeeConfirmed(event.target.checked)} className="mt-0.5 h-4 w-4 accent-brand-700" />
            This payout was already sent to the payee entered here; it was created before W-9 collection.
          </label>
          {fieldError('legacyPayee')}
        </div>}
        {!legacyTaxPayee && taxApprovalChanged && <div className="mt-2 rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-950 [overflow-wrap:anywhere]">
          <p className="font-semibold">The W-9 or payout approval on file differs from this payout’s approved tax identity.</p>
          <p className="mt-1">Approved tax payee: {payout.tax_information_snapshot?.legal_name || 'No W-9 on file at payout'}{payout.tax_information_snapshot?.masked_tin ? ` · ${payout.tax_information_snapshot.masked_tin}` : ''}.</p>
          {outcome === 'paid' && <label className="mt-2 flex min-h-11 items-start gap-2 font-medium">
            <input type="checkbox" checked={taxPayeeConfirmed} onChange={event => setTaxPayeeConfirmed(event.target.checked)} aria-describedby={errors.taxPayee ? 'reconcile-taxPayee-error' : undefined} className="mt-0.5 h-4 w-4 accent-brand-700" />
            This payout was already sent to the approved payee shown above
          </label>}
          {fieldError('taxPayee')}
        </div>}
        {isCheck && <p className="mt-2 text-sm text-content-muted">A check is recorded as paid on the date written on the check, not when it clears.</p>}
        {errors.form && <p role="alert" className="mt-4 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">{errors.form}</p>}
        {payout.conflict && <div className="mt-4 rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-950">
          <p className="font-semibold">The provider reported a result that conflicts with an earlier outcome.</p>
          <p className="mt-1">Recorded before: {adminLabel(payout.conflict.recorded_before?.status) || 'unknown'}{payout.conflict.recorded_before?.provider_payout_id ? ` (${payout.conflict.recorded_before.provider_payout_id})` : ''}. Provider now reports: {adminLabel(payout.conflict.provider_result?.status) || 'unknown'}{payout.conflict.provider_result?.provider_payout_id ? ` (${payout.conflict.provider_result.provider_payout_id})` : ''}, {formatDateTime(payout.conflict.occurred_at)}.</p>
          <label className="mt-2 flex min-h-11 items-center gap-2 font-medium">
            <input type="checkbox" checked={acknowledged} onChange={event => setAcknowledged(event.target.checked)} aria-describedby={errors.conflict ? 'reconcile-conflict-error' : undefined} className="h-4 w-4 accent-brand-700" />
            I reviewed conflict audit #{payout.conflict.audit_id}
          </label>
          {fieldError('conflict')}
        </div>}
        <fieldset className="mt-4">
          <legend className="text-sm font-medium text-neutral-900">Outcome</legend>
          <div className="mt-2 space-y-2">
            {payout.allowed_outcomes.map(value => (
              <label key={value} className={`flex cursor-pointer gap-3 rounded-lg border p-3 ${outcome === value ? 'border-brand-600 bg-brand-50' : 'border-neutral-200'}`}>
                <input type="radio" name="outcome" value={value} checked={outcome === value} onChange={() => setOutcome(value)} className="mt-1 h-4 w-4 accent-brand-700" />
                <span><span className="block font-medium text-neutral-900">{OUTCOMES[value].label}</span><span className="block text-sm text-content-muted">{OUTCOMES[value].body}</span></span>
              </label>
            ))}
          </div>
        </fieldset>
        <div className="mt-4 grid gap-4 sm:grid-cols-2">
          <div className="sm:col-span-2">
            <label className="block text-sm font-medium text-neutral-900">
              {isCheck ? 'Check number' : 'Transfer ID'} {outcome === 'paid' ? '(required)' : '(optional)'}
              <input value={transferId} disabled={keepsTransferId} onChange={event => setTransferId(event.target.value)} maxLength={255} aria-invalid={!!errors.transfer} aria-describedby={errors.transfer ? 'reconcile-transfer-error' : undefined} className={`input mt-1 ${errors.transfer ? 'input-error' : ''}`} />
            </label>
            {keepsTransferId && <p className="mt-1 text-sm text-content-muted">A reversal keeps the original {isCheck ? 'check number' : 'transfer ID'}.</p>}
            {fieldError('transfer')}
          </div>
          <div>
            <label className="block text-sm font-medium text-neutral-900">
              {isCheck ? 'Reference (for example the check register line)' : 'Confirmation reference'}
              <input value={reference} onChange={event => setReference(event.target.value)} maxLength={500} aria-invalid={!!errors.reference} aria-describedby={errors.reference ? 'reconcile-reference-error' : undefined} className={`input mt-1 ${errors.reference ? 'input-error' : ''}`} />
            </label>
            {fieldError('reference')}
          </div>
          <div>
            <label className="block text-sm font-medium text-neutral-900">
              {isCheck ? 'Date on the check' : 'Confirmed at'}
              <input type="datetime-local" value={confirmedAt} onChange={event => setConfirmedAt(event.target.value)} aria-invalid={!!errors.confirmedAt} aria-describedby={errors.confirmedAt ? 'reconcile-confirmedAt-error' : undefined} className={`input mt-1 ${errors.confirmedAt ? 'input-error' : ''}`} />
            </label>
            {fieldError('confirmedAt')}
          </div>
          <div className="sm:col-span-2">
            <label className="block text-sm font-medium text-neutral-900">
              How you confirmed it
              <textarea rows={3} value={reason} onChange={event => setReason(event.target.value)} maxLength={1000} aria-invalid={!!errors.reason} aria-describedby={errors.reason ? 'reconcile-reason-error' : undefined} className={`input mt-1 ${errors.reason ? 'input-error' : ''}`} />
            </label>
            {fieldError('reason')}
          </div>
        </div>
        <div className="mt-6 flex flex-wrap justify-end gap-3">
          <button type="button" disabled={busy} onClick={onClose} className="btn-secondary">Cancel</button>
          <button type="submit" disabled={busy} className={outcome === 'paid' ? 'btn-primary' : 'btn-danger'}>{busy ? 'Recording…' : `Record as ${OUTCOMES[outcome].label.toLowerCase()}`}</button>
        </div>
      </form>
    </Dialog>
  )
}

function ReleaseHoldDialog({ payout, beginRequest, onClose, onSaved }) {
  const titleId = useId()
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const unresolved = payout.cancellation_refunds_unresolved || payout.outstanding_buyer_balance_cents > 0
  const tooLarge = payout.amount_cents > payout.hold_available_cents
  const submit = async event => {
    event.preventDefault()
    const request = beginRequest()
    if (!request) return
    setBusy(true)
    setError('')
    try {
      await apiClient.post(`/admin/payouts/${payout.id}/release_hold`, {}, request.config)
      if (request.current()) onSaved(`Hold released for payout #${payout.id}.`)
    } catch (failure) {
      if (request.handleError(failure) || !request.current()) return
      setError(errorMessage(failure, 'The hold was not released. Check your connection and try again.'))
    } finally { request.release(); setBusy(false) }
  }
  return <Dialog labelledBy={titleId} busy={busy} onClose={onClose} className="max-w-lg">
    <form onSubmit={submit}>
      <h2 id={titleId} className="text-lg font-semibold text-neutral-900">Release hold on payout #{payout.id}</h2>
      <p className="mt-2 text-sm text-neutral-700">This restores the payout to {payout.held_from_status || 'its previous'} status. Amount: {money(payout.amount_cents, payout.currency)}.</p>
      {tooLarge && <p className="mt-3 rounded-lg bg-red-50 p-3 text-sm text-red-800">The payout exceeds the event’s current net payable ({money(payout.hold_available_cents, payout.currency)} available after other payouts). Record a failed outcome, then finalize a new settlement and reissue the correct amount.</p>}
      {!payout.held_from_status && <p className="mt-3 rounded-lg bg-red-50 p-3 text-sm text-red-800">The original payout status is unknown. Record an outcome and reissue instead of releasing this hold.</p>}
      {['provider_result_conflict', 'provider_result_unknown'].includes(payout.failure_code) && <p className="mt-3 rounded-lg bg-red-50 p-3 text-sm text-red-800">The provider result needs reconciliation before this hold can be released.</p>}
      {unresolved && <p className="mt-3 rounded-lg bg-amber-50 p-3 text-sm text-amber-950">Resolve all buyer refund liabilities before releasing this payout. If it was already sent before cancellation, record it as paid with the transfer evidence.</p>}
      {error && <p role="alert" className="mt-3 text-sm text-red-700">{error}</p>}
      <div className="mt-6 flex justify-end gap-3"><button type="button" onClick={onClose} disabled={busy} className="btn-secondary">Cancel</button><button type="submit" disabled={busy || unresolved || tooLarge || !payout.held_from_status || ['provider_result_conflict', 'provider_result_unknown'].includes(payout.failure_code)} className="btn-primary">{busy ? 'Releasing…' : 'Release hold'}</button></div>
    </form>
  </Dialog>
}

function AdjustmentDialog({ context, beginRequest, onClose, onSaved }) {
  const titleId = useId()
  const [kind, setKind] = useState('manual_credit')
  const [amount, setAmount] = useState('')
  const [reason, setReason] = useState('')
  const [reviewing, setReviewing] = useState(false)
  const [errors, setErrors] = useState({})
  const [busy, setBusy] = useState(false)
  const option = ADJUSTMENT_KINDS[kind]
  const cents = Math.round(Number(amount) * 100)
  const currency = context.organization.currency
  const target = context.event ? `${context.organization.name}, for ${context.event.title}` : `${context.organization.name} (organization balance, not a single event)`

  const review = event => {
    event.preventDefault()
    const found = {}
    if (!/^\d+(\.\d{1,2})?$/.test(amount.trim()) || cents <= 0) found.amount = 'Enter a positive amount in dollars and cents.'
    if (!reason.trim()) found.reason = 'Explain why this adjustment is needed.'
    setErrors(found)
    if (!Object.keys(found).length) setReviewing(true)
  }

  const post = async () => {
    const request = beginRequest()
    if (!request) return
    setBusy(true)
    try {
      await apiClient.post('/admin/balance_adjustments', {
        organization_id: context.organization.id, event_id: context.event?.id, kind,
        amount_cents: option.sign * cents, reason: reason.trim(),
      }, request.config)
      if (request.current()) onSaved(`${option.label} of ${money(cents, currency)} posted.`)
    } catch (failure) {
      if (request.handleError(failure) || !request.current()) return
      setReviewing(false)
      setErrors({ form: errorMessage(failure, 'The adjustment was not posted. Check your connection and try again.') })
    } finally { request.release(); setBusy(false) }
  }

  return (
    <Dialog labelledBy={titleId} busy={busy} onClose={onClose} className="max-w-lg">
      <h2 id={titleId} className="text-lg font-semibold text-neutral-900">{reviewing ? 'Post this adjustment?' : 'New balance adjustment'}</h2>
      <p className="mt-1 text-sm text-content-muted">For {target}.</p>
      {errors.form && <p role="alert" className="mt-4 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">{errors.form}</p>}
      {reviewing ? <>
        <dl className="mt-4 space-y-2 rounded-lg bg-neutral-50 p-4 text-sm ring-1 ring-neutral-200">
          <div className="flex justify-between gap-4"><dt className="text-content-muted">Type</dt><dd className="font-medium text-neutral-900">{option.label}</dd></div>
          <div className="flex justify-between gap-4"><dt className="text-content-muted">Effect on balance</dt><dd className="font-semibold text-neutral-900">{option.sign > 0 ? '+' : '−'}{money(cents, currency)}</dd></div>
          <div><dt className="text-content-muted">Reason</dt><dd className="mt-0.5 whitespace-pre-wrap break-words text-neutral-900">{reason.trim()}</dd></div>
        </dl>
        <p className="mt-3 text-sm text-neutral-700">It posts immediately and counts in the next settlement. Posted adjustments cannot be edited or deleted; a mistake is corrected with a reversal.</p>
        <div className="mt-6 flex flex-wrap justify-end gap-3">
          <button type="button" disabled={busy} onClick={() => setReviewing(false)} className="btn-secondary">Back</button>
          <button type="button" disabled={busy} onClick={post} className="btn-primary">{busy ? 'Posting…' : 'Post adjustment'}</button>
        </div>
      </> : <form noValidate onSubmit={review}>
        <fieldset className="mt-4">
          <legend className="text-sm font-medium text-neutral-900">Type</legend>
          <div className="mt-2 grid gap-2 sm:grid-cols-2">
            {Object.entries(ADJUSTMENT_KINDS).map(([value, entry]) => (
              <label key={value} className={`flex cursor-pointer gap-3 rounded-lg border p-3 ${kind === value ? 'border-brand-600 bg-brand-50' : 'border-neutral-200'}`}>
                <input type="radio" name="kind" value={value} checked={kind === value} onChange={() => setKind(value)} className="mt-1 h-4 w-4 accent-brand-700" />
                <span><span className="block text-sm font-medium text-neutral-900">{entry.label}</span><span className="block text-xs text-content-muted">{entry.body}</span></span>
              </label>
            ))}
          </div>
        </fieldset>
        <label className="mt-4 block text-sm font-medium text-neutral-900">
          Amount ($)
          <input type="number" inputMode="decimal" min="0.01" step="0.01" value={amount} onChange={event => setAmount(event.target.value)} aria-invalid={!!errors.amount} aria-describedby={errors.amount ? 'adjustment-amount-error' : undefined} className={`input mt-1 ${errors.amount ? 'input-error' : ''}`} />
        </label>
        {errors.amount && <p id="adjustment-amount-error" className="mt-1 text-sm text-red-700">{errors.amount}</p>}
        <label className="mt-4 block text-sm font-medium text-neutral-900">
          Reason
          <textarea rows={3} value={reason} onChange={event => setReason(event.target.value)} maxLength={1000} aria-invalid={!!errors.reason} aria-describedby={errors.reason ? 'adjustment-reason-error' : undefined} className={`input mt-1 ${errors.reason ? 'input-error' : ''}`} />
        </label>
        {errors.reason && <p id="adjustment-reason-error" className="mt-1 text-sm text-red-700">{errors.reason}</p>}
        <div className="mt-6 flex flex-wrap justify-end gap-3">
          <button type="button" onClick={onClose} className="btn-secondary">Cancel</button>
          <button type="submit" className="btn-primary">Review adjustment</button>
        </div>
      </form>}
    </Dialog>
  )
}

function ReverseDialog({ adjustment, beginRequest, onClose, onSaved }) {
  const titleId = useId()
  const [reason, setReason] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const submit = async event => {
    event.preventDefault()
    if (!reason.trim()) { setError('Explain why this adjustment is being reversed.'); return }
    const request = beginRequest()
    if (!request) return
    setBusy(true)
    try {
      await apiClient.delete(`/admin/balance_adjustments/${adjustment.id}`, { ...request.config, data: { reason: reason.trim() } })
      if (request.current()) onSaved(`Adjustment #${adjustment.id} reversed.`)
    } catch (failure) {
      if (request.handleError(failure) || !request.current()) return
      setError(errorMessage(failure, 'The reversal was not posted. Check your connection and try again.'))
    } finally { request.release(); setBusy(false) }
  }
  return (
    <Dialog labelledBy={titleId} busy={busy} onClose={onClose} className="max-w-lg">
      <form noValidate onSubmit={submit}>
        <h2 id={titleId} className="text-lg font-semibold text-neutral-900">Reverse adjustment #{adjustment.id}?</h2>
        <p className="mt-2 text-sm text-neutral-700">This posts an equal and opposite entry of {money(-adjustment.amount_cents, adjustment.currency)}. The original stays on record, marked reversed.</p>
        <label className="mt-4 block text-sm font-medium text-neutral-900">
          Reason
          <textarea rows={3} value={reason} onChange={event => { setReason(event.target.value); setError('') }} maxLength={1000} aria-invalid={!!error} aria-describedby={error ? 'reverse-error' : undefined} className={`input mt-1 ${error ? 'input-error' : ''}`} />
        </label>
        {error && <p id="reverse-error" role="alert" className="mt-1 text-sm text-red-700">{error}</p>}
        <div className="mt-6 flex flex-wrap justify-end gap-3">
          <button type="button" disabled={busy} onClick={onClose} className="btn-secondary">Cancel</button>
          <button type="submit" disabled={busy} className="btn-danger">{busy ? 'Reversing…' : 'Post reversal'}</button>
        </div>
      </form>
    </Dialog>
  )
}

function ListState({ list, empty, children }) {
  if (list.loading && !list.data) return <div className="flex justify-center py-12"><Loader2 aria-label="Loading" className="h-6 w-6 animate-spin text-brand-500" /></div>
  if (list.error && !list.data) return <div role="alert" className="p-5 text-sm text-red-700">{list.error} <button type="button" onClick={list.reload} className="min-h-11 rounded px-2 font-semibold underline focus-visible:ring-2 focus-visible:ring-focus">Try again</button></div>
  if (empty) return <div className="px-5 py-10 text-center"><p className="font-medium text-neutral-900">{empty.title}</p><p className="mt-1 text-sm text-content-muted">{empty.body}</p></div>
  return children
}

function PayoutsList({ identity, resourcePath, filters, setFilter, onNotice }) {
  const list = useAdminList(identity, resourcePath, '/admin/payouts', compactParams({
    status: filters.status, q: filters.q, event_id: filters.event_id, organization_id: filters.organization_id, page: filters.page || 1,
  }))
  const [reconciling, setReconciling] = useState(null)
  const [releasing, setReleasing] = useState(null)
  const payouts = list.data?.payouts || []
  const counts = list.data?.status_counts || {}
  const filtered = filters.status || filters.q
  return <>
    <div className="mb-4 flex flex-wrap gap-2" role="group" aria-label="Filter payouts by status">
      {['', ...PAYOUT_STATUSES].map(status => (
        <button key={status || 'all'} type="button" aria-pressed={filters.status === status} onClick={() => setFilter({ status, page: '' })}
          className={`min-h-11 rounded-full px-4 text-sm font-medium ring-1 transition-[background-color,transform] duration-150 ease-out-strong active:scale-[0.97] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus ${filters.status === status ? 'bg-neutral-900 text-white ring-neutral-900' : 'bg-white text-neutral-700 ring-neutral-200 hover:bg-neutral-50'}`}>
          {status ? adminLabel(status) : 'All'}{status && list.data ? ` (${counts[status] || 0})` : ''}
        </button>
      ))}
    </div>
    <OperationalSearch label="Find a payout" hint="Search by organization, event or transfer ID." query={filters.q} onSearch={q => setFilter({ q, page: '' })} busy={list.loading} />
    {list.error && list.data && <p role="alert" className="mb-3 text-sm text-red-700">{list.error} <button type="button" onClick={list.reload} className="min-h-11 font-semibold underline">Try again</button></p>}
    <div className="card overflow-hidden" aria-busy={list.loading}>
      <ListState list={list} empty={list.data && !payouts.length && (filtered
        ? { title: 'No payouts match these filters.', body: 'Clear the search or choose another status.' }
        : { title: 'No payouts yet.', body: 'Payouts appear here after an organizer requests one from a finalized settlement.' })}>
        <table className={foldTable}>
          <thead><tr className="border-b border-neutral-100 text-left text-content-muted">
            <th className="px-3 py-3 font-medium">Payout</th><th className="px-3 py-3 font-medium">Organization and event</th>
            <th className="px-3 py-3 text-right font-medium">Amount</th><th className="px-3 py-3 font-medium">Status</th>
            <th className="px-3 py-3 font-medium">Transfer and evidence</th><th className="px-3 py-3 font-medium"><span className="sr-only">Actions</span></th>
          </tr></thead>
          <tbody>
            {payouts.map(payout => (
              <tr key={payout.id} className={foldRow}>
                <td data-label="Payout" className={foldCell}><span><span className="font-mono text-xs text-neutral-900">#{payout.id}</span><span className="block text-xs text-content-muted">{formatDate(payout.created_at)}</span></span></td>
                <td data-label="For" className={foldCell}><span className="min-w-0"><span className="block font-medium text-neutral-900 [overflow-wrap:anywhere]">{payout.organization.name}</span><span className="block text-xs text-content-muted [overflow-wrap:anywhere]">{payout.event.title} · settlement v{payout.settlement.version}</span></span></td>
                <td data-label="Amount" className={`${foldCell} md:text-right`}><span className="font-semibold text-neutral-900">{money(payout.amount_cents, payout.currency)}</span></td>
                <td data-label="Status" className={foldCell}><span><Badge status={payout.status} />{payout.paid_at && <span className="block text-xs text-content-muted">Paid {formatDate(payout.paid_at)}</span>}{payout.outstanding_buyer_balance_cents > 0 ? <span className="block text-xs font-semibold text-red-700">{money(payout.outstanding_buyer_balance_cents, payout.currency)} still owed to buyers</span> : payout.cancellation_refunds_unresolved && <span className="block text-xs font-semibold text-amber-800">Buyer refunds pending</span>}{payout.status === 'paid' && (payout.outstanding_buyer_balance_cents > 0 || payout.cancellation_refunds_unresolved) && <span className="block text-xs font-semibold text-red-700">Organizer was already paid; recover from organizer</span>}</span></td>
                <td data-label="Transfer" className={foldCell}><span className="min-w-0 text-xs text-neutral-700">
                  <span className="block font-mono [overflow-wrap:anywhere]">{payout.provider_payout_id || 'No transfer ID yet'}</span>
                  {payout.failure_message && <span className="block text-red-700">{payout.failure_message}</span>}
                  {payout.status === 'held' && payout.amount_cents > payout.hold_available_cents && <span className="block text-red-700">Amount exceeds current net payable; record a failed outcome and reissue.</span>}
                  {payout.last_reconciliation && <span className="block text-content-muted [overflow-wrap:anywhere]">Recorded by {payout.last_reconciliation.recorded_by || 'system'} · {payout.last_reconciliation.reference}</span>}
                </span></td>
                <td className={`${foldCell} before:content-none md:text-right`}>
                  {payout.status === 'held' && <button type="button" onClick={() => setReleasing(payout)} className="btn-secondary !px-4 !py-2 text-sm">Release hold<span className="sr-only"> for payout #{payout.id}</span></button>}
                  {payout.allowed_outcomes.length > 0
                    ? <button type="button" onClick={() => setReconciling(payout)} className="btn-secondary !px-4 !py-2 text-sm">Record outcome<span className="sr-only"> for payout #{payout.id}</span></button>
                    : <span className="text-xs text-content-muted">Final</span>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </ListState>
    </div>
    <OperationalPagination meta={list.data?.meta} page={Number(filters.page) || 1} onPage={page => setFilter({ page: String(page) })} busy={list.loading} label="Payout pages" />
    {reconciling && <ReconcileDialog payout={reconciling} beginRequest={list.beginRequest} onClose={() => setReconciling(null)}
      onSaved={message => { setReconciling(null); onNotice(message); list.reload() }} />}
    {releasing && <ReleaseHoldDialog payout={releasing} beginRequest={list.beginRequest} onClose={() => setReleasing(null)}
      onSaved={message => { setReleasing(null); onNotice(message); list.reload() }} />}
  </>
}

function AdjustmentsList({ identity, resourcePath, filters, setFilter, context, onNotice }) {
  const list = useAdminList(identity, resourcePath, '/admin/balance_adjustments', compactParams({
    kind: filters.kind, event_id: filters.event_id, organization_id: filters.organization_id, page: filters.page || 1,
  }))
  const [creating, setCreating] = useState(false)
  const [reversing, setReversing] = useState(null)
  const adjustments = list.data?.balance_adjustments || []
  const done = message => { setCreating(false); setReversing(null); onNotice(message); list.reload() }
  return <>
    <div className="mb-4 flex flex-wrap items-end justify-between gap-3">
      <label className="text-sm font-medium text-neutral-900">
        Type
        <select value={filters.kind} onChange={event => setFilter({ kind: event.target.value, page: '' })} className="input mt-1 !w-auto !py-2">
          <option value="">All types</option>
          {Object.entries(ADJUSTMENT_LABELS).map(([kind, label]) => <option key={kind} value={kind}>{label}</option>)}
        </select>
      </label>
      {context?.organization
        ? <button type="button" onClick={() => setCreating(true)} className="btn-primary">New adjustment</button>
        : <p className="max-w-sm text-sm text-content-muted">To post an adjustment, open payouts from an event on the Events screen.</p>}
    </div>
    <div className="card overflow-hidden" aria-busy={list.loading}>
      <ListState list={list} empty={list.data && !adjustments.length && { title: 'No balance adjustments.', body: 'Credits, debits and reserves posted by administrators appear here.' }}>
        <table className={foldTable}>
          <thead><tr className="border-b border-neutral-100 text-left text-content-muted">
            <th className="px-3 py-3 font-medium">Posted</th><th className="px-3 py-3 font-medium">For</th><th className="px-3 py-3 font-medium">Type</th>
            <th className="px-3 py-3 text-right font-medium">Amount</th><th className="px-3 py-3 font-medium">Reason</th><th className="px-3 py-3 font-medium"><span className="sr-only">Actions</span></th>
          </tr></thead>
          <tbody>
            {adjustments.map(adjustment => (
              <tr key={adjustment.id} className={foldRow}>
                <td data-label="Posted" className={foldCell}><span><span className="font-mono text-xs">#{adjustment.id}</span><span className="block text-xs text-content-muted">{formatDate(adjustment.created_at)}</span><span className="block text-xs text-content-muted [overflow-wrap:anywhere]">{adjustment.created_by || 'System'}</span></span></td>
                <td data-label="For" className={foldCell}><span className="min-w-0"><span className="block font-medium text-neutral-900 [overflow-wrap:anywhere]">{adjustment.organization.name}</span><span className="block text-xs text-content-muted [overflow-wrap:anywhere]">{adjustment.event?.title || 'Organization balance'}</span></span></td>
                <td data-label="Type" className={foldCell}><span><span className="block text-neutral-900">{ADJUSTMENT_LABELS[adjustment.kind] || adminLabel(adjustment.kind)}</span><Badge status={adjustment.status} />{adjustment.reversal_of_id && <span className="block text-xs text-content-muted">Reverses #{adjustment.reversal_of_id}</span>}</span></td>
                <td data-label="Amount" className={`${foldCell} md:text-right`}><span className={`font-semibold ${adjustment.amount_cents < 0 ? 'text-red-800' : 'text-emerald-800'}`}>{adjustment.amount_cents > 0 ? '+' : '−'}{money(Math.abs(adjustment.amount_cents), adjustment.currency)}</span></td>
                <td data-label="Reason" className={foldCell}><span className="min-w-0 whitespace-pre-wrap text-neutral-700 [overflow-wrap:anywhere]">{adjustment.reason}</span></td>
                <td className={`${foldCell} before:content-none md:text-right`}>
                  {adjustment.status === 'posted' && !adjustment.reversal_of_id && <button type="button" onClick={() => setReversing(adjustment)} className="btn-ghost !px-3 !py-2 text-sm">Reverse<span className="sr-only"> adjustment #{adjustment.id}</span></button>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </ListState>
    </div>
    <OperationalPagination meta={list.data?.meta} page={Number(filters.page) || 1} onPage={page => setFilter({ page: String(page) })} busy={list.loading} label="Adjustment pages" />
    {creating && <AdjustmentDialog context={context} beginRequest={list.beginRequest} onClose={() => setCreating(false)} onSaved={done} />}
    {reversing && <ReverseDialog adjustment={reversing} beginRequest={list.beginRequest} onClose={() => setReversing(null)} onSaved={done} />}
  </>
}

const FILTERS = ['view', 'status', 'q', 'kind', 'event_id', 'organization_id', 'page']

function AdminPayoutsSession({ identity, resourcePath }) {
  const [searchParams, setSearchParams] = useSearchParams()
  const filters = readFilters(searchParams, FILTERS)
  const [notice, setNotice] = useState('')
  const view = filters.view === 'adjustments' ? 'adjustments' : 'payouts'
  const setFilter = changes => {
    setNotice('')
    setSearchParams(compactParams({ ...filters, ...changes }), { replace: true })
  }
  // The payouts read also names the event or organization context.
  const scoped = Boolean(filters.event_id || filters.organization_id)
  const contextList = useAdminList(identity, resourcePath, '/admin/payouts', compactParams({ event_id: filters.event_id, organization_id: filters.organization_id, per_page: 1 }), { enabled: scoped })
  const context = scoped ? contextList.data?.context : null
  const tabClass = active => `inline-flex min-h-11 items-center border-b-2 px-4 text-sm font-semibold transition-colors ${active ? 'border-brand-700 text-brand-800' : 'border-transparent text-content-muted hover:text-neutral-900'}`
  const contextQuery = compactParams({ event_id: filters.event_id, organization_id: filters.organization_id })
  const tabLink = target => `?${new URLSearchParams(target === 'adjustments' ? { ...contextQuery, view: 'adjustments' } : contextQuery)}`

  return (
    <AdminLayout>
      {context && <div className="mb-5 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-brand-200 bg-brand-50 px-4 py-3 text-sm text-brand-900">
        <p className="min-w-0 [overflow-wrap:anywhere]">Showing <strong>{context.event ? context.event.title : context.organization.name}</strong>{context.event && <> · {context.organization.name}</>}</p>
        <Link to={view === 'adjustments' ? '?view=adjustments' : '?'} className="min-h-11 content-center font-semibold underline underline-offset-2">Show all organizations</Link>
      </div>}
      <nav aria-label="Payout records" className="mb-5 flex gap-2 border-b border-neutral-200">
        <Link to={tabLink('payouts')} aria-current={view === 'payouts' ? 'page' : undefined} className={tabClass(view === 'payouts')}>Payouts</Link>
        <Link to={tabLink('adjustments')} aria-current={view === 'adjustments' ? 'page' : undefined} className={tabClass(view === 'adjustments')}>Balance adjustments</Link>
      </nav>
      {notice && <p role="status" className="mb-4 rounded-xl border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-900">{notice}</p>}
      {view === 'payouts'
        ? <PayoutsList key={`payouts:${contextQuery.event_id || ''}:${contextQuery.organization_id || ''}`} identity={identity} resourcePath={resourcePath} filters={filters} setFilter={setFilter} onNotice={setNotice} />
        : <AdjustmentsList key={`adjustments:${contextQuery.event_id || ''}:${contextQuery.organization_id || ''}`} identity={identity} resourcePath={resourcePath} filters={filters} setFilter={setFilter} context={context} onNotice={setNotice} />}
    </AdminLayout>
  )
}

export default function AdminPayoutsPage() {
  return <AdminSessionGate resourcePath="/admin/payouts" Session={AdminPayoutsSession} />
}
