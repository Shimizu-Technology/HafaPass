import { useCallback, useEffect, useRef, useState } from 'react'
import { useParams, useSearchParams } from 'react-router-dom'
import { AlertTriangle, CheckCircle2, Clock, Download, Landmark, Loader2, Printer, ShieldCheck } from 'lucide-react'
import apiClient from '../../api/client'
import { BackLink, PageHeader, WorkspacePage } from '../../components/WorkspacePage'
import NoAccessNotice from '../../components/NoAccessNotice'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import { formatMoneyCents } from '../../utils/money'
import { saveBlob } from '../../utils/download'
import { formatDay, signedMoney, statusSummary } from '../../utils/payoutStatement'

// Organizer-facing payout statement for one event (and optionally one
// payout). Every amount comes from the API, which builds the lines from the
// same settlement records finance uses; this page only formats them.

const STATUS_STYLE = {
  sales_open: { icon: Clock, tone: 'bg-neutral-100 text-neutral-800 ring-neutral-200' },
  waiting_for_payout: { icon: Clock, tone: 'bg-amber-50 text-amber-950 ring-amber-200' },
  reserve_held: { icon: ShieldCheck, tone: 'bg-brand-50 text-brand-900 ring-brand-200' },
  final: { icon: CheckCircle2, tone: 'bg-emerald-50 text-emerald-900 ring-emerald-200' },
}

export default function PayoutStatementPage() {
  const { id: eventId } = useParams()
  const path = `/dashboard/events/${eventId}/statement`
  const identity = useOrganizerIdentity()
  const visit = useOrganizerPageVisit(path)
  if (!visit.active) return null
  if (!identity.ready) return <p role="status" className="p-6">Preparing your account…</p>
  return <PayoutStatementSession key={`${identity.accountKey}:${identity.organizationId}:${eventId}:${visit.generation}`} eventId={eventId} path={path} identity={identity} />
}

function PayoutStatementSession({ eventId, path, identity }) {
  const [searchParams] = useSearchParams()
  const payoutId = searchParams.get('payout') || ''
  const { current, beginRequest } = useOrganizerRequests(identity, path)
  const [state, setState] = useState({ status: 'loading', data: null, error: null })
  const [exporting, setExporting] = useState(false)
  const [exportError, setExportError] = useState('')
  const loadRequest = useRef(null)
  const query = payoutId ? `?payout_id=${encodeURIComponent(payoutId)}` : ''

  const load = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    loadRequest.current?.controller.abort()
    loadRequest.current = request
    const applies = () => request.current() && loadRequest.current === request
    setState(previous => ({ status: previous.data ? 'refreshing' : 'loading', data: previous.data, error: null }))
    try {
      const response = await apiClient.get(`/organizer/events/${eventId}/finance/payout_statement${query}`, request.config)
      if (applies()) setState({ status: 'ready', data: response.data, error: null })
    } catch (error) {
      if (!applies() || error?.name === 'AbortError' || error?.name === 'CanceledError') return
      const status = error.response?.status
      setState({ status: 'error', data: null, error: status === 403 ? 'denied' : status === 404 ? 'missing' : status === 401 ? 'signed-out' : 'failed' })
    } finally { request.release() }
  }, [beginRequest, eventId, query])
  useEffect(() => { load() }, [load])

  const download = async () => {
    if (exporting) return
    const request = beginRequest()
    if (!request) return
    setExporting(true); setExportError('')
    try {
      const response = await apiClient.get(`/organizer/events/${eventId}/finance/payout_statement_export${query}`, { ...request.config, responseType: 'blob' })
      if (request.current()) saveBlob(response.data, `${state.data?.event?.slug || `event-${eventId}`}-payout-statement.csv`)
    } catch (error) {
      if (request.current() && error?.name !== 'AbortError' && error?.name !== 'CanceledError') {
        setExportError(error.response?.status === 403 ? 'Your role no longer includes finances.' : 'The CSV could not be downloaded. Check your connection and try again.')
      }
    } finally {
      request.release()
      if (current()) setExporting(false)
    }
  }

  const data = state.data
  const back = <BackLink to={`/dashboard/events/${eventId}/analytics#settlement`} data-print="hide">Back to event finances</BackLink>
  const actions = data && (
    <div className="flex flex-wrap gap-2" data-print="hide">
      <button type="button" onClick={() => window.print()} className="btn-secondary gap-2 !px-4 !py-2.5 text-sm"><Printer aria-hidden="true" className="h-4 w-4" /> Print</button>
      <button type="button" onClick={download} disabled={exporting} className="btn-secondary gap-2 !px-4 !py-2.5 text-sm">
        {exporting ? <Loader2 aria-hidden="true" className="h-4 w-4 animate-spin" /> : <Download aria-hidden="true" className="h-4 w-4" />} Download CSV
      </button>
    </div>
  )

  if (state.status === 'loading') {
    return <WorkspacePage width="form"><PageHeader back={back} title="Payout statement" />
      <div aria-busy="true"><p role="status" className="sr-only">Loading statement…</p><div className="h-40 animate-pulse rounded-2xl bg-neutral-100 motion-reduce:animate-none" /></div>
    </WorkspacePage>
  }
  if (state.status === 'error') {
    return <WorkspacePage width="form"><PageHeader back={back} title="Payout statement" />
      {state.error === 'denied'
        ? <NoAccessNotice title="Finances aren’t part of your role" detail="Owners, managers and finance members can see payout statements." />
        : <div role="alert" className="rounded-2xl border border-neutral-200 bg-white p-6 text-sm text-neutral-700">
          <p>{state.error === 'missing' ? 'This statement or payout was not found.' : state.error === 'signed-out' ? 'Please sign in again to see this statement.' : 'The statement could not be loaded. Check your connection and try again.'}</p>
          {state.error === 'failed' && <button type="button" onClick={load} className="btn-secondary mt-4 !px-4 !py-2.5 text-sm">Try again</button>}
        </div>}
    </WorkspacePage>
  }

  const currency = data.currency || 'USD'
  const money = cents => formatMoneyCents(cents, currency)
  const style = STATUS_STYLE[data.status] || STATUS_STYLE.sales_open
  const StatusIcon = style.icon
  const { totals } = data
  return (
    <WorkspacePage width="form" id="payout-statement" data-testid="payout-statement">
      <PageHeader back={back} title="Payout statement" actions={actions}
        description={<span className="break-words [overflow-wrap:anywhere]"><span className="font-semibold text-neutral-800">{data.event.title}</span> · {data.organization.name}</span>} />

      <section aria-labelledby="statement-status" className={`rounded-2xl p-5 ring-1 ${style.tone}`}>
        <h2 id="statement-status" className="flex items-center gap-2 text-lg font-semibold" data-testid="statement-status"><StatusIcon aria-hidden="true" className="h-5 w-5 shrink-0" />{data.status_label}</h2>
        <p className="mt-1 text-sm">{statusSummary(data)}</p>
      </section>

      {!data.reconciles && <p role="alert" className="mt-4 rounded-xl border border-red-300 bg-red-50 p-3 text-sm text-red-900">These lines do not add up to the totals (off by {money(data.difference_cents)}). HåfaPass finance has been asked to check this statement; please contact us before relying on it.</p>}

      <dl className="mt-5 grid grid-cols-1 gap-3 sm:grid-cols-3">
        <Figure label="Net proceeds" value={signedMoney(totals.net_proceeds_cents, currency)} detail="After refunds, card processing and door cash" />
        <Figure label="Sent to you" value={money(totals.transferred_cents)} detail={totals.in_progress_cents > 0 ? `${money(totals.in_progress_cents)} on the way` : totals.reserve_held_cents > 0 ? `${money(totals.reserve_held_cents)} held in reserve` : null} />
        <Figure label={totals.still_to_come_cents < 0 ? 'You owe' : 'Still to come'} value={money(Math.abs(totals.still_to_come_cents))} highlight
          detail={totals.still_to_come_cents < 0 ? 'Taken from your next payout' : totals.reserve_held_cents > 0 ? `Includes the ${money(totals.reserve_held_cents)} reserve, due ${formatDay(data.schedule.reserve_release_on)}` : null} />
      </dl>

      {data.payout && <PayoutReceipt payout={data.payout} money={money} />}

      <section aria-labelledby="by-ticket" className="mt-6 rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6">
        <h2 id="by-ticket" className="text-base font-semibold text-neutral-950">Sales by ticket</h2>
        {data.sales_by_ticket.length === 0 ? <p className="mt-2 text-sm text-neutral-600">No tickets sold yet.</p> : (
          <table className="mt-3 w-full text-sm">
            <thead><tr className="text-left text-xs text-neutral-600"><th scope="col" className="pb-2 font-medium">Ticket</th><th scope="col" className="pb-2 text-right font-medium">Sold</th><th scope="col" className="pb-2 text-right font-medium">Amount</th></tr></thead>
            <tbody className="divide-y divide-neutral-100">
              {data.sales_by_ticket.map(row => (
                <tr key={row.name}><td className="py-2 pr-3 break-words [overflow-wrap:anywhere]">{row.name}</td><td className="py-2 text-right tabular-nums">{row.quantity.toLocaleString('en-US')}</td><td className="py-2 pl-3 text-right font-medium tabular-nums">{money(row.gross_cents)}</td></tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      <section aria-labelledby="statement-lines" className="mt-6 rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6">
        <h2 id="statement-lines" className="text-base font-semibold text-neutral-950">How your payout adds up</h2>
        {data.sections.map(section => (
          <div key={section.key} className="mt-4 break-inside-avoid">
            <h3 className="text-xs font-semibold uppercase tracking-wide text-neutral-500">{section.title}</h3>
            {section.lines.length === 0 && <p className="py-2 text-sm text-neutral-600">{section.key === 'reserve' ? 'No reserve held.' : 'None.'}</p>}
            <dl className="mt-1">
              {section.lines.map((line, index) => <Line key={`${line.label}-${index}`} label={line.label} note={line.note} value={signedMoney(line.amount_cents, currency)} />)}
              <Line label={section.total_label} value={signedMoney(section.total_cents, currency)} strong />
            </dl>
          </div>
        ))}
        <div className="mt-4 break-inside-avoid">
          <h3 className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Transfers to your bank</h3>
          {data.transfers.length === 0 && <p className="py-2 text-sm text-neutral-600">No transfers yet.</p>}
          <dl className="mt-1">
            {data.transfers.map(transfer => (
              <Line key={transfer.id} label={transferLabel(transfer)} note={transferNote(transfer, money)}
                value={transfer.counted_cents === 0 ? money(0) : signedMoney(transfer.counted_cents, currency)} />
            ))}
            {(data.closing?.lines || []).map(line => <Line key={line.label} label={line.label} note={line.note} value={signedMoney(line.amount_cents, currency)} />)}
            <Line label={data.closing?.total_label || (totals.still_to_come_cents < 0 ? 'You owe' : 'Still to come')} value={signedMoney(data.closing?.total_cents ?? totals.still_to_come_cents, currency)} strong testId="balance-remaining" />
          </dl>
        </div>
      </section>

      {data.notes.length > 0 && <section aria-labelledby="statement-notes" className="mt-6 rounded-2xl bg-neutral-50 p-5 text-sm text-neutral-700 sm:p-6">
        <h2 id="statement-notes" className="font-semibold text-neutral-900">Good to know</h2>
        <ul className="mt-2 list-disc space-y-1 pl-5">{data.notes.map(note => <li key={note}>{note}</li>)}</ul>
      </section>}
      {exportError && <p role="alert" className="mt-4 rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-700">{exportError}</p>}
      <p className="mt-6 text-xs text-neutral-500">Prepared {new Intl.DateTimeFormat('en-US', { dateStyle: 'medium', timeStyle: 'short', timeZone: data.event.timezone || 'Pacific/Guam' }).format(new Date(data.generated_at))} ({data.event.timezone || 'Pacific/Guam'} time). Amounts in {currency}. Bank account numbers are never shown in full.</p>
    </WorkspacePage>
  )
}

function transferLabel(transfer) {
  const method = transfer.method === 'check' ? 'Check' : 'Bank transfer'
  return transfer.bank_last4 ? `${method} to account ending ${transfer.bank_last4}` : method
}

function transferNote(transfer, money) {
  const parts = [transfer.status_label]
  if (transfer.sent_on) parts.push(formatDay(transfer.sent_on))
  else if (transfer.requested_on) parts.push(`requested ${formatDay(transfer.requested_on)}`)
  if (transfer.reference) parts.push(`Ref ${transfer.reference}`)
  if (transfer.withheld_cents > 0) parts.push(`${money(transfer.withheld_cents)} withheld for taxes; ${money(transfer.sent_cents)} sent`)
  if (transfer.status === 'reversed') parts.push('Returned by the bank; not counted')
  return parts.join(' · ')
}

function Figure({ label, value, detail, highlight = false }) {
  return (
    <div className={`rounded-xl p-4 ${highlight ? 'bg-brand-50 text-brand-950' : 'bg-white ring-1 ring-neutral-200'}`}>
      <dt className="text-xs font-medium text-neutral-600">{label}</dt>
      <dd className="mt-1 text-xl font-bold tabular-nums break-words">{value}</dd>
      {detail && <dd className="mt-0.5 text-xs text-neutral-600">{detail}</dd>}
    </div>
  )
}

function Line({ label, note, value, strong = false, testId }) {
  return (
    <div className={`flex items-baseline justify-between gap-4 py-2 ${strong ? 'border-t border-neutral-200 font-semibold text-neutral-950' : 'text-neutral-800'}`} data-testid={testId}>
      <dt className="min-w-0 break-words text-sm [overflow-wrap:anywhere]">{label}{note && <span className="block text-xs font-normal text-neutral-600">{note}</span>}</dt>
      <dd className="shrink-0 text-sm tabular-nums">{value}</dd>
    </div>
  )
}

function PayoutReceipt({ payout, money }) {
  const version = payout.version
  return (
    <section aria-labelledby="payout-receipt" className="mt-6 rounded-2xl border border-brand-200 bg-white p-5 sm:p-6" data-testid="payout-receipt">
      <h2 id="payout-receipt" className="flex items-center gap-2 text-base font-semibold text-neutral-950"><Landmark aria-hidden="true" className="h-5 w-5 text-brand-700" />This transfer</h2>
      <dl className="mt-2">
        <Line label="Amount" value={money(payout.sent_cents)} note={payout.withheld_cents > 0 ? `${money(payout.amount_cents)} less ${money(payout.withheld_cents)} withheld for taxes` : null} strong />
        <Line label="Status" value={payout.status_label} />
        {payout.sent_on && <Line label="Sent" value={formatDay(payout.sent_on)} />}
        {payout.bank_last4 && <Line label="To account ending" value={payout.bank_last4} />}
        {payout.reference && <Line label="Bank reference" value={<span className="break-all font-mono">{payout.reference}</span>} />}
      </dl>
      {version && <p className="mt-3 text-sm text-neutral-700">Paid from statement version {version.version}: net proceeds {money(version.net_proceeds_cents)}, reserve held {money(version.reserve_held_cents)}, earlier transfers {money(version.previously_sent_cents)}.</p>}
    </section>
  )
}
