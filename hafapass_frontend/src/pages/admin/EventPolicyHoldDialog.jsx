import { useId, useState } from 'react'
import { Link } from 'react-router-dom'
import apiClient from '../../api/client'
import Dialog from '../../components/Dialog'
import { POLICY_HOLD_SCOPES, errorMessage, formatDateTime } from './adminOperations'

// Places or lifts a platform policy hold. Holds never cancel the event,
// delete anything or refund anyone; existing tickets stay valid for entry.
export default function EventPolicyHoldDialog({ event, beginRequest, onClose, onSaved }) {
  const titleId = useId()
  const hold = event.policy_hold
  const [scope, setScope] = useState('sales')
  const [reason, setReason] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  const submit = async submitEvent => {
    submitEvent.preventDefault()
    if (!reason.trim()) { setError(hold ? 'Explain why sales can resume.' : 'Explain the policy reason. The organizer will see it.'); return }
    const request = beginRequest()
    if (!request) return
    setBusy(true)
    setError('')
    try {
      const path = `/admin/events/${event.id}/policy_hold`
      if (hold) await apiClient.delete(path, { ...request.config, data: { reason: reason.trim() } })
      else await apiClient.post(path, { scope, reason: reason.trim() }, request.config)
      if (request.current()) onSaved(hold ? `${event.title} is restored.` : scope === 'hidden' ? `${event.title} is hidden and its sales are paused.` : `Sales are paused for ${event.title}.`)
    } catch (failure) {
      if (request.handleError(failure) || !request.current()) return
      setError(errorMessage(failure, 'Nothing changed. Check your connection and try again.'))
    } finally { request.release(); setBusy(false) }
  }

  return (
    <Dialog labelledBy={titleId} busy={busy} onClose={onClose} className="max-w-lg">
      <form noValidate onSubmit={submit}>
        <h2 id={titleId} className="text-lg font-semibold text-neutral-900 [overflow-wrap:anywhere]">{hold ? `Restore ${event.title}?` : `Policy hold for ${event.title}`}</h2>
        {hold ? <>
          <div className="mt-3 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-900">
            <p className="font-semibold">{POLICY_HOLD_SCOPES[hold.scope]?.badge}</p>
            <p className="mt-1 whitespace-pre-wrap [overflow-wrap:anywhere]">{hold.reason}</p>
            <p className="mt-1 text-xs">Since {formatDateTime(hold.placed_at)}{hold.placed_by ? ` · ${hold.placed_by}` : ''}</p>
          </div>
          <p className="mt-3 text-sm text-neutral-700">Restoring lets ticket sales resume{hold.scope === 'hidden' ? ' and puts the event page back' : ''}, as long as the event is otherwise on sale.</p>
        </> : <>
          <p className="mt-2 text-sm text-neutral-700">Nothing is deleted, cancelled or refunded. Existing tickets stay valid for entry, and you can restore the event later.</p>
          <fieldset className="mt-4">
            <legend className="text-sm font-medium text-neutral-900">What should happen?</legend>
            <div className="mt-2 space-y-2">
              {Object.entries(POLICY_HOLD_SCOPES).map(([value, option]) => (
                <label key={value} className={`flex cursor-pointer gap-3 rounded-lg border p-3 ${scope === value ? 'border-red-400 bg-red-50' : 'border-neutral-200'}`}>
                  <input type="radio" name="policy-hold-scope" value={value} checked={scope === value} onChange={() => setScope(value)} className="mt-1 h-4 w-4 accent-red-700" />
                  <span><span className="block font-medium text-neutral-900">{option.label}</span><span className="block text-sm text-content-muted">{option.body}</span></span>
                </label>
              ))}
            </div>
          </fieldset>
        </>}
        <label className="mt-4 block text-sm font-medium text-neutral-900">
          {hold ? 'Why can it be restored?' : 'Policy reason (shown to the organizer)'}
          <textarea rows={3} value={reason} maxLength={1000} onChange={changeEvent => { setReason(changeEvent.target.value); setError('') }} aria-invalid={!!error} aria-describedby={error ? `${titleId}-error` : undefined} className={`input mt-1 ${error ? 'input-error' : ''}`} />
        </label>
        {error && <p id={`${titleId}-error`} role="alert" className="mt-1 text-sm text-red-700">{error}</p>}
        <p className="mt-3 text-xs text-content-muted">Recorded in the audit log under your name. <Link to={`/admin/audit-log?target_type=Event&target_id=${event.id}`} className="font-semibold text-brand-700 underline underline-offset-2">View this event’s history</Link></p>
        <div className="mt-6 flex flex-wrap justify-end gap-3">
          <button type="button" disabled={busy} onClick={onClose} className="btn-secondary">Cancel</button>
          <button type="submit" disabled={busy} className={hold ? 'btn-primary' : 'btn-danger'}>{busy ? 'Saving…' : hold ? 'Restore event' : POLICY_HOLD_SCOPES[scope].label}</button>
        </div>
      </form>
    </Dialog>
  )
}
