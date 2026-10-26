import { useState } from 'react'
import apiClient from '../../api/client'
import { downloadJournalFile, parseJournal } from '../../utils/admissionJournal'

export default function JournalRecovery({ eventId, onRecovered }) {
  const [journal, setJournal] = useState(null)
  const [reason, setReason] = useState('')
  const [start, setStart] = useState('')
  const [end, setEnd] = useState('')
  const [reviewed, setReviewed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const [receipt, setReceipt] = useState(null)

  async function chooseFile(event) {
    setJournal(null); setReceipt(null); setReviewed(false); setMessage('')
    try {
      const file = event.target.files?.[0]
      if (!file) return
      if (file.size > 2_000_000) throw new Error('Journal is too large. Retain the original and ask support for help.')
      setJournal(parseJournal(await file.text(), eventId))
    } catch (error) { setMessage(error.message) }
  }

  async function recover(event) {
    event.preventDefault()
    if (!journal || !reviewed || busy) return
    setBusy(true); setMessage(''); setReceipt(null)
    try {
      const { data } = await apiClient.post(`/organizer/events/${eventId}/scanner_devices/${journal.device_id}/recover`, {
        actions: journal.actions, reason, window_start: start, window_end: end,
      }, { timeout: 30_000 })
      setReceipt({ schema: 'hafapass-admission-recovery-receipt-v1', event_id: Number(eventId),
        device_id: journal.device_id, results: data.results })
      const counts = data.results.reduce((totals, item) => ({ ...totals, [item.result]: (totals[item.result] || 0) + 1 }), {})
      setMessage(`Review recorded: ${counts.accepted || 0} accepted, ${counts.conflict || 0} conflicts, ${counts.rejected || 0} rejected. Device permission is unchanged. Original saved scans are retained. Save the receipt and investigate conflicts; do not admit guests again.`)
      onRecovered?.(data.summary)
    } catch (error) {
      setMessage(error.response?.data?.error || 'Recovery was not confirmed. Keep the original file and retry with the same action IDs. Do not admit guests again.')
    } finally { setBusy(false) }
  }

  return <details className="mt-4 border-t border-neutral-200 pt-2">
    <summary className="flex min-h-11 cursor-pointer items-center font-semibold">Manager: recover an offline journal</summary>
    <p className="mt-2 text-sm text-neutral-700">Use this after independently checking the gate log and staff handover. A client timestamp alone does not prove entry. Only offline admissions from a known downloaded list, within its original lease and before revocation, can be recovered. Review within 48 hours; use a window of at most 24 hours. Recovery never restores scanner access.</p>
    <form onSubmit={recover} className="mt-3 space-y-3">
      <label className="block text-sm font-medium">Saved journal file<input type="file" accept="application/json,.json" onChange={chooseFile} disabled={busy} className="mt-1 block min-h-11 w-full text-base" /></label>
      {journal && <p className="text-sm">Device {journal.device_id} · {journal.actions.length} saved scans. Online scans and Undo requests need separate investigation.</p>}
      <label className="block text-sm font-medium">Reviewed start (ISO 8601 with timezone)<input required value={start} onChange={event => setStart(event.target.value)} placeholder="2026-10-26T08:00:00+10:00" className="input mt-1 w-full text-base" disabled={busy} /></label>
      <label className="block text-sm font-medium">Reviewed end, exclusive (ISO 8601 with timezone)<input required value={end} onChange={event => setEnd(event.target.value)} placeholder="2026-10-26T09:00:00+10:00" className="input mt-1 w-full text-base" disabled={busy} /></label>
      <label className="block text-sm font-medium">Gate evidence and reason<textarea required minLength={12} maxLength={500} value={reason} onChange={event => setReason(event.target.value)} className="input mt-1 w-full text-base" disabled={busy} /></label>
      <label className="flex min-h-11 items-start gap-2 text-sm"><input type="checkbox" checked={reviewed} onChange={event => setReviewed(event.target.checked)} disabled={busy} className="mt-1" />I independently reviewed these entries against the physical gate record and approve this historical window.</label>
      <button className="btn-secondary min-h-11" disabled={!journal || !reviewed || busy}>{busy ? 'Recording review…' : 'Recover reviewed admissions'}</button>
    </form>
    {message && <p role="status" className="mt-3 break-words text-sm">{message}</p>}
    {receipt && <button className="btn-secondary mt-3 min-h-11" onClick={() => downloadJournalFile(receipt, `hafapass-recovery-${eventId}-${journal.device_id}.json`)}>Save recovery receipt</button>}
  </details>
}
