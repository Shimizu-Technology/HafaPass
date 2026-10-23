import { useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import apiClient from '../../api/client'
import Dialog from '../../components/Dialog'
import { errorMessage } from './adminOperations'
import { formatEventDate } from '../../utils/eventTime'

const STATUS_COPY = { pending: 'Requested', unverified: 'Not requested yet', rejected: 'Not verified last time' }

// Verify an organizer so its events can sell, or pause all of its sales.
// Both go through the organizer profile update and are recorded in the audit log.
function VerificationDialog({ action, organizer, beginRequest, onClose, onSaved }) {
  const { t } = useTranslation()
  const titleId = useId()
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const pausing = action === 'pause'
  const rejecting = action === 'reject'
  const resuming = action === 'resume'
  const name = organizer.business_name

  const submit = async submitEvent => {
    submitEvent.preventDefault()
    if (rejecting && !note.trim()) { setError(t('adminVerification.noteRequired')); return }
    const request = beginRequest()
    if (!request) return
    setBusy(true)
    setError('')
    const body = { verification_status: rejecting ? 'rejected' : pausing ? 'suspended' : 'verified',
      ...(organizer.verification_status === 'pending' && Number.isInteger(organizer.verification_request_version)
        ? { verification_request_version: organizer.verification_request_version } : {}),
      ...(note.trim() ? { verification_notes: note.trim() } : {}) }
    try {
      await apiClient.patch(`/admin/organizer_profiles/${organizer.profile_id}`, body, request.config)
      if (request.current()) onSaved(rejecting ? t('adminVerification.rejectedSaved', { name }) : pausing ? t('adminVerification.suspendedSaved', { name }) : resuming ? t('adminVerification.restoredSaved', { name }) : t('adminVerification.verifiedSaved', { name }))
    } catch (failure) {
      if (request.handleError(failure) || !request.current()) return
      setError(errorMessage(failure, 'Nothing changed. Check your connection and try again.'))
    } finally { request.release(); setBusy(false) }
  }

  return <Dialog labelledBy={titleId} busy={busy} onClose={onClose} className="max-w-lg">
    <form noValidate onSubmit={submit}>
      <h2 id={titleId} className="text-lg font-semibold text-neutral-900 [overflow-wrap:anywhere]">{rejecting ? `Reject ${name}'s request?` : pausing ? `Suspend ${name}?` : resuming ? `Restore ${name}?` : `Verify ${name}?`}</h2>
      {pausing
        ? <p className="mt-2 text-sm text-neutral-700">{t('adminVerification.suspendExplanation')}</p>
        : rejecting ? <p className="mt-2 text-sm text-neutral-700">{t('adminVerification.rejectExplanation')}</p>
        : <>
          <p className="mt-2 text-sm text-neutral-700">{t('adminVerification.verifyExplanation')}</p>
          {organizer.payout_ready === false && <p className="mt-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950">{t('adminVerification.payoutExplanation')}</p>}
        </>}
      <label className="mt-4 block text-sm font-medium text-neutral-900">
        Note {rejecting ? '(required)' : '(optional)'} — shown to the organizer
        <textarea rows={3} value={note} maxLength={1000} onChange={changeEvent => setNote(changeEvent.target.value)} className="input mt-1" />
      </label>
      {error && <p role="alert" className="mt-3 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">{error}</p>}
      <p className="mt-3 text-xs text-content-muted">Recorded in the audit log under your name.</p>
      <div className="mt-6 flex flex-wrap justify-end gap-3">
        <button type="button" disabled={busy} onClick={onClose} className="btn-secondary">Cancel</button>
        <button type="submit" disabled={busy} className={pausing || rejecting ? 'btn-danger' : 'btn-primary'}>{busy ? 'Saving…' : rejecting ? 'Reject request' : pausing ? 'Suspend' : resuming ? 'Restore' : 'Verify'}</button>
      </div>
    </form>
  </Dialog>
}

function Description({ value }) {
  const [expanded, setExpanded] = useState(false)
  if (!value) return null
  const long = value.length > 240
  return <div className="mt-2 text-neutral-700">
    <p className="font-medium">Business description</p>
    <p className="whitespace-pre-wrap [overflow-wrap:anywhere]">{long && !expanded ? `${value.slice(0, 240)}…` : value}</p>
    {long && <button type="button" onClick={() => setExpanded(!expanded)} className="min-h-11 font-semibold text-brand-700 underline">{expanded ? 'Show less' : 'Show more'}</button>}
  </div>
}

// Organizers waiting for HåfaPass verification, and those already verified.
// Self-contained so it can move to its own admin page later.
export default function OrganizerVerificationQueue({ awaiting = [], verified = [], suspended = [], beginRequest, onChanged }) {
  const { t } = useTranslation()
  const [dialog, setDialog] = useState(null)
  const [notice, setNotice] = useState('')

  const saved = message => {
    setDialog(null)
    setNotice(message)
    onChanged?.()
  }
  const open = (action, organizer) => { setNotice(''); setDialog({ action, organizer }) }

  const requested = awaiting.filter(organizer => organizer.requested_at)
    .sort((a, b) => new Date(b.requested_at || 0) - new Date(a.requested_at || 0))
  const notRequested = awaiting.filter(organizer => !organizer.requested_at)
  const renderRows = organizers => organizers.map(organizer => <li key={organizer.profile_id} className="flex flex-col gap-3 rounded-xl border border-neutral-200 p-4 sm:flex-row sm:items-start sm:justify-between">
    <div className="min-w-0 text-sm">
      <p className="font-semibold text-neutral-900 [overflow-wrap:anywhere]">{organizer.business_name}</p>
      {organizer.owner_email && <p className="text-neutral-700 [overflow-wrap:anywhere]">Owner: {organizer.owner_email}</p>}
      <p className="text-neutral-700">{organizer.requested_at ? `Requested ${formatEventDate(organizer.requested_at)}` : STATUS_COPY[organizer.verification_status] || 'Not requested yet'}</p>
      {Object.keys(organizer.verification_change_diff || {}).length > 0 && <div className="mt-2 rounded-lg border border-amber-200 bg-amber-50 p-2 text-amber-950">
        <p className="font-semibold">Updated after submission — review again</p>
        <ul className="mt-1 list-disc space-y-1 pl-4">{Object.entries(organizer.verification_change_diff).map(([field, change]) => <li key={field} className="[overflow-wrap:anywhere]">{field.replaceAll('_', ' ')}: {change.before || 'Not provided'} → {change.after || 'Not provided'}</li>)}</ul>
      </div>}
      <Description value={organizer.business_description} />
      <p className="text-neutral-700">{t('adminVerification.phone', { phone: organizer.verification_phone || t('adminVerification.notProvided') })}</p>
      {organizer.verification_link && <p className="text-neutral-700">{t('adminVerification.websiteLink')}: <a href={organizer.verification_link} target="_blank" rel="noreferrer" className="underline [overflow-wrap:anywhere]">{organizer.verification_link.replace(/^https?:\/\//, '')}</a></p>}
      {organizer.verification_request_note && <p className="whitespace-pre-wrap text-neutral-700">{t('adminVerification.reviewerNote', { note: organizer.verification_request_note })}</p>}
      <p className="text-neutral-700">{t('adminVerification.awaitingCount', { number: organizer.published_awaiting_events_count ?? 0, payout: organizer.payout_ready ? 'Ready' : 'Not ready' })}</p>
    </div>
    <div className="flex flex-wrap gap-2"><button type="button" onClick={() => open('verify', organizer)} className="btn-primary min-h-11 shrink-0 text-sm">Verify<span className="sr-only"> {organizer.business_name}</span></button>
      <button type="button" onClick={() => open('reject', organizer)} className="btn-secondary min-h-11 shrink-0 text-sm">Reject<span className="sr-only"> {organizer.business_name}</span></button></div>
  </li>)

  return <div className="mb-8 grid gap-6 lg:grid-cols-2">
    {notice && <p role="status" className="rounded-xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900 lg:col-span-2">{notice}</p>}
    <section aria-labelledby="awaiting-verification-title" className="card min-w-0 p-5">
      <h2 id="awaiting-verification-title" className="font-semibold text-neutral-900">Requested (newest first) ({requested.length})</h2>
      <p className="mt-1 text-sm text-content-muted">{t('adminVerification.queueExplanation')}</p>
      {requested.length === 0 ? <p className="mt-4 text-sm text-content-muted">No requests yet.</p> : <ul className="mt-4 space-y-3">{renderRows(requested)}</ul>}
      <details className="mt-5 border-t border-neutral-200 pt-4"><summary className="min-h-11 cursor-pointer font-semibold text-neutral-900">Not requested yet ({notRequested.length})</summary>
        {notRequested.length === 0 ? <p className="mt-2 text-sm text-content-muted">None.</p> : <ul className="mt-3 space-y-3">{renderRows(notRequested)}</ul>}
      </details>
    </section>

    <section aria-labelledby="verified-organizers-title" className="card min-w-0 p-5">
      <h2 id="verified-organizers-title" className="font-semibold text-neutral-900">Verified organizers</h2>
      {verified.length === 0
        ? <p className="mt-4 text-sm text-content-muted">No organizers are verified yet.</p>
        : <ul className="mt-4 divide-y divide-neutral-100">
          {verified.map(organizer => <li key={organizer.profile_id} className="flex flex-col gap-2 py-3 sm:flex-row sm:items-center sm:justify-between">
            <div className="min-w-0 text-sm">
              <p className="font-medium text-neutral-900 [overflow-wrap:anywhere]">{organizer.business_name}</p>
              {organizer.verified_at && <p className="text-content-muted [overflow-wrap:anywhere]">Verified {formatEventDate(organizer.verified_at)}{organizer.verified_by ? ` by ${organizer.verified_by}` : ''}</p>}
            </div>
            <button type="button" onClick={() => open('pause', organizer)} className="btn-secondary min-h-11 shrink-0 text-sm">Suspend<span className="sr-only"> {organizer.business_name}</span></button>
          </li>)}
        </ul>}
    </section>

    {suspended.length > 0 && <section aria-labelledby="suspended-organizers-title" className="card min-w-0 p-5 lg:col-span-2">
      <h2 id="suspended-organizers-title" className="font-semibold text-neutral-900">Suspended organizers</h2>
      <p className="mt-1 text-sm text-content-muted">{t('adminVerification.suspendedExplanation')}</p>
      <ul className="mt-4 divide-y divide-neutral-100">
        {suspended.map(organizer => <li key={organizer.profile_id} className="flex flex-col gap-2 py-3 sm:flex-row sm:items-start sm:justify-between">
          <div className="min-w-0 text-sm">
            <p className="font-medium text-neutral-900 [overflow-wrap:anywhere]">{organizer.business_name}</p>
            {organizer.owner_email && <p className="text-neutral-700 [overflow-wrap:anywhere]">Owner: {organizer.owner_email}</p>}
            {organizer.suspended_at && <p className="text-content-muted">Paused {formatEventDate(organizer.suspended_at)}</p>}
            {organizer.verification_notes && <p className="mt-1 whitespace-pre-wrap text-neutral-700 [overflow-wrap:anywhere]">{organizer.verification_notes}</p>}
          </div>
          <button type="button" onClick={() => open('resume', organizer)} className="btn-primary min-h-11 shrink-0 text-sm">Restore<span className="sr-only"> {organizer.business_name}</span></button>
        </li>)}
      </ul>
    </section>}

    {dialog && <VerificationDialog {...dialog} beginRequest={beginRequest} onClose={() => setDialog(null)} onSaved={saved} />}
  </div>
}
