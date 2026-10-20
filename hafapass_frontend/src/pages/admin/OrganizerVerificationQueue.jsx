import { useId, useState } from 'react'
import apiClient from '../../api/client'
import Dialog from '../../components/Dialog'
import { errorMessage, formatDateTime } from './adminOperations'

const STATUS_COPY = { pending: 'Requested', unverified: 'Not requested yet', rejected: 'Not verified last time' }

// Verify an organizer so its events can sell, or pause all of its sales.
// Both go through the organizer profile update and are recorded in the audit log.
function VerificationDialog({ action, organizer, beginRequest, onClose, onSaved }) {
  const titleId = useId()
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const pausing = action === 'pause'
  const name = organizer.business_name

  const submit = async submitEvent => {
    submitEvent.preventDefault()
    const request = beginRequest()
    if (!request) return
    setBusy(true)
    setError('')
    const body = { verification_status: pausing ? 'suspended' : 'verified', ...(note.trim() ? { verification_notes: note.trim() } : {}) }
    try {
      await apiClient.patch(`/admin/organizer_profiles/${organizer.profile_id}`, body, request.config)
      if (request.current()) onSaved(pausing ? `All sales are paused for ${name}.` : `${name} is verified. Their published events can sell tickets.`)
    } catch (failure) {
      if (request.handleError(failure) || !request.current()) return
      setError(errorMessage(failure, 'Nothing changed. Check your connection and try again.'))
    } finally { request.release(); setBusy(false) }
  }

  return <Dialog labelledBy={titleId} busy={busy} onClose={onClose} className="max-w-lg">
    <form noValidate onSubmit={submit}>
      <h2 id={titleId} className="text-lg font-semibold text-neutral-900 [overflow-wrap:anywhere]">{pausing ? `Pause all sales for ${name}?` : `Verify ${name}?`}</h2>
      {pausing
        ? <p className="mt-2 text-sm text-neutral-700">Their events stay visible but stop selling until you verify them again. Tickets already sold stay valid.</p>
        : <>
          <p className="mt-2 text-sm text-neutral-700">Their published events can sell tickets right away.</p>
          {organizer.payout_ready === false && <p className="mt-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950">They have not added payout details yet. Paid tickets won’t sell until they do; free tickets can.</p>}
        </>}
      <label className="mt-4 block text-sm font-medium text-neutral-900">
        Note (optional, shown to the organizer)
        <textarea rows={3} value={note} maxLength={1000} onChange={changeEvent => setNote(changeEvent.target.value)} className="input mt-1" />
      </label>
      {error && <p role="alert" className="mt-3 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">{error}</p>}
      <p className="mt-3 text-xs text-content-muted">Recorded in the audit log under your name.</p>
      <div className="mt-6 flex flex-wrap justify-end gap-3">
        <button type="button" disabled={busy} onClick={onClose} className="btn-secondary">Cancel</button>
        <button type="submit" disabled={busy} className={pausing ? 'btn-danger' : 'btn-primary'}>{busy ? 'Saving…' : pausing ? 'Pause all sales' : 'Verify'}</button>
      </div>
    </form>
  </Dialog>
}

// Organizers waiting for HåfaPass verification, and those already verified.
// Self-contained so it can move to its own admin page later.
export default function OrganizerVerificationQueue({ awaiting = [], verified = [], beginRequest, onChanged }) {
  const [dialog, setDialog] = useState(null)
  const [notice, setNotice] = useState('')

  const saved = message => {
    setDialog(null)
    setNotice(message)
    onChanged?.()
  }
  const open = (action, organizer) => { setNotice(''); setDialog({ action, organizer }) }

  return <div className="mb-8 grid gap-6 lg:grid-cols-2">
    {notice && <p role="status" className="rounded-xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900 lg:col-span-2">{notice}</p>}
    <section aria-labelledby="awaiting-verification-title" className="card min-w-0 p-5">
      <h2 id="awaiting-verification-title" className="font-semibold text-neutral-900">Organizers waiting for verification</h2>
      <p className="mt-1 text-sm text-content-muted">Their events can be published, but tickets don’t sell until you verify them.</p>
      {awaiting.length === 0
        ? <p className="mt-4 text-sm text-content-muted">No organizers are waiting.</p>
        : <ul className="mt-4 space-y-3">
          {awaiting.map(organizer => <li key={organizer.profile_id} className="flex flex-col gap-3 rounded-xl border border-neutral-200 p-4 sm:flex-row sm:items-start sm:justify-between">
            <div className="min-w-0 text-sm">
              <p className="font-semibold text-neutral-900 [overflow-wrap:anywhere]">{organizer.business_name}</p>
              {organizer.owner_email && <p className="text-neutral-700 [overflow-wrap:anywhere]">Owner: {organizer.owner_email}</p>}
              <p className="text-neutral-700">{organizer.verification_status === 'pending' && organizer.requested_at
                ? `Requested ${formatDateTime(organizer.requested_at)}`
                : STATUS_COPY[organizer.verification_status] || 'Not requested yet'}</p>
              <p className="text-neutral-700">Payout details on file: {organizer.payout_ready ? 'Yes' : 'No'} · {organizer.event_count ?? 0} {organizer.event_count === 1 ? 'event' : 'events'}</p>
            </div>
            <button type="button" onClick={() => open('verify', organizer)} className="btn-primary min-h-11 shrink-0 text-sm">Verify<span className="sr-only"> {organizer.business_name}</span></button>
          </li>)}
        </ul>}
    </section>

    <section aria-labelledby="verified-organizers-title" className="card min-w-0 p-5">
      <h2 id="verified-organizers-title" className="font-semibold text-neutral-900">Verified organizers</h2>
      {verified.length === 0
        ? <p className="mt-4 text-sm text-content-muted">No organizers are verified yet.</p>
        : <ul className="mt-4 divide-y divide-neutral-100">
          {verified.map(organizer => <li key={organizer.profile_id} className="flex flex-col gap-2 py-3 sm:flex-row sm:items-center sm:justify-between">
            <div className="min-w-0 text-sm">
              <p className="font-medium text-neutral-900 [overflow-wrap:anywhere]">{organizer.business_name}</p>
              {organizer.verified_at && <p className="text-content-muted [overflow-wrap:anywhere]">Verified {formatDateTime(organizer.verified_at)}{organizer.verified_by ? ` by ${organizer.verified_by}` : ''}</p>}
            </div>
            <button type="button" onClick={() => open('pause', organizer)} className="btn-secondary min-h-11 shrink-0 text-sm">Pause all sales<span className="sr-only"> for {organizer.business_name}</span></button>
          </li>)}
        </ul>}
    </section>

    {dialog && <VerificationDialog {...dialog} beginRequest={beginRequest} onClose={() => setDialog(null)} onSaved={saved} />}
  </div>
}
