import { useId, useState } from 'react'
import apiClient from '../../api/client'
import Dialog from '../../components/Dialog'
import { errorMessage } from './adminOperations'

// Lifts a HåfaPass sales suspension so the event can sell again (as long as
// nothing else holds it back). Recorded in the audit log.
export default function EventSalesSuspensionDialog({ event, beginRequest, onClose, onSaved }) {
  const titleId = useId()
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const submit = async submitEvent => {
    submitEvent.preventDefault()
    const request = beginRequest()
    if (!request) return
    setBusy(true)
    setError('')
    try {
      await apiClient.delete(`/admin/events/${event.id}/sales_suspension`, { ...request.config, data: note.trim() ? { note: note.trim() } : {} })
      if (request.current()) onSaved(`Sales resumed for ${event.title}.`)
    } catch (failure) {
      if (request.handleError(failure) || !request.current()) return
      setError(errorMessage(failure, 'Nothing changed. Check your connection and try again.'))
    } finally { request.release(); setBusy(false) }
  }

  return <Dialog labelledBy={titleId} busy={busy} onClose={onClose} className="max-w-lg">
    <form noValidate onSubmit={submit}>
      <h2 id={titleId} className="text-lg font-semibold text-neutral-900 [overflow-wrap:anywhere]">Resume sales for {event.title}?</h2>
      {event.sales_suspension_reason && <div className="mt-3 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-900">
        <p className="font-semibold">Why sales were paused</p>
        <p className="mt-1 whitespace-pre-wrap [overflow-wrap:anywhere]">{event.sales_suspension_reason}</p>
      </div>}
      <p className="mt-3 text-sm text-neutral-700">Ticket sales start again right away, as long as nothing else holds them back.</p>
      <label className="mt-4 block text-sm font-medium text-neutral-900">
        Note (optional)
        <textarea rows={3} value={note} maxLength={1000} onChange={changeEvent => setNote(changeEvent.target.value)} className="input mt-1" />
      </label>
      {error && <p role="alert" className="mt-3 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">{error}</p>}
      <p className="mt-3 text-xs text-content-muted">Recorded in the audit log under your name.</p>
      <div className="mt-6 flex flex-wrap justify-end gap-3">
        <button type="button" disabled={busy} onClick={onClose} className="btn-secondary">Cancel</button>
        <button type="submit" disabled={busy} className="btn-primary">{busy ? 'Saving…' : 'Resume sales'}</button>
      </div>
    </form>
  </Dialog>
}
