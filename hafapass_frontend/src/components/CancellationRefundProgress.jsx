import { useCallback, useEffect, useState } from 'react'
import apiClient from '../api/client'
import Dialog from './Dialog'
import { formatEventDateTime, fromEventLocalInput, toEventLocalInput } from '../utils/eventTime'

const money = cents => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(cents / 100)

export default function CancellationRefundProgress({ eventId, admin = false, status, onCancelled, canMarkCash = false, canRefund = true, eventTimeZone = 'Pacific/Guam', prominent = false }) {
  const base = `${admin ? '/admin' : '/organizer'}/events/${eventId}`
  const [data, setData] = useState(null)
  const [page, setPage] = useState(1)
  const [error, setError] = useState('')
  const [confirming, setConfirming] = useState(false)
  const [confirmingLegacy, setConfirmingLegacy] = useState(false)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [open, setOpen] = useState(false)
  const [cashItem, setCashItem] = useState(null)
  const [reference, setReference] = useState('')
  const [returnedAt, setReturnedAt] = useState('')
  const [cashError, setCashError] = useState('')
  const runStatus = data?.run?.status
  const load = useCallback(() => apiClient.get(`${base}/cancellation_refunds`, { params: { page } }).then(response => {
    setData(response.data)
    setError('')
  }).catch(() => setError('Refund progress could not be loaded. Try again.')), [base, page])

  useEffect(() => { if (open || (prominent && status === 'cancelled')) load() }, [load, open, prominent, status])
  useEffect(() => {
    if ((!open && !prominent) || !runStatus || runStatus === 'completed') return
    const timer = window.setInterval(load, 5000)
    return () => window.clearInterval(timer)
  }, [open, prominent, runStatus, load])

  async function mutate(path, payload) {
    setBusy(true)
    setError('')
    try {
      const response = await apiClient.post(path, payload)
      await load()
      return response.data
    } catch (failure) {
      if (failure.response?.status === 409 && failure.response?.data?.preview) {
        setData(previous => previous && ({ ...previous, preview: failure.response.data.preview }))
      }
      setError(failure.response?.data?.error || 'The action could not be completed. Refresh the refund status before trying again.')
      if (cashItem) setCashError(failure.response?.data?.error || 'The cash return could not be recorded. Try again.')
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

  async function startLegacy() {
    const preview = data?.preview
    if (!preview) return
    const result = await mutate(`${base}/start_cancellation_refunds`, {
      refund_count: preview.count, refund_total_cents: preview.total_cents,
    })
    if (result) setConfirmingLegacy(false)
  }

  function openCash(item) {
    setCashItem(item)
    setCashError('')
    setReturnedAt(toEventLocalInput(new Date(), eventTimeZone))
  }

  async function markCash() {
    const instant = fromEventLocalInput(returnedAt, eventTimeZone)
    const soldAt = cashItem.order_created_at && new Date(cashItem.order_created_at)
    if (!instant || instant > new Date() || (soldAt && instant < soldAt)) {
      setCashError(`Use a time after the sale${soldAt ? ` (${formatEventDateTime(soldAt, eventTimeZone)})` : ''} and not in the future.`)
      return
    }
    setCashError('')
    const result = await mutate(`${base}/cancellation_refunds/${cashItem.order_id}/mark_cash_refunded`, { reference: reference.trim(), returned_at: instant.toISOString() })
    if (result) { setCashItem(null); setReference(''); setReturnedAt('') }
  }

  const progressCounts = data?.run && [
    [data.run.refunded, 'refunded'], [data.run.pending, 'pending'],
    [data.run.waiting_on_pending_refund, 'Awaiting refund confirmation'],
    [data.run.waiting_on_dispute, 'Awaiting dispute resolution'],
    [data.run.failed, 'failed'], [data.run.needs_manual, 'Needs cash return'],
    [data.run.skipped, 'already resolved'],
  ].filter(([count]) => count > 0)

  return <div className="min-w-0">
    <button type="button" className={prominent ? 'w-full rounded-xl border border-amber-300 bg-amber-50 p-4 text-left text-sm font-semibold text-amber-950 hover:bg-amber-100' : 'text-sm font-semibold text-brand-700 underline'} onClick={() => setOpen(value => !value)}>
      {prominent && data?.run ? `Cancellation refunds: ${data.run.refunded + data.run.skipped} of ${data.run.total_orders} done · ${open ? 'Hide details' : 'View details'}` : open ? 'Hide refund progress' : status === 'cancelled' ? 'View cancellation refunds' : 'Review cancellation and refunds'}
    </button>
    {open && <section id="cancellation-refund-progress" className="mt-3 max-w-2xl min-w-0 rounded-xl border border-neutral-200 bg-white p-4 text-sm [overflow-wrap:anywhere]">
      {error && <p role="alert" className="mb-3 text-red-700">{error}</p>}
      {!data && error ? <button type="button" className="btn-secondary" onClick={load}>Retry loading refund details</button>
        : !data ? <p role="status">Loading refund details…</p> : <>
        {status !== 'cancelled' && <><p>{data.preview.count} {data.preview.count === 1 ? 'order' : 'orders'} · {money(data.preview.total_cents)} including service fees.</p>
          {data.preview.cash_count > 0 && <p>{data.preview.cash_count} cash {data.preview.cash_count === 1 ? 'order' : 'orders'} will need a manual return and record.</p>}
          {canRefund ? <button type="button" className="btn-primary mt-3" onClick={() => setConfirming(true)}>Cancel event and refund all buyers</button>
            : <p className="mt-3">Ask an owner to cancel the event and refund buyers.</p>}</>}
        {status === 'cancelled' && !data.run && <>
          <p>{data.preview.count} {data.preview.count === 1 ? 'order' : 'orders'} · {money(data.preview.total_cents)} still to resolve.</p>
          {admin && <button type="button" disabled={busy} className="btn-primary mt-3"
            onClick={() => setConfirmingLegacy(true)}>Start refunds for this cancelled event</button>}
          {!admin && <p className="mt-2">Ask an admin to start refunds for this cancelled event.</p>}
        </>}
        {data.run && <>
          <h3 className="font-semibold">Cancellation refunds</h3>
          <p role="status" className="mt-2">{progressCounts.map(([count, label]) => `${count} ${label}`).join(' · ')}</p>
          {canRefund && (data.run.failed > 0 || data.run.pending > 0) && <button type="button" disabled={busy} className="btn-secondary mt-3" onClick={() => mutate(`${base}/retry_cancellation_refunds`, {})}>{data.run.failed > 0 ? 'Retry failed' : 'Resume pending'}</button>}
          {!canRefund && data.run.failed > 0 && <p className="mt-2">Ask an owner or finance teammate to retry failed refunds.</p>}
          <ul className="mt-3 divide-y divide-neutral-100">{data.run.items.map(item => <li key={item.id} className="py-3">
            <strong>{item.order_reference}</strong><span className="block text-neutral-700">{item.status === 'refunded' ? `${money(item.amount_cents)} refunded ${item.payment_method === 'door_cash' ? 'in cash' : 'to card'}` : `${money(item.amount_cents)}${item.status === 'needs_manual' ? ' remaining to return' : ''} · ${item.status === 'needs_manual' ? 'Needs cash return' : item.status.replaceAll('_', ' ')}`}</span>
            {item.error && <p className="text-red-700">{item.error}</p>}
            {item.status === 'needs_manual' && (canMarkCash
              ? <button type="button" className="btn-secondary mt-3 block" onClick={() => openCash(item)}>Mark refunded in cash</button>
              : <p>Ask an owner or finance teammate to record the cash return.</p>)}
          </li>)}</ul>
          {data.run.item_total_pages > 1 && <div className="mt-4 flex flex-wrap items-center gap-3">
            <button type="button" className="btn-secondary" disabled={page <= 1} onClick={() => setPage(value => value - 1)}>Previous orders</button>
            <span>Page {data.run.item_page} of {data.run.item_total_pages}</span>
            <button type="button" className="btn-secondary" disabled={page >= data.run.item_total_pages} onClick={() => setPage(value => value + 1)}>Next orders</button>
          </div>}
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
    {confirmingLegacy && <Dialog labelledBy="legacy-refunds-title" onClose={() => setConfirmingLegacy(false)} busy={busy} className="max-w-md">
      <h2 id="legacy-refunds-title" className="text-lg font-semibold">Start refunds for this cancelled event?</h2>
      <p className="mt-3">Review {data?.preview.count} {data?.preview.count === 1 ? 'order' : 'orders'} and {money(data?.preview.total_cents || 0)} still to resolve. Card refunds will start after confirmation.</p>
      <div className="mt-5 flex flex-wrap gap-2"><button type="button" className="btn-secondary" onClick={() => setConfirmingLegacy(false)}>Keep reviewing</button><button type="button" disabled={busy} className="btn-primary" onClick={startLegacy}>Confirm and start refunds</button></div>
    </Dialog>}
    {cashItem && <Dialog labelledBy="cash-refund-title" onClose={() => setCashItem(null)} busy={busy} className="max-w-md">
      <h2 id="cash-refund-title" className="text-lg font-semibold">Record cash returned to buyer</h2>
      <p className="mt-2">{cashItem.order_reference} · {money(cashItem.amount_cents)}. Return the cash before recording it here.</p>
      {cashError && <p role="alert" className="mt-3 text-sm text-red-700">{cashError}</p>}
      <label className="mt-4 block">Cash return reference<input className="input mt-1" value={reference} onChange={event => setReference(event.target.value)} /></label>
      <label className="mt-3 block">Returned at ({eventTimeZone})<input type="datetime-local" required className="input mt-1" value={returnedAt} onChange={event => setReturnedAt(event.target.value)} /></label>
      <div className="mt-5 flex flex-wrap gap-2"><button type="button" className="btn-secondary" onClick={() => setCashItem(null)}>Close</button><button type="button" disabled={busy || !reference.trim() || !returnedAt} className="btn-primary" onClick={markCash}>Mark refunded in cash</button></div>
    </Dialog>}
  </div>
}
