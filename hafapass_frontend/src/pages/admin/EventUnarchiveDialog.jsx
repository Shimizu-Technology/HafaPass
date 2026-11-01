import { useId, useState } from 'react'
import apiClient from '../../api/client'
import Dialog from '../../components/Dialog'
import { errorMessage } from './adminOperations'

// Returns an archived event to the status it was archived from, so a statement
// that was never finalized can be finalized and paid. Recorded in the audit log.
export default function EventUnarchiveDialog({ event, beginRequest, onClose, onSaved }) {
  const titleId = useId()
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const submit = async submitEvent => {
    submitEvent.preventDefault()
    if (!reason.trim()) { setError('Add a reason for the audit record.'); return }
    const request = beginRequest()
    if (!request) return
    setBusy(true)
    setError('')
    try {
      const response = await apiClient.post(`/admin/events/${event.id}/unarchive`, { reason: reason.trim() }, request.config)
      if (request.current()) onSaved(`${event.title} restored to ${String(response.data.status).replaceAll('_', ' ')}.`)
    } catch (failure) {
      if (request.handleError(failure) || !request.current()) return
      setError(errorMessage(failure, 'Nothing changed. Check your connection and try again.'))
    } finally { request.release(); setBusy(false) }
  }

  return <Dialog labelledBy={titleId} busy={busy} onClose={onClose} className="max-w-lg">
    <form noValidate onSubmit={submit}>
      <h2 id={titleId} className="text-lg font-semibold text-neutral-900 [overflow-wrap:anywhere]">Restore {event.title}?</h2>
      <p className="mt-3 text-sm text-neutral-700">The event goes back to the status it had before it was archived (draft, completed or cancelled). The organizer can then finalize its statement and request what is still owed.</p>
      <label className="mt-4 block text-sm font-medium text-neutral-900">
        Reason <span className="text-red-700">*</span>
        <textarea rows={3} value={reason} maxLength={1000} onChange={changeEvent => setReason(changeEvent.target.value)} className="input mt-1" />
      </label>
      {error && <p role="alert" className="mt-3 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">{error}</p>}
      <p className="mt-3 text-xs text-content-muted">Recorded in the event history and audit log under your name.</p>
      <div className="mt-6 flex flex-wrap justify-end gap-3">
        <button type="button" disabled={busy} onClick={onClose} className="btn-secondary">Cancel</button>
        <button type="submit" disabled={busy} className="btn-primary">{busy ? 'Restoring…' : 'Restore event'}</button>
      </div>
    </form>
  </Dialog>
}
