import { useState } from 'react'
import Dialog from './Dialog'
import { formatEventDate } from '../utils/eventTime'

// A sent-but-unaccepted transfer on the holder's ticket, with a confirmed
// cancel. `onCancel` performs the request; `onSettled` refreshes the list
// whether the cancel succeeded or the transfer had already ended.
export default function PendingTransfer({ transfer, timeZone, onCancel, onSettled }) {
  const [confirming, setConfirming] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const expires = formatEventDate(transfer.expires_at, timeZone, { year: undefined })

  async function cancel() {
    if (busy) return
    setBusy(true)
    setError(null)
    try {
      await onCancel()
      setConfirming(false)
      onSettled?.({ status: 'cancelled', message: 'Transfer cancelled. Your ticket stays with you.' })
    } catch (err) {
      const status = err.response?.status
      if (status === 404 || status === 422) {
        // Accepted, expired or cancelled elsewhere while this page was open.
        setConfirming(false)
        onSettled?.({ status: 'ended', message: 'This transfer already ended, so there was nothing to cancel. Your tickets are refreshed.' })
      } else {
        setError(err.response?.data?.error || 'We could not cancel the transfer. Check your connection and try again.')
      }
    } finally {
      setBusy(false)
    }
  }

  return <div className="mt-1">
    <p className="text-xs text-amber-800">
      <span className="font-semibold">Transfer pending</span>
      {' · '}sent to <span className="break-all">{transfer.recipient_email}</span>
      {expires && <>{' · '}expires {expires}</>}
    </p>
    <button type="button" onClick={() => { setError(null); setConfirming(true) }}
      className="mt-1 min-h-11 rounded-lg px-2 text-xs font-semibold text-red-700 transition-[background-color,transform] duration-150 ease-out-strong active:scale-[0.97] hover:bg-red-50">
      Cancel transfer
    </button>
    {confirming && <Dialog labelledBy={`cancel-transfer-${transfer.id}`} onClose={() => setConfirming(false)} busy={busy} className="max-w-md">
      <h2 id={`cancel-transfer-${transfer.id}`} className="text-lg font-semibold text-neutral-900">Cancel this transfer?</h2>
      <p className="mt-2 text-sm text-neutral-600">The link sent to <strong className="break-all text-neutral-900">{transfer.recipient_email}</strong> stops working and the ticket stays with you. You can send a new transfer afterward.</p>
      {error && <p role="alert" className="mt-3 text-sm text-red-700">{error}</p>}
      <div className="mt-6 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
        <button type="button" className="btn-secondary min-h-11 px-5" onClick={() => setConfirming(false)} disabled={busy}>Keep transfer</button>
        <button type="button" className="btn-danger min-h-11 px-5" onClick={cancel} disabled={busy}>{busy ? 'Cancelling…' : 'Cancel transfer'}</button>
      </div>
    </Dialog>}
  </div>
}
