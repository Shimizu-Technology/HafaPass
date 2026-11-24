import { useId, useState } from 'react'
import { Link } from 'react-router-dom'
import { AlertTriangle, CalendarClock, CheckCircle2, Clock, Loader2 } from 'lucide-react'
import apiClient from '../../api/client'
import Dialog from '../../components/Dialog'
import { errorMessage, foldCell, foldRow, foldTable, money } from './adminOperations'
import { formatDay } from '../../utils/payoutStatement'

// Admin → Payouts → Due. Which events need their bank transfer (2–3 business
// days after the event, Guam time) and which reserves are due for release
// (30 days after the event). Each row offers the next step; the API rechecks
// every guard before it changes anything. Money still moves outside HåfaPass.

const DUE_TONE = {
  overdue: 'bg-red-50 text-red-800 ring-red-200',
  due: 'bg-amber-50 text-amber-900 ring-amber-200',
  upcoming: 'bg-neutral-100 text-neutral-700 ring-neutral-200',
  none: 'bg-neutral-100 text-neutral-700 ring-neutral-200',
}

function DueBadge({ row }) {
  if (!row.due_on) return null
  const Icon = row.due_state === 'overdue' ? AlertTriangle : row.due_state === 'upcoming' ? CalendarClock : Clock
  const label = row.due_state === 'overdue'
    ? `Overdue${row.overdue_business_days > 0 ? ` ${row.overdue_business_days} business day${row.overdue_business_days === 1 ? '' : 's'}` : ''} · was due ${formatDay(row.due_on)}`
    : row.due_state === 'upcoming' ? `Release on ${formatDay(row.due_on)}` : `Due by ${formatDay(row.due_on)}`
  return <span className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-semibold ring-1 ${DUE_TONE[row.due_state] || DUE_TONE.none}`}><Icon aria-hidden="true" className="h-3.5 w-3.5" />{label}</span>
}

function ReserveDialog({ row, beginRequest, onClose, onSaved }) {
  const titleId = useId()
  const [amount, setAmount] = useState(((row.suggested_reserve_cents || 0) / 100).toFixed(2))
  const [note, setNote] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const cents = /^\d+(\.\d{1,2})?$/.test(amount.trim()) ? Math.round(Number(amount.trim()) * 100) : null
  const submit = async event => {
    event.preventDefault()
    if (!cents) { setError('Enter a positive amount in dollars and cents.'); return }
    const request = beginRequest()
    if (!request) return
    setBusy(true); setError('')
    try {
      const body = cents === row.suggested_reserve_cents ? {} : { amount_cents: cents }
      if (note.trim()) body.note = note.trim()
      await apiClient.post(`/admin/payout_schedule/${row.event.id}/reserve`, body, request.config)
      if (request.current()) onSaved(`Reserve of ${money(cents, row.currency)} held for ${row.event.title}. Finalize the statement next.`)
    } catch (failure) {
      if (request.current() && !request.handleError(failure)) setError(errorMessage(failure, 'The reserve was not held. Check your connection and try again.'))
    } finally { request.release(); setBusy(false) }
  }
  return <Dialog labelledBy={titleId} busy={busy} onClose={onClose} className="max-w-lg">
    <form noValidate onSubmit={submit}>
      <h2 id={titleId} className="text-lg font-semibold text-neutral-900">Hold the chargeback reserve</h2>
      <p className="mt-1 text-sm text-content-muted [overflow-wrap:anywhere]">{row.event.title} · {row.organization.name}</p>
      <dl className="mt-4 space-y-1 rounded-lg bg-neutral-50 p-3 text-sm ring-1 ring-neutral-200">
        <div className="flex justify-between gap-4"><dt>Net proceeds held by HåfaPass</dt><dd className="font-medium tabular-nums">{money(row.net_proceeds_cents, row.currency)}</dd></div>
        <div className="flex justify-between gap-4"><dt>Standard 10% reserve</dt><dd className="font-medium tabular-nums">{money(row.suggested_reserve_cents, row.currency)}</dd></div>
        <div className="flex justify-between gap-4"><dt>Release date</dt><dd className="font-medium">{formatDay(row.reserve_release_on)}</dd></div>
      </dl>
      <label className="mt-4 block text-sm font-medium text-neutral-900">Reserve amount ($)
        <input type="number" inputMode="decimal" min="0.01" step="0.01" value={amount} onChange={event => setAmount(event.target.value)} className="input mt-1" />
      </label>
      <label className="mt-3 block text-sm font-medium text-neutral-900">Note (optional, shown in the adjustment reason)
        <input value={note} onChange={event => setNote(event.target.value)} maxLength={300} className="input mt-1" />
      </label>
      <p className="mt-3 text-sm text-neutral-700">This posts a reserve hold. It moves no money. The organizer sees it on their statement with the release date.</p>
      {error && <p role="alert" className="mt-3 rounded-lg bg-red-50 p-3 text-sm text-red-800">{error}</p>}
      <div className="mt-6 flex flex-wrap justify-end gap-3">
        <button type="button" onClick={onClose} disabled={busy} className="btn-secondary">Cancel</button>
        <button type="submit" disabled={busy} className="btn-primary">{busy ? 'Holding…' : 'Hold reserve'}</button>
      </div>
    </form>
  </Dialog>
}

function ReleaseDialog({ row, beginRequest, onClose, onSaved }) {
  const titleId = useId()
  const early = row.due_state === 'upcoming'
  const [reason, setReason] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const remaining = row.after_release_cents ?? row.owed_cents + row.reserve_held_cents
  const submit = async event => {
    event.preventDefault()
    if (early && reason.trim().length < 10) { setError('Explain the early release in at least 10 characters.'); return }
    const request = beginRequest()
    if (!request) return
    setBusy(true); setError('')
    try {
      await apiClient.post(`/admin/payout_schedule/${row.event.id}/release`, early ? { early_release_reason: reason.trim() } : {}, request.config)
      if (request.current()) onSaved(`Reserve released for ${row.event.title}.${remaining > 0 ? ' Finalize the statement and send the remaining transfer.' : ''}`)
    } catch (failure) {
      if (request.current() && !request.handleError(failure)) setError(errorMessage(failure, 'The reserve was not released. Check your connection and try again.'))
    } finally { request.release(); setBusy(false) }
  }
  return <Dialog labelledBy={titleId} busy={busy} onClose={onClose} className="max-w-lg">
    <form noValidate onSubmit={submit}>
      <h2 id={titleId} className="text-lg font-semibold text-neutral-900">{early ? 'Release the reserve early?' : 'Release the reserve'}</h2>
      <p className="mt-1 text-sm text-content-muted [overflow-wrap:anywhere]">{row.event.title} · {row.organization.name}</p>
      <dl className="mt-4 space-y-1 rounded-lg bg-neutral-50 p-3 text-sm ring-1 ring-neutral-200">
        <div className="flex justify-between gap-4"><dt>Reserve held</dt><dd className="font-medium tabular-nums">{money(row.reserve_held_cents, row.currency)}</dd></div>
        <div className="flex justify-between gap-4"><dt>Chargebacks and changes since the payout</dt><dd className="font-medium tabular-nums">{money(Math.min(row.owed_cents, 0), row.currency)}</dd></div>
        <div className="flex justify-between gap-4 border-t border-neutral-200 pt-1 font-semibold"><dt>{remaining < 0 ? 'Organizer will owe' : 'Left to send after release'}</dt><dd className="tabular-nums">{money(Math.abs(remaining), row.currency)}</dd></div>
      </dl>
      {early && <label className="mt-4 block text-sm font-medium text-neutral-900">Reason for releasing before {formatDay(row.reserve_release_on)}
        <textarea rows={3} value={reason} onChange={event => setReason(event.target.value)} maxLength={1000} className="input mt-1" />
      </label>}
      {error && <p role="alert" className="mt-3 rounded-lg bg-red-50 p-3 text-sm text-red-800">{error}</p>}
      <div className="mt-6 flex flex-wrap justify-end gap-3">
        <button type="button" onClick={onClose} disabled={busy} className="btn-secondary">Cancel</button>
        <button type="submit" disabled={busy} className="btn-primary">{busy ? 'Releasing…' : 'Release reserve'}</button>
      </div>
    </form>
  </Dialog>
}

function RowActions({ row, busy, run, setDialog }) {
  const actions = row.actions || []
  const buttons = []
  if (row.next_step === 'complete_event') {
    return <p className="text-xs text-content-muted">Completes automatically 6 hours after the end, or <Link to={`/admin/events?q=${encodeURIComponent(row.event.title)}`} className="font-semibold underline">open the event</Link>.</p>
  }
  if (row.next_step === 'resolve_money') {
    return <p className="text-xs text-amber-900">{row.blocker}. <Link to="/admin/reconciliation_exceptions" className="font-semibold underline">Open reconciliation</Link></p>
  }
  if (actions.includes('record_transfer')) {
    buttons.push(<Link key="record" to={`?event_id=${row.event.id}`} className="btn-primary !px-4 !py-2 text-sm">Record transfer</Link>)
  }
  if (actions.includes('hold_reserve')) buttons.push(<button key="hold" type="button" disabled={busy} onClick={() => setDialog({ kind: 'reserve', row })} className={`${row.next_step === 'hold_reserve' ? 'btn-primary' : 'btn-secondary'} !px-4 !py-2 text-sm`}>Hold {money(row.suggested_reserve_cents, row.currency)} reserve</button>)
  if (actions.includes('finalize_statement')) buttons.push(<button key="finalize" type="button" disabled={busy} onClick={() => run(row, 'finalize')} className={`${row.next_step === 'finalize_statement' ? 'btn-primary' : 'btn-secondary'} !px-4 !py-2 text-sm`}>{row.next_step === 'hold_reserve' ? 'Finalize without reserve' : 'Finalize statement'}</button>)
  if (actions.includes('send_transfer') && row.settlement) buttons.push(<button key="send" type="button" disabled={busy || !row.payout_account_ready} onClick={() => run(row, 'payout')} className="btn-primary !px-4 !py-2 text-sm">Request payout {money(row.settlement.available_to_payout_cents, row.currency)}</button>)
  if (actions.includes('release_reserve')) buttons.push(<button key="release" type="button" disabled={busy} onClick={() => setDialog({ kind: 'release', row })} className={`${row.next_step === 'release_reserve' ? 'btn-primary' : 'btn-ghost'} !px-4 !py-2 text-sm`}>{row.due_state === 'upcoming' ? 'Release early' : 'Release reserve'}</button>)
  return <div className="flex flex-wrap gap-2 md:justify-end">
    {buttons}
    {actions.includes('send_transfer') && !row.payout_account_ready && <p className="w-full text-xs text-red-700">No approved payout method on file.</p>}
  </div>
}

function DueTable({ title, description, rows, empty, busy, run, setDialog }) {
  return <section className="mb-6" aria-label={title}>
    <h2 className="text-base font-semibold text-neutral-900">{title}</h2>
    <p className="mb-3 text-sm text-content-muted">{description}</p>
    <div className="card overflow-hidden">
      {rows.length === 0 ? <p className="px-5 py-8 text-center text-sm text-content-muted">{empty}</p> : (
        <table className={foldTable}>
          <thead><tr className="border-b border-neutral-100 text-left text-content-muted">
            <th scope="col" className="px-3 py-3 font-medium">Event</th><th scope="col" className="px-3 py-3 font-medium">When</th>
            <th scope="col" className="px-3 py-3 text-right font-medium">Amounts</th><th scope="col" className="px-3 py-3 font-medium">Next step</th>
          </tr></thead>
          <tbody>
            {rows.map(row => (
              <tr key={row.event.id} className={foldRow} data-testid={`due-row-${row.event.id}`}>
                <td data-label="Event" className={foldCell}><span className="min-w-0"><span className="block font-medium text-neutral-900 [overflow-wrap:anywhere]">{row.event.title}</span><span className="block text-xs text-content-muted [overflow-wrap:anywhere]">{row.organization.name}</span></span></td>
                <td data-label="When" className={foldCell}><span><span className="block text-xs text-content-muted">Ended {formatDay(row.ended_on)}</span><DueBadge row={row} /></span></td>
                <td data-label="Amounts" className={`${foldCell} md:text-right`}><span className="text-xs tabular-nums text-neutral-700">
                  <span className="block">Net {money(row.net_proceeds_cents, row.currency)}</span>
                  {row.reserve_held_cents > 0 && <span className="block">Reserve {money(row.reserve_held_cents, row.currency)}</span>}
                  {row.paid_cents > 0 && <span className="block">Sent {money(row.paid_cents, row.currency)}</span>}
                  {row.reserve_held_cents > 0 && row.paid_cents > 0
                    ? <span className={`block font-semibold ${row.after_release_cents < 0 ? 'text-red-800' : 'text-neutral-900'}`}>{row.after_release_cents < 0 ? `Owes ${money(-row.after_release_cents, row.currency)} after release` : `To send after release ${money(row.after_release_cents, row.currency)}`}</span>
                    : <span className={`block font-semibold ${row.owed_cents < 0 ? 'text-red-800' : 'text-neutral-900'}`}>{row.owed_cents < 0 ? `Owes ${money(-row.owed_cents, row.currency)}` : `To send ${money(row.owed_cents, row.currency)}`}</span>}
                </span></td>
                <td data-label="Next step" className={foldCell}><span className="min-w-0 space-y-2"><span className="block text-sm font-medium text-neutral-900">{row.next_step_label}</span><RowActions row={row} busy={busy} run={run} setDialog={setDialog} /></span></td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  </section>
}

export default function AdminPayoutDueList({ list, dueOnly, setDueOnly, onNotice }) {
  const [dialog, setDialog] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const data = list.data

  const run = async (row, action) => {
    const request = list.beginRequest()
    if (!request) return
    setBusy(true); setError('')
    try {
      if (action === 'finalize') {
        const response = await apiClient.post(`/admin/payout_schedule/${row.event.id}/finalize`, {}, request.config)
        if (request.current()) onNotice(`Statement version ${response.data.version} finalized for ${row.event.title}.`)
      } else {
        await apiClient.post('/admin/payouts', { settlement_id: row.settlement.id }, { ...request.config, headers: { 'Idempotency-Key': window.crypto.randomUUID() } })
        if (request.current()) onNotice(`Payout of ${money(row.settlement.available_to_payout_cents, row.currency)} requested for ${row.event.title}. Send the bank transfer, then choose Record transfer.`)
      }
      if (request.current()) list.reload()
    } catch (failure) {
      if (request.current() && !request.handleError(failure)) setError(errorMessage(failure, 'That step did not complete. Check your connection and try again.'))
    } finally { request.release(); setBusy(false) }
  }
  const saved = message => { setDialog(null); onNotice(message); list.reload() }

  if (list.loading && !data) return <div className="flex justify-center py-12"><Loader2 aria-label="Loading" className="h-6 w-6 animate-spin text-brand-500" /></div>
  if (list.error && !data) return <div role="alert" className="p-5 text-sm text-red-700">{list.error} <button type="button" onClick={list.reload} className="min-h-11 rounded px-2 font-semibold underline">Try again</button></div>
  const counts = data?.counts || {}
  return <div aria-busy={list.loading}>
    <div className="mb-5 flex flex-col gap-3 rounded-xl border border-neutral-200 bg-white p-4 sm:flex-row sm:items-center sm:justify-between">
      <p className="text-sm text-neutral-700">Standard terms: bank transfer within {data?.rules?.transfer_business_days || '2–3'} business days after the event (Guam time), {data?.rules?.reserve_percent ?? 10}% reserve released after {data?.rules?.reserve_days ?? 30} days.</p>
      <label className="flex min-h-11 shrink-0 items-center gap-2 text-sm font-medium"><input type="checkbox" checked={dueOnly} onChange={event => setDueOnly(event.target.checked)} className="h-4 w-4 accent-brand-700" />Due now only</label>
    </div>
    <div className="mb-5 flex flex-wrap gap-2 text-sm" role="status">
      <span className={`inline-flex items-center gap-1 rounded-full px-3 py-1 font-semibold ring-1 ${DUE_TONE.overdue}`}><AlertTriangle aria-hidden="true" className="h-4 w-4" />{counts.overdue || 0} overdue</span>
      <span className={`inline-flex items-center gap-1 rounded-full px-3 py-1 font-semibold ring-1 ${DUE_TONE.due}`}><Clock aria-hidden="true" className="h-4 w-4" />{counts.due || 0} due</span>
      <span className={`inline-flex items-center gap-1 rounded-full px-3 py-1 font-semibold ring-1 ${DUE_TONE.upcoming}`}><CheckCircle2 aria-hidden="true" className="h-4 w-4" />{counts.upcoming || 0} reserves waiting</span>
    </div>
    {error && <p role="alert" className="mb-4 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">{error}</p>}
    <DueTable title="Bank transfers" description="Events that have ended and still need their transfer prepared, sent or recorded." rows={data?.transfers || []}
      empty="No transfers are due." busy={busy} run={run} setDialog={setDialog} />
    <DueTable title="Reserves" description="Reserves held after the first transfer. Release each one 30 days after its event." rows={data?.reserves || []}
      empty="No reserves are held." busy={busy} run={run} setDialog={setDialog} />
    {dialog?.kind === 'reserve' && <ReserveDialog row={dialog.row} beginRequest={list.beginRequest} onClose={() => setDialog(null)} onSaved={saved} />}
    {dialog?.kind === 'release' && <ReleaseDialog row={dialog.row} beginRequest={list.beginRequest} onClose={() => setDialog(null)} onSaved={saved} />}
  </div>
}
