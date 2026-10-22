import { useCallback, useEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { AlertTriangle, CheckCircle2, Circle, Clock, Download, Loader2, RotateCcw, WalletCards, XCircle } from 'lucide-react'
import apiClient from '../../api/client'
import { BackLink, PageHeader, WorkspacePage } from '../../components/WorkspacePage'
import NoAccessNotice from '../../components/NoAccessNotice'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import usePlatformFeeTerms from '../../hooks/usePlatformFeeTerms'
import { formatEventDate } from '../../utils/eventTime'
import { formatMoneyCents } from '../../utils/money'
import { saveBlob } from '../../utils/download'

const PATH = '/dashboard/finances'
const plural = (count, word) => `${count} ${word}${count === 1 ? '' : 's'}`

const TONES = {
  neutral: 'bg-neutral-100 text-neutral-700',
  good: 'bg-emerald-50 text-emerald-800',
  warning: 'bg-amber-50 text-amber-900',
  action: 'bg-brand-50 text-brand-800',
  critical: 'bg-red-50 text-red-800',
}

function Badge({ tone = 'neutral', icon: Icon = Circle, children }) {
  return (
    <span className={`inline-flex items-center gap-1 whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-semibold ${TONES[tone]}`}>
      <Icon aria-hidden="true" className="h-3.5 w-3.5 shrink-0" />{children}
    </span>
  )
}

function StatementBadge({ row }) {
  const version = row.settlement?.version
  if (row.settlement_state === 'finalized') return <Badge tone="good" icon={CheckCircle2}>Finalized v{version}</Badge>
  if (row.settlement_state === 'changed') return <Badge tone="warning" icon={AlertTriangle}>Changed since v{version}</Badge>
  return <Badge>Not finalized</Badge>
}

function PayoutStateBadge({ state }) {
  switch (state) {
    case 'ready': return <Badge tone="action" icon={WalletCards}>Ready to request</Badge>
    case 'in_progress': return <Badge tone="warning" icon={Clock}>Payout in progress</Badge>
    case 'on_hold': return <Badge tone="warning" icon={Clock}>On hold — event cancelled, refunds in progress</Badge>
    case 'paid': return <Badge tone="good" icon={CheckCircle2}>Paid</Badge>
    case 'needs_new_version': return <Badge tone="warning" icon={AlertTriangle}>Finalize new version</Badge>
    case 'awaiting_statement': return <Badge icon={Clock}>Waiting for statement</Badge>
    default: return <Badge>Nothing owed</Badge>
  }
}

function PayoutStatusBadge({ status }) {
  if (status === 'held') return <Badge tone="warning" icon={Clock}>On hold — event cancelled, refunds in progress</Badge>
  if (status === 'paid') return <Badge tone="good" icon={CheckCircle2}>Paid</Badge>
  if (status === 'failed') return <Badge tone="critical" icon={XCircle}>Failed</Badge>
  if (status === 'reversed') return <Badge tone="critical" icon={RotateCcw}>Reversed</Badge>
  return <Badge tone="warning" icon={Clock}>In progress</Badge>
}

function Line({ label, value, detail, strong = false, sign = '' }) {
  return (
    <div className={`flex items-baseline justify-between gap-4 py-2.5 ${strong ? 'border-t border-neutral-200 font-semibold text-neutral-950' : 'text-neutral-700'}`}>
      <dt className="min-w-0">{label}{detail && <span className="block text-xs font-normal text-neutral-600">{detail}</span>}</dt>
      <dd className="shrink-0 tabular-nums">{sign}{value}</dd>
    </div>
  )
}

function processingNotes(bearers = {}, feeTerms) {
  const notes = []
  if (feeTerms?.bearer === 'platform') notes.push('Under current terms, HåfaPass pays card processing on tickets out of its service fee. Add-ons and donations still carry their share.')
  if (feeTerms?.bearer === 'organizer') notes.push('Under current terms, card processing comes out of your proceeds.')
  if (bearers.platform > 0) notes.push(`${plural(bearers.platform, 'order')} had card processing on tickets covered by HåfaPass.`)
  if (bearers.organizer > 0) notes.push(`${plural(bearers.organizer, 'order')} had card processing taken from your proceeds under the terms in place when they were bought.`)
  if (bearers.legacy > 0) notes.push(`${plural(bearers.legacy, 'older order')} ${bearers.legacy === 1 ? 'was' : 'were'} placed under earlier terms, when card processing was deducted from organizer proceeds.`)
  return notes
}

export default function FinancesPage() {
  const identity = useOrganizerIdentity()
  const visit = useOrganizerPageVisit(PATH)
  if (!visit.active) return null
  if (!identity.ready) return <p role="status" className="p-6">Preparing your account…</p>
  return <FinancesSession key={`${identity.accountKey}:${identity.organizationId}:${visit.generation}`} identity={identity} />
}

function FinancesSession({ identity }) {
  const { current, beginRequest } = useOrganizerRequests(identity, PATH)
  const [state, setState] = useState({ status: 'loading', data: null, error: null })
  const [exporting, setExporting] = useState(null)
  const [exportError, setExportError] = useState(null)
  const feeTerms = usePlatformFeeTerms()
  const loadRequest = useRef(null)

  const load = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    loadRequest.current?.controller.abort()
    loadRequest.current = request
    const applies = () => request.current() && loadRequest.current === request
    setState(previous => ({ status: previous.data ? 'refreshing' : 'loading', data: previous.data, error: null }))
    try {
      const response = await apiClient.get('/organizer/finances', request.config)
      if (applies()) setState({ status: 'ready', data: response.data, error: null })
    } catch (error) {
      if (!applies() || error?.name === 'AbortError' || error?.name === 'CanceledError') return
      const status = error.response?.status
      setState({ status: 'error', data: null, error: status === 403 ? 'denied' : status === 401 ? 'signed-out' : 'failed' })
    } finally { request.release() }
  }, [beginRequest])
  useEffect(() => { load() }, [load])

  const download = async (kind, path, filename) => {
    if (exporting) return
    const request = beginRequest()
    if (!request) return
    setExporting(kind); setExportError(null)
    try {
      const response = await apiClient.get(path, { ...request.config, responseType: 'blob' })
      if (request.current()) saveBlob(response.data, filename)
    } catch (error) {
      if (request.current() && error?.name !== 'AbortError' && error?.name !== 'CanceledError') {
        setExportError(error.response?.status === 403 ? 'Your role no longer includes finance exports.' : 'That export could not be downloaded. Check your connection and try again.')
      }
    } finally {
      request.release()
      if (current()) setExporting(null)
    }
  }

  const header = actions => (
    <PageHeader
      back={<BackLink />}
      title="Finances"
      description={state.data?.organization?.name ? `Sales, fees and payouts across every ${state.data.organization.name} event.` : 'Sales, fees and payouts across all your events.'}
      actions={actions}
    />
  )

  if (state.status === 'loading') {
    return (
      <WorkspacePage>
        {header(null)}
        <div aria-busy="true">
          <p role="status" className="sr-only">Loading finances…</p>
          <div className="h-36 animate-pulse rounded-2xl bg-neutral-100 motion-reduce:animate-none" />
          <div className="mt-6 grid gap-6 lg:grid-cols-3">
            <div className="h-72 animate-pulse rounded-2xl bg-neutral-100 motion-reduce:animate-none lg:col-span-2" />
            <div className="h-72 animate-pulse rounded-2xl bg-neutral-100 motion-reduce:animate-none" />
          </div>
        </div>
      </WorkspacePage>
    )
  }

  if (state.status === 'error' && state.error === 'denied') {
    return (
      <WorkspacePage>
        {header(null)}
        <NoAccessNotice title="Finances aren’t part of your role" detail="Your role in this organization does not include finances. Owners, managers and finance members can see this page." />
      </WorkspacePage>
    )
  }

  if (state.status === 'error') {
    const message = state.error === 'signed-out' ? 'Please sign in again to see your finances.'
      : 'Finances could not be loaded. Check your connection and try again.'
    return (
      <WorkspacePage>
        {header(null)}
        <div role="alert" className="rounded-2xl border border-neutral-200 bg-white p-6 text-sm text-neutral-700">
          <p>{message}</p>
          {state.error === 'failed' && <button type="button" onClick={load} className="btn-secondary mt-4 !px-4 !py-2.5 text-sm">Try again</button>}
        </div>
      </WorkspacePage>
    )
  }

  const data = state.data
  const totals = data.totals || {}
  const currency = (data.currency || 'usd').toUpperCase()
  const money = cents => formatMoneyCents(cents, currency)
  const timezone = data.organization?.timezone || undefined
  const events = data.events || []
  const payouts = data.payouts || []
  const slug = data.organization?.slug || 'organization'
  const breakdown = data.breakdown || {}
  const today = new Date().toISOString().slice(0, 10)
  const signed = cents => ({ value: money(Math.abs(cents || 0)), sign: cents < 0 ? '−' : '' })
  const adjustment = breakdown.adjustment_cents || 0
  const payoutTiming = feeTerms.terms?.payoutScheduleText
  const notes = processingNotes(data.processing_fee_bearers, feeTerms.terms)
  const heldCents = Math.max(0, events.reduce((sum, row) => sum + (row.requestable_cents || 0), 0) - (totals.requestable_cents || 0))

  const exportButtons = (
    <div className="grid w-full grid-cols-2 gap-2 sm:flex sm:w-auto">
      <button type="button" disabled={Boolean(exporting)} onClick={() => download('orders', '/organizer/finances/orders_export', `${slug}-orders-${today}.csv`)} className="btn-secondary gap-2 whitespace-nowrap !px-4 !py-2.5 text-sm">
        {exporting === 'orders' ? <Loader2 aria-hidden="true" className="h-4 w-4 animate-spin" /> : <Download aria-hidden="true" className="h-4 w-4" />} Orders CSV
      </button>
      <button type="button" disabled={Boolean(exporting)} onClick={() => download('payouts', '/organizer/finances/payouts_export', `${slug}-payouts-${today}.csv`)} className="btn-secondary gap-2 whitespace-nowrap !px-4 !py-2.5 text-sm">
        {exporting === 'payouts' ? <Loader2 aria-hidden="true" className="h-4 w-4 animate-spin" /> : <Download aria-hidden="true" className="h-4 w-4" />} Payouts CSV
      </button>
    </div>
  )

  return (
    <WorkspacePage>
      {header(exportButtons)}
      {exportError && <p role="alert" className="-mt-4 mb-6 rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-700">{exportError}</p>}

      <div className={`transition-opacity duration-150 ease-out-strong ${state.status === 'refreshing' ? 'opacity-60' : ''}`} aria-busy={state.status === 'refreshing'}>
        <section aria-labelledby="owed-heading" className="rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6">
          <h2 id="owed-heading" className="text-sm font-medium text-neutral-600">Still owed to you</h2>
          <p className="mt-1 text-5xl font-bold tracking-tight text-neutral-950">{money(breakdown.owed_cents)}</p>
          <ul className="mt-3 space-y-1 text-sm text-neutral-700">
            <li>{totals.requestable_cents > 0 ? `${money(totals.requestable_cents)} can be requested now from finalized statements.` : 'Nothing can be requested right now. Payouts open once an event’s statement is finalized and any refunds, disputes or payment checks are settled.'}</li>
            {heldCents > 0 && <li>{money(heldCents)} from finalized statements is on hold until open refunds, disputes or payment checks are settled.</li>}
            {totals.in_flight_cents > 0 && <li>{money(totals.in_flight_cents)} is on its way in a payout that has been requested.</li>}
            {totals.held_cents > 0 && <li>{money(totals.held_cents)} is on hold — event cancelled, refunds in progress.</li>}
            {payoutTiming && <li>Payout timing: {payoutTiming}.</li>}
          </ul>
          {breakdown.negative_balance_cents > 0 && (
            <p className="mt-4 flex items-start gap-2 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
              <AlertTriangle aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" />
              <span>A negative balance of {money(breakdown.negative_balance_cents)} carries forward. It is withheld from future payouts until it is covered, for example after refunds that were paid out earlier.</span>
            </p>
          )}
        </section>

        <div className="mt-6 grid min-w-0 gap-6 lg:grid-cols-3">
          <section aria-labelledby="breakdown-heading" className="min-w-0 rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6 lg:col-span-2">
            <h2 id="breakdown-heading" className="text-lg font-semibold text-neutral-900">How the total adds up</h2>
            <p className="mt-1 text-sm text-neutral-600">All events with sales, refunds or payouts. Amounts update as orders, refunds and payouts are recorded.</p>
            <dl className="mt-4 text-sm" data-testid="finance-breakdown">
              <Line label="Sales" value={money(breakdown.sales_cents)} detail="Tickets and add-ons at their listed prices" />
              {breakdown.discount_cents > 0 && <Line label="Discounts" value={money(breakdown.discount_cents)} sign="−" />}
              {breakdown.absorbed_fee_cents !== 0 && <Line label="Service fees you covered" {...signed(-breakdown.absorbed_fee_cents)} detail="Your share of the HåfaPass fee on events where you cover some or all of it" />}
              {breakdown.refunded_proceeds_cents > 0 && <Line label="Refunded from your proceeds" value={money(breakdown.refunded_proceeds_cents)} sign="−" />}
              <Line label="Your proceeds" value={money(breakdown.proceeds_cents)} strong />
              <Line label="Card processing you paid" value={money(breakdown.processing_fee_cents)} sign="−" />
              {breakdown.door_cash_retained_cents > 0 && <Line label="Door cash you already kept" value={money(breakdown.door_cash_retained_cents)} sign="−" detail="Cash sales stay with you, so they are not paid out again" />}
              {breakdown.reserve_cents > 0 && <Line label="Reserves held" value={money(breakdown.reserve_cents)} sign="−" />}
              {adjustment !== 0 && <Line label="Adjustments and disputes" value={money(Math.abs(adjustment))} sign={adjustment < 0 ? '−' : '+'} />}
              <Line label="Earned for payout" {...signed(breakdown.earned_cents)} strong />
              <Line label="Paid out" value={money(breakdown.paid_cents)} sign="−" />
              {breakdown.in_flight_cents > 0 && <Line label="Payouts in progress" value={money(breakdown.in_flight_cents)} sign="−" />}
              {breakdown.held_cents > 0 && <Line label="On hold — event cancelled, refunds in progress" value={money(breakdown.held_cents)} sign="−" />}
              <Line label={breakdown.balance_cents < 0 ? 'Negative balance carried forward' : 'Still owed to you'} {...signed(breakdown.balance_cents)} strong />
            </dl>
            <ul className="mt-4 space-y-1 border-t border-neutral-100 pt-4 text-xs text-neutral-600">
              <li>Buyers also paid {money(breakdown.buyer_fee_cents)} in service fees to HåfaPass. Those are not part of your proceeds.</li>
              {breakdown.refunded_to_buyers_cents > 0 && <li>{money(breakdown.refunded_to_buyers_cents)} was refunded to buyers in total, including any fees and tax refunded with tickets.</li>}
              {breakdown.platform_processing_fee_cents > 0 && <li>HåfaPass paid {money(breakdown.platform_processing_fee_cents)} of card processing on your tickets.</li>}
            </ul>
            {data.orders_without_items_count > 0 && (
              <p className="mt-4 flex items-start gap-2 rounded-xl border border-neutral-200 bg-neutral-50 p-3 text-sm text-neutral-700">
                <Circle aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-neutral-500" />
                <span>{plural(data.orders_without_items_count, 'older order')} {data.orders_without_items_count === 1 ? 'is' : 'are'} not included in statements because {data.orders_without_items_count === 1 ? 'it has' : 'they have'} no ticket details on record. Contact support if you need {data.orders_without_items_count === 1 ? 'it' : 'them'} added.</span>
              </p>
            )}
          </section>

          <section aria-labelledby="explain-heading" className="min-w-0 rounded-2xl border border-neutral-200 bg-neutral-50 p-5 sm:p-6">
            <h2 id="explain-heading" className="text-lg font-semibold text-neutral-900">What the statuses mean</h2>
            <dl className="mt-3 space-y-3 text-sm text-neutral-700">
              <div><dt className="font-semibold text-neutral-900">Not finalized</dt><dd>Sales are still being counted. After the event ends, an owner or finance member finalizes its statement.</dd></div>
              <div><dt className="font-semibold text-neutral-900">Finalized</dt><dd>The statement is approved and locked. If a refund or adjustment happens later, it shows as changed and a new version is needed. Earlier versions never change.</dd></div>
              <div><dt className="font-semibold text-neutral-900">Finalize new version</dt><dd>Money is still owed, but a refund, adjustment or the last payout came after the latest version. Finalize a new version on the event page to request the rest.</dd></div>
              <div><dt className="font-semibold text-neutral-900">Payout in progress</dt><dd>A payout was requested. Requesting does not mean the money has arrived yet.</dd></div>
              <div><dt className="font-semibold text-neutral-900">Paid</dt><dd>The payout provider confirmed the transfer.</dd></div>
            </dl>
            {notes.length > 0 && (
              <div className="mt-4 border-t border-neutral-200 pt-4">
                <h3 className="text-sm font-semibold text-neutral-900">Card processing</h3>
                <ul className="mt-2 space-y-1.5 text-sm text-neutral-700">{notes.map(note => <li key={note}>{note}</li>)}</ul>
              </div>
            )}
          </section>
        </div>

        <section aria-labelledby="events-heading" className="mt-6 min-w-0 rounded-2xl border border-neutral-200 bg-white">
          <div className="px-5 pt-5 sm:px-6">
            <h2 id="events-heading" className="text-lg font-semibold text-neutral-900">By event</h2>
            <p className="mt-1 text-sm text-neutral-600">Open an event to finalize its statement, request a payout or download its statement.</p>
          </div>
          {events.length === 0 ? (
            <p className="m-5 rounded-xl bg-neutral-50 px-4 py-8 text-center text-sm text-neutral-600 sm:m-6">No sales yet. Totals appear here once an event sells its first ticket.</p>
          ) : (
            <>
              <div className="mt-4 hidden overflow-x-auto md:block">
                <table className="w-full text-sm">
                  <thead className="bg-neutral-50 text-xs text-neutral-600">
                    <tr>
                      <th scope="col" className="px-6 py-3 text-left font-medium">Event</th>
                      <th scope="col" className="px-3 py-3 text-right font-medium">Your proceeds</th>
                      <th scope="col" className="px-3 py-3 text-right font-medium">Paid out</th>
                      <th scope="col" className="px-3 py-3 text-right font-medium">Still owed</th>
                      <th scope="col" className="px-3 py-3 text-left font-medium">Statement</th>
                      <th scope="col" className="px-6 py-3 text-left font-medium">Payout</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-neutral-100">
                    {events.map(row => (
                      <tr key={row.id} className="align-top">
                        <td className="max-w-xs px-6 py-3">
                          <Link to={`/dashboard/events/${row.id}/analytics#settlement`} className="font-semibold text-neutral-950 underline-offset-2 hover:text-brand-800 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus">{row.title}</Link>
                          <p className="text-xs capitalize text-neutral-600">{formatEventDate(row.starts_at, row.timezone || undefined)} · {row.status}</p>
                        </td>
                        <td className="px-3 py-3 text-right tabular-nums">{money(row.organizer_proceeds_cents)}</td>
                        <td className="px-3 py-3 text-right tabular-nums">{money(row.paid_cents)}</td>
                        <td className="px-3 py-3 text-right font-semibold tabular-nums text-neutral-950">{money(row.owed_cents)}</td>
                        <td className="px-3 py-3"><StatementBadge row={row} /></td>
                        <td className="px-6 py-3"><PayoutStateBadge state={row.payout_state} />{row.negative_balance_cents > 0 && <p className="mt-1 text-xs text-amber-900">Negative balance {money(row.negative_balance_cents)}</p>}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              <ul className="mt-4 divide-y divide-neutral-100 border-t border-neutral-100 md:hidden">
                {events.map(row => (
                  <li key={row.id}>
                    <Link to={`/dashboard/events/${row.id}/analytics#settlement`} className="block px-5 py-4 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-focus active:bg-neutral-50">
                      <div className="flex items-start justify-between gap-3">
                        <div className="min-w-0">
                          <p className="break-words font-semibold text-neutral-950">{row.title}</p>
                          <p className="text-xs capitalize text-neutral-600">{formatEventDate(row.starts_at, row.timezone || undefined)} · {row.status}</p>
                        </div>
                        <div className="shrink-0 text-right">
                          <p className="font-semibold tabular-nums text-neutral-950">{money(row.owed_cents)}</p>
                          <p className="text-xs text-neutral-600">still owed</p>
                        </div>
                      </div>
                      <p className="mt-2 text-xs text-neutral-600 tabular-nums">Proceeds {money(row.organizer_proceeds_cents)} · Paid {money(row.paid_cents)}</p>
                      <div className="mt-2 flex flex-wrap gap-1.5"><StatementBadge row={row} /><PayoutStateBadge state={row.payout_state} /></div>
                    </Link>
                  </li>
                ))}
              </ul>
            </>
          )}
        </section>

        <section aria-labelledby="payouts-heading" className="mt-6 min-w-0 rounded-2xl border border-neutral-200 bg-white">
          <div className="px-5 pt-5 sm:px-6">
            <h2 id="payouts-heading" className="text-lg font-semibold text-neutral-900">Payout history</h2>
            <p className="mt-1 text-sm text-neutral-600">{data.payouts_count > payouts.length ? `Showing the latest ${payouts.length} of ${data.payouts_count}. Download Payouts CSV for the full history.` : 'Every payout requested for this organization.'}</p>
          </div>
          {payouts.length === 0 ? (
            <p className="m-5 rounded-xl bg-neutral-50 px-4 py-8 text-center text-sm text-neutral-600 sm:m-6">No payouts yet.</p>
          ) : (
            <ul className="mt-4 divide-y divide-neutral-100 border-t border-neutral-100">
              {payouts.map(payout => (
                <li key={payout.id} className="flex flex-col gap-2 px-5 py-4 sm:flex-row sm:items-center sm:justify-between sm:px-6">
                  <div className="min-w-0">
                    <p className="break-words font-medium text-neutral-950">{payout.event_title}</p>
                    <p className="text-xs text-neutral-600">
                      {formatEventDate(payout.paid_at || payout.initiated_at || payout.created_at, timezone)} · Statement v{payout.settlement_version}
                      {payout.provider_payout_id && <> · Ref <span className="break-all font-mono">{payout.provider_payout_id}</span></>}
                    </p>
                    {payout.status === 'failed' && payout.failure_message && <p className="mt-1 text-xs text-red-800">{payout.failure_message}</p>}
                  </div>
                  <div className="flex shrink-0 items-center gap-3 sm:justify-end">
                    <PayoutStatusBadge status={payout.status} />
                    <span className="font-semibold tabular-nums text-neutral-950">{money(payout.amount_cents)}</span>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
    </WorkspacePage>
  )
}
