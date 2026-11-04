import { useCallback, useEffect, useId, useMemo, useState } from 'react'
import { Loader2 } from 'lucide-react'
import apiClient from '../../api/client'
import Dialog from '../../components/Dialog'
import { errorMessage } from './adminOperations'

const money = (cents = 0) => (cents / 100).toLocaleString('en-US', { style: 'currency', currency: 'USD' })
const newRequestKey = () => globalThis.crypto?.randomUUID?.() || `admin-refund-${Date.now()}-${Math.random()}`
const journalKey = orderId => `hafapass_admin_refund:${orderId}`

const amountToCents = text => {
  const value = text.trim().replace(/^\$/, '')
  if (!/^\d+(\.\d{1,2})?$/.test(value)) return null
  return Math.round(Number(value) * 100)
}

// A request whose outcome is unknown stays saved, so retrying replays the same
// key and the server can't refund twice, even after the dialog closes.
function readJournal(orderId) {
  try {
    const saved = JSON.parse(window.sessionStorage.getItem(journalKey(orderId)) || 'null')
    return typeof saved?.key === 'string' && saved.key && saved.payload && typeof saved.cents === 'number' ? saved : null
  } catch {
    return null
  }
}

function saveJournal(orderId, journal) {
  try {
    if (journal) window.sessionStorage.setItem(journalKey(orderId), JSON.stringify(journal))
    else window.sessionStorage.removeItem(journalKey(orderId))
  } catch { /* Unavailable storage only loses recovery after this dialog closes. */ }
}

const ticketLabel = ticket => [ticket.ticket_type, ticket.attendee_name].filter(Boolean).join(' · ') || `Ticket #${ticket.id}`

export default function AdminOrderRefundDialog({ order, onClose, onRefunded }) {
  const titleId = useId()
  const [options, setOptions] = useState(null)
  const [loadError, setLoadError] = useState('')
  const [journal, setJournal] = useState(() => readJournal(order.id))
  const [mode, setMode] = useState('full')
  const [selected, setSelected] = useState([])
  const [amount, setAmount] = useState('')
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const loadOptions = useCallback(async () => {
    setLoadError('')
    setOptions(null)
    try {
      const response = await apiClient.get(`/admin/orders/${order.id}/refund_options`)
      setOptions(response.data)
    } catch (failure) {
      setLoadError(errorMessage(failure, "We couldn't load this order's refund details."))
    }
  }, [order.id])

  useEffect(() => { loadOptions() }, [loadOptions])

  const tickets = useMemo(() => options?.tickets || [], [options])
  const refundable = options?.refundable_cents || 0
  const cents = journal ? journal.cents
    : mode === 'full' ? refundable
      : mode === 'tickets' ? tickets.filter(ticket => selected.includes(ticket.id)).reduce((sum, ticket) => sum + ticket.refundable_cents, 0)
        : amountToCents(amount)
  const transferredTickets = tickets.filter(ticket => ticket.transferred && !ticket.unavailable_reason)
  const selectedTransferred = tickets.some(ticket => ticket.transferred && selected.includes(ticket.id))
  const blocked = Boolean(options?.unavailable_reason) && !journal

  const validationError = () => {
    if (mode === 'tickets' && !selected.length) return 'Choose at least one ticket.'
    if (mode === 'amount' && (cents === null || cents <= 0)) return 'Enter an amount in dollars, like 25 or 25.50.'
    if (cents > refundable) return `The most you can refund is ${money(refundable)}.`
    if (cents <= 0) return 'Nothing is left to refund on this order.'
    if (!note.trim()) return 'Add a note explaining the refund.'
    return ''
  }

  const submit = async event => {
    event.preventDefault()
    if (busy) return
    let request = journal
    if (!request) {
      const invalid = validationError()
      if (invalid) { setError(invalid); return }
      request = { key: newRequestKey(), cents, payload: {
        note: note.trim(),
        ...(mode === 'amount' ? { amount_cents: cents } : {}),
        ...(mode === 'tickets' ? { ticket_ids: selected } : {}),
      } }
      saveJournal(order.id, request)
      setJournal(request)
    }
    setBusy(true)
    setError('')
    try {
      const response = await apiClient.post(`/admin/orders/${order.id}/refund`, request.payload,
        { headers: { 'Idempotency-Key': request.key } })
      // A pending refund keeps its key, so reopening checks this same request.
      if (response.data?.refund?.status !== 'pending') saveJournal(order.id, null)
      onRefunded(response.data)
    } catch (failure) {
      const data = failure?.response?.data
      if (data?.reconciliation_required === false) {
        saveJournal(order.id, null)
        setJournal(null)
        setError(`${errorMessage(failure, 'The refund was rejected.')} No refund was sent.`)
        loadOptions()
      } else {
        setError(`${errorMessage(failure, "We couldn't confirm the result.")} This refund isn't confirmed. Trying again checks the same request and can't refund twice.`)
      }
      setBusy(false)
    }
  }

  const toggleTicket = id => {
    setError('')
    setSelected(current => current.includes(id) ? current.filter(value => value !== id) : [...current, id])
  }
  const chooseMode = next => { setError(''); setMode(next) }
  const modeOption = (value, label, hint) => (
    <label className="flex min-h-11 cursor-pointer items-start gap-3 rounded-xl border border-neutral-200 p-3 has-[:checked]:border-brand-500 has-[:checked]:bg-brand-50">
      <input type="radio" name="refund-mode" className="mt-1" checked={mode === value} onChange={() => chooseMode(value)} />
      <span><span className="block text-sm font-medium text-neutral-900">{label}</span><span className="block text-sm text-neutral-600">{hint}</span></span>
    </label>
  )

  return <Dialog labelledBy={titleId} onClose={onClose} busy={busy} className="max-w-lg">
    <form noValidate onSubmit={submit}>
      <h2 id={titleId} className="text-lg font-semibold text-neutral-900">Refund order #{order.id}</h2>
      {!options && !loadError && <div role="status" aria-label="Loading refund details" className="flex justify-center py-8"><Loader2 className="h-6 w-6 animate-spin text-brand-500" /></div>}
      {loadError && <div className="mt-3">
        <p role="alert" className="text-sm text-red-700">{loadError}</p>
        <button type="button" className="btn-secondary mt-3" onClick={loadOptions}>Try again</button>
      </div>}
      {options && <>
        {options.unavailable_reason && !journal && <p role="alert" className="mt-3 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">{options.unavailable_reason}</p>}
        {options.event_paid_out && <p className="mt-3 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
          <strong>This event has already been paid out.</strong> HåfaPass&apos;s Stripe balance pays this refund. Any amount above {options.organization_name || 'the organizer'}&apos;s balance becomes a negative balance they owe, deducted from future payouts or invoiced.
        </p>}
        {journal ? <p role="status" className="mt-3 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
          An earlier refund of {money(journal.cents)} for this order isn&apos;t confirmed. Check it before doing anything else. This replays the same request and can&apos;t refund twice.
        </p> : !blocked && <>
          <fieldset className="mt-4 space-y-2">
            <legend className="mb-2 text-sm font-medium text-neutral-800">What to refund</legend>
            {modeOption('full', `Everything left (${money(refundable)})`, 'Cancels every ticket that has not been scanned.')}
            {tickets.length > 0 && modeOption('tickets', 'Selected tickets', 'Refunds each ticket’s value and cancels only those tickets.')}
            {modeOption('amount', 'A set amount', 'Tickets stay valid.')}
          </fieldset>
          {mode === 'full' && transferredTickets.length > 0 && <p className="mt-3 text-sm text-amber-800">This also cancels {transferredTickets.length === 1 ? 'a ticket' : `${transferredTickets.length} tickets`} transferred to someone else. The refund goes to the original buyer&apos;s card.</p>}
          {mode === 'tickets' && <fieldset className="mt-3 space-y-1">
            <legend className="sr-only">Tickets to refund</legend>
            {tickets.map(ticket => <label key={ticket.id} className={`flex min-h-11 items-center gap-3 text-sm ${ticket.unavailable_reason ? 'text-neutral-500' : 'cursor-pointer text-neutral-800'}`}>
              <input type="checkbox" disabled={Boolean(ticket.unavailable_reason)} checked={selected.includes(ticket.id)} onChange={() => toggleTicket(ticket.id)} />
              <span className="min-w-0 flex-1 break-words">{ticketLabel(ticket)}{ticket.transferred ? ' · transferred' : ''}{ticket.unavailable_reason ? ` · ${ticket.unavailable_reason}` : ''}</span>
              <span className="tabular-nums">{money(ticket.refundable_cents)}</span>
            </label>)}
            {selectedTransferred && <p className="text-sm text-amber-800">The refund goes to the original buyer&apos;s card, and the current holder loses this ticket. Tell them yourself.</p>}
          </fieldset>}
          {mode === 'amount' && <label className="mt-3 block text-sm font-medium text-neutral-800">Amount in dollars
            <input className="input mt-1" inputMode="decimal" value={amount} onChange={event => { setError(''); setAmount(event.target.value) }} />
          </label>}
          <label className="mt-4 block text-sm font-medium text-neutral-800">Note for the audit log
            <textarea className="input mt-1 min-h-24" value={note} maxLength={2000} onChange={event => { setError(''); setNote(event.target.value) }} required />
          </label>
          <p className="mt-3 text-sm text-neutral-700">The buyer gets a refund email. This can&apos;t be undone.</p>
        </>}
      </>}
      {error && <p role="alert" className="mt-3 text-sm text-red-700">{error}</p>}
      <div className="mt-5 flex flex-wrap justify-end gap-2">
        <button type="button" className="btn-secondary" disabled={busy} onClick={onClose}>{blocked || loadError ? 'Close' : 'Cancel'}</button>
        {options && !blocked && <button type="submit" className="btn-primary" disabled={busy}>
          {busy ? 'Refunding…' : journal ? 'Check this refund' : cents > 0 ? `Refund ${money(cents)}` : 'Refund'}
        </button>}
      </div>
    </form>
  </Dialog>
}
