import { useId, useState } from 'react'
import { ShieldAlert } from 'lucide-react'

export default function ReEntryLeadOverride({ ticket, busy = false, onSubmit, defaultAction = 'admit', compact = false }) {
  const [open, setOpen] = useState(false)
  const [overrideAction, setOverrideAction] = useState(defaultAction)
  const [reason, setReason] = useState('')
  const [localError, setLocalError] = useState('')
  const fieldId = useId()

  if (!ticket?.ticket_id && !ticket?.id) return null
  const ticketId = ticket.ticket_id || ticket.id

  const handleSubmit = async event => {
    event.preventDefault()
    const trimmed = reason.trim()
    if (trimmed.length < 3) {
      setLocalError('Enter a short reason (at least 3 characters) for the audit log.')
      return
    }
    setLocalError('')
    const ok = await onSubmit({ ticketId, overrideAction, reason: trimmed })
    if (ok) {
      setReason('')
      setOpen(false)
    }
  }

  if (!open) {
    return (
      <button
        type="button"
        onClick={() => setOpen(true)}
        className={`inline-flex min-h-11 items-center gap-1.5 rounded-lg border border-amber-700 bg-white px-3 py-2 text-sm font-semibold text-amber-950 hover:bg-amber-100 ${compact ? 'mt-2' : 'mt-3'}`}
      >
        <ShieldAlert aria-hidden="true" className="h-4 w-4 shrink-0" />
        Lead override
      </button>
    )
  }

  return (
    <form onSubmit={handleSubmit} className="mt-3 space-y-3 rounded-xl border border-amber-400 bg-white p-3 text-left text-neutral-950">
      <div className="flex items-center justify-between gap-2">
        <p className="text-sm font-bold text-neutral-950">Scanner lead override (audited)</p>
        <button type="button" onClick={() => setOpen(false)} className="min-h-11 shrink-0 whitespace-nowrap px-2 text-xs font-semibold text-neutral-700 underline">
          Cancel
        </button>
      </div>
      <div className="grid grid-cols-2 gap-2" role="radiogroup" aria-label="Override action">
        {[
          ['admit', 'Admit guest'],
          ['clear', 'Clear inside status'],
        ].map(([value, label]) => (
          <label
            key={value}
            className={`flex min-h-11 cursor-pointer items-center justify-center gap-2 rounded-lg border-2 px-2 py-2 text-center text-xs font-bold ${
              overrideAction === value ? 'border-brand-800 bg-brand-50 text-brand-950' : 'border-neutral-300 bg-neutral-50 text-neutral-800'
            }`}
          >
            <input
              type="radio"
              name={`${fieldId}-action`}
              value={value}
              checked={overrideAction === value}
              onChange={() => setOverrideAction(value)}
              className="sr-only"
            />
            {label}
          </label>
        ))}
      </div>
      <div>
        <label htmlFor={`${fieldId}-reason`} className="mb-1 block text-xs font-semibold text-neutral-800">
          Reason for override <span className="text-red-600">*</span>
        </label>
        <input
          id={`${fieldId}-reason`}
          type="text"
          maxLength={500}
          value={reason}
          onChange={event => { setReason(event.target.value); setLocalError('') }}
          placeholder="e.g., Verified wristband at North Gate"
          className="input min-h-11 w-full text-sm"
          disabled={busy}
        />
        {localError && <p role="alert" className="mt-1 text-xs text-red-700">{localError}</p>}
      </div>
      <button
        type="submit"
        disabled={busy}
        className="btn-primary min-h-11 w-full text-sm disabled:opacity-50"
      >
        {busy ? 'Recording override…' : overrideAction === 'admit' ? 'Confirm override & Admit' : 'Confirm override & Clear'}
      </button>
    </form>
  )
}
