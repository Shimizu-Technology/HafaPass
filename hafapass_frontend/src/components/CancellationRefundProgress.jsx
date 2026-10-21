import { useCallback, useEffect, useState } from 'react'
import apiClient from '../api/client'
import Dialog from './Dialog'

const money = cents => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(cents / 100)

export default function CancellationRefundProgress({ eventId, admin = false, status, onCancelled, canMarkCash = false, canRefund = true }) {
  const base = `${admin ? '/admin' : '/organizer'}/events/${eventId}`
  const [data, setData] = useState(null)
  const [error, setError] = useState('')
  const [confirming, setConfirming] = useState(false)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [open, setOpen] = useState(false)
  const [cashItem, setCashItem] = useState(null)
  const [reference, setReference] = useState('')
  const [returnedAt, setReturnedAt] = useState('')
  const runStatus = data?.run?.status
  const load = useCallback(() => apiClient.get(`${base}/cancellation_refunds`).then(response => {
    setData(response.data)
    setError('')
  }).catch(() => setError('Refund progress could not be loaded. Try again.')), [base])

  useEffect(() => { if (open) load() }, [load, open])
  useEffect(() => {
    if (!open || !runStatus || runStatus === 'completed') return
    const timer = window.setInterval(load, 5000)
    return () => window.clearInterval(timer)
  }, [open, runStatus, load])

  async function mutate(path, payload) {
    setBusy(true)
    setError('')
    try {
      const response = await apiClient.post(path, payload)
      await load()
      return response.data
    } catch (failure) {
      setError(failure.response?.data?.error || 'The action could not be completed. Refresh the refund status before trying again.')
      return null
    } finally { setBusy(false) }
  }

  async function cancel() {
    const preview = data?.preview
    if (!preview || !reason.trim()) return
    const result = await mutate(`${base}/${admin ? 'cancel_and_refund' : 'cancel'}`, {
      reason: reason.trim(), refund_count: preview.count, refund_total_cents: preview.total_cents,
    })
    if (result) { setConfirming(false); setReason(''); onCancelled?.() }
  }

  return <div>
    <button type="button" className="text-sm font-semibold text-brand-700 underline" onClick={() => setOpen(value => !value)}>
      {open ? 'Hide refund progress' : status === 'cancelled' ? 'View cancellation refunds' : 'Review cancellation and refunds'}
    </button>
    {open && <section className="mt-3 max-w-2xl rounded-xl border border-neutral-200 bg-white p-4 text-sm">
      {error && <p role="alert" className="mb-3 text-red-700">{error}</p>}
      {!data && error ? <button type="button" className="btn-secondary" onClick={load}>Retry loading refund details</button>
        : !data ? <p role="status">Loading refund details…</p> : <>
        {status !== 'cancelled' && <><p>{data.preview.count} orders · {money(data.preview.total_cents)} including service fees.</p>
          {data.preview.cash_count > 0 && <p>{data.preview.cash_count} cash orders will need a manual return and record.</p>}
          {canRefund ? <button type="button" className="btn-primary mt-3" onClick={() => setConfirming(true)}>Cancel event and refund all buyers</button>
            : <p className="mt-3">Ask an owner to cancel the event and refund buyers.</p>}</>}
        {data.run && <>
          <h3 className="font-semibold">Cancellation refunds</h3>
          <p role="status" className="mt-2">{data.run.refunded} refunded · {data.run.pending} pending · {data.run.waiting_on_pending_refund || 0} awaiting refund confirmation · {data.run.waiting_on_dispute || 0} awaiting dispute resolution · {data.run.failed} failed · {data.run.needs_manual} need manual cash refund · {data.run.skipped} skipped</p>
          {canRefund && (data.run.failed > 0 || data.run.pending > 0) && <button type="button" disabled={busy} className="btn-secondary mt-3" onClick={() => mutate(`${base}/retry_cancellation_refunds`, {})}>{data.run.failed > 0 ? 'Retry failed' : 'Resume pending'}</button>}
          {!canRefund && data.run.failed > 0 && <p className="mt-2">Ask an owner or finance teammate to retry failed refunds.</p>}
          <ul className="mt-3 divide-y divide-neutral-100">{data.run.items.map(item => <li key={item.id} className="py-2">
            <strong>{item.order_reference}</strong> · {money(item.amount_cents)} · {item.status.replaceAll('_', ' ')}
            {item.error && <p className="text-red-700">{item.error}</p>}
            {item.status === 'needs_manual' && (canMarkCash
              ? <button type="button" className="mt-2 font-semibold text-brand-700 underline" onClick={() => setCashItem(item)}>Mark refunded in cash</button>
              : <p>Ask an owner or finance teammate to record the cash return.</p>)}
          </li>)}</ul>
        </>}
      </>}
    </section>}
    {confirming && <Dialog labelledBy="cancel-refunds-title" onClose={() => setConfirming(false)} busy={busy} className="max-w-md">
      <h2 id="cancel-refunds-title" className="text-lg font-semibold">Cancel event and refund all buyers?</h2>
      <p className="mt-3">Refund {data?.preview.count} orders, {money(data?.preview.total_cents || 0)} including service fees.</p>
      <p className="mt-2 font-semibold text-red-700">This cannot be undone.</p>
      <label className="mt-4 block">Reason for cancellation<textarea className="input mt-1" value={reason} onChange={event => setReason(event.target.value)} /></label>
      <div className="mt-5 flex flex-wrap gap-2"><button type="button" className="btn-secondary" onClick={() => setConfirming(false)}>Keep event</button><button type="button" disabled={busy || !reason.trim()} className="btn-primary" onClick={cancel}>Confirm cancellation and refunds</button></div>
    </Dialog>}
    {cashItem && <Dialog labelledBy="cash-refund-title" onClose={() => setCashItem(null)} busy={busy} className="max-w-md">
      <h2 id="cash-refund-title" className="text-lg font-semibold">Record cash returned to buyer</h2>
      <p className="mt-2">{cashItem.order_reference} · {money(cashItem.amount_cents)}. Return the cash before recording it here.</p>
      <label className="mt-4 block">Cash return reference<input className="input mt-1" value={reference} onChange={event => setReference(event.target.value)} /></label>
      <label className="mt-3 block">Returned at<input type="datetime-local" className="input mt-1" value={returnedAt} onChange={event => setReturnedAt(event.target.value)} /></label>
      <div className="mt-5 flex flex-wrap gap-2"><button type="button" className="btn-secondary" onClick={() => setCashItem(null)}>Close</button><button type="button" disabled={busy || !reference.trim() || !returnedAt} className="btn-primary" onClick={async () => {
        const result = await mutate(`${base}/cancellation_refunds/${cashItem.order_id}/mark_cash_refunded`, { reference: reference.trim(), returned_at: new Date(returnedAt).toISOString() })
        if (result) { setCashItem(null); setReference(''); setReturnedAt('') }
      }}>Mark refunded in cash</button></div>
    </Dialog>}
  </div>
}
