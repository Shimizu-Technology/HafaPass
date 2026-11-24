import { useRef, useState } from 'react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'
import AdminSessionGate from './AdminSessionGate'
import { usePlatformRequests } from '../../hooks/usePlatformContext'
import { errorMessage, formatDateTime, money, useAdminList } from './adminOperations'

const endpoint = '/admin/monitoring'
const KIND_LABELS = {
  stripe_webhooks_silent: 'Stripe webhooks silent',
  stripe_webhook_failures: 'Stripe webhook failures',
  stripe_unverified_deliveries: 'Unverified deliveries rejected',
  failed_payment_webhooks: 'Failed payment updates',
  open_reconciliation_exceptions: 'Open reconciliation exceptions',
  failed_background_jobs: 'Failed background jobs',
  exhausted_message_deliveries: 'Exhausted email deliveries',
  checkout: 'Checkout error',
  webhook: 'Webhook processing error',
  scanner: 'Scanner error',
  box_office: 'Box-office error',
  sentry_connectivity: 'Sentry connectivity only',
}

function Stat({ label, value, tone }) {
  return <div className="min-w-0 rounded-lg border border-neutral-200 bg-white p-3">
    <dt className="text-xs text-neutral-600">{label}</dt>
    <dd className={`mt-1 text-lg font-semibold [overflow-wrap:anywhere] ${tone === 'bad' ? 'text-red-800' : 'text-neutral-900'}`}>{value}</dd>
  </div>
}

function WebhookHealth({ health }) {
  const bad = health.silent || health.failing || health.unverified_failing
  return <section aria-labelledby="webhook-health-heading" className="mb-6">
    <h2 id="webhook-health-heading" className="text-lg font-semibold text-neutral-900">Stripe webhooks{health.mode ? ` (${health.mode} mode)` : ''}</h2>
    <p role="status" className={`mt-2 rounded-lg border p-3 text-sm ${bad ? 'border-red-200 bg-red-50 text-red-900' : 'border-emerald-200 bg-emerald-50 text-emerald-900'}`}>
      {health.unverified_failing ? "Unverified deliveries are being rejected (bad signature) while payments are not being confirmed. If these are real Stripe deliveries, the signing secret on the server does not match the Stripe webhook destination. Rejected senders can't be identified, so check Stripe's failed deliveries."
        : health.silent ? 'Webhooks look silent while payments are being made. Open the first-three-actions list in the incident runbook.'
          : health.failing ? 'Webhook processing is failing. Compare Stripe\'s failed deliveries with the receipts here.'
          : 'Webhooks are arriving and being processed. Quiet periods with no buyers are expected and not an alert.'}
    </p>
    <dl className="mt-3 grid grid-cols-2 gap-2 lg:grid-cols-4">
      <Stat label="Last received" value={health.last_receipt_at ? formatDateTime(health.last_receipt_at) : 'Never'} />
      <Stat label="Last processed" value={health.last_processed_at ? formatDateTime(health.last_processed_at) : 'Never'} />
      <Stat label="Received, last hour" value={health.receipts_last_hour} />
      <Stat label={`Failed, last ${health.thresholds.failure_window_minutes} min`} value={health.failed_in_window + health.stuck_processing} tone={health.failing ? 'bad' : undefined} />
      <Stat label="Paid, no webhook yet" value={health.paid_without_webhook} tone={health.silent ? 'bad' : undefined} />
      <Stat label={`Payments started, last ${health.thresholds.silence_minutes} min`} value={health.recent_payment_attempts} />
      <Stat label="Failed receipts standing" value={health.failed_total} />
      <Stat label={`Unverified rejected, last ${health.thresholds.failure_window_minutes} min`} value={health.rejected_in_window ?? 0} tone={health.unverified_failing ? 'bad' : undefined} />
    </dl>
  </section>
}

function SummaryPanel({ summary }) {
  const { sales, health } = summary
  return <section aria-labelledby="summary-heading" className="mb-6">
    <h2 id="summary-heading" className="text-lg font-semibold text-neutral-900">Sales, {summary.guam_date} (Guam){summary.window.partial ? ' so far' : ''}</h2>
    <dl className="mt-3 grid grid-cols-2 gap-2 lg:grid-cols-4">
      <Stat label="Orders" value={sales.orders} />
      <Stat label="Tickets" value={sales.tickets} />
      <Stat label="Gross" value={money(sales.gross_cents)} />
      <Stat label="Refunds" value={money(sales.refund_cents)} />
      <Stat label="Online" value={`${money(sales.online.gross_cents)} · ${sales.online.orders}`} />
      <Stat label="Door cash" value={`${money(sales.door_cash.gross_cents)} · ${sales.door_cash.orders}`} />
      <Stat label="Readiness" value={String(health.readiness).replaceAll('_', ' ')} tone={health.readiness === 'ready' ? undefined : 'bad'} />
      <Stat label="Waiting jobs" value={health.job_queue.available ? health.job_queue.ready : 'n/a'} />
    </dl>
    {summary.on_sale.length > 0 && <ul className="mt-3 space-y-1 text-sm text-neutral-800">
      {summary.on_sale.map(event => <li key={event.event_id} className="[overflow-wrap:anywhere]">
        <strong>{event.title}</strong>: {event.capacity_remaining === null ? 'no capacity cap' : `${event.capacity_remaining} of ${event.max_capacity} left`}
      </li>)}
    </ul>}
    <p className="mt-3 max-w-3xl text-sm text-neutral-700">The morning brief reads this same summary from <code>/api/v1/ops/summary</code> with its own token. Errors and spikes are in the Sentry app.</p>
  </section>
}

function TestAlert({ identity, kinds }) {
  const { beginRequest } = usePlatformRequests(identity, endpoint)
  const busyRef = useRef(false)
  const [kind, setKind] = useState('sentry_connectivity')
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState(null)

  const send = async () => {
    if (busyRef.current) return
    const request = beginRequest()
    if (!request) return
    busyRef.current = true; setBusy(true); setResult(null)
    try {
      await apiClient.post(`${endpoint}/test_alert`, { kind }, request.config)
      if (request.current()) setResult({ ok: true, text: 'Sentry accepted the test alert. Check your phone in a minute or two.' })
    } catch (failure) {
      if (request.handleError(failure)) return
      if (request.current()) setResult({ ok: false, text: errorMessage(failure, 'The test alert could not be sent.') })
    } finally {
      request.release(); busyRef.current = false
      if (request.current()) setBusy(false)
    }
  }

  return <section aria-labelledby="test-alert-heading">
    <h2 id="test-alert-heading" className="text-lg font-semibold text-neutral-900">Send a test alert</h2>
    <p className="mt-2 max-w-3xl text-sm text-neutral-700">Sends one event marked <strong>[TEST]</strong> to Sentry, tagged like the real alert, so you can confirm the rule reaches your phone. Nothing is wrong and no real alert state changes. Steps are in docs/MONITORING_SETUP.md.</p>
    <div className="mt-3 flex flex-col gap-2 sm:flex-row sm:items-end">
      <label className="block text-sm font-medium text-neutral-800 sm:w-80">Alert to test
        <select className="input mt-1 min-h-11" value={kind} onChange={event => setKind(event.target.value)} disabled={busy}>
          {kinds.map(item => <option key={item} value={item}>{KIND_LABELS[item] || item}</option>)}
        </select>
      </label>
      <button type="button" className="btn-primary min-h-11" disabled={busy} onClick={send}>{busy ? 'Sending…' : 'Send test alert'}</button>
    </div>
    {result && <p role={result.ok ? 'status' : 'alert'} className={`mt-3 text-sm ${result.ok ? 'text-emerald-900' : 'text-red-800'}`}>{result.text}</p>}
  </section>
}

function MonitoringSession({ identity, resourcePath }) {
  const list = useAdminList(identity, resourcePath, endpoint, {})
  const data = list.data
  return <AdminLayout>
    <p className="mb-4 max-w-3xl text-sm text-neutral-700">What reaches your phone, and whether it is working. This page only reads, apart from the test alert.</p>
    <div className="mb-5 flex flex-wrap items-center justify-between gap-3">
      <p role="status" className="text-sm text-neutral-700">{list.loading ? 'Loading monitoring…' : data ? `Checked ${formatDateTime(data.stripe_webhooks.checked_at)}.` : 'Monitoring unavailable.'}</p>
      <button type="button" className="btn-secondary min-h-11" disabled={list.loading} onClick={list.reload}>Refresh monitoring</button>
    </div>
    {list.error && <div role="alert" className="mb-5 rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-900">
      Monitoring could not be loaded.
      <button type="button" className="ml-2 inline-flex min-h-11 items-center font-semibold underline" onClick={list.reload}>Try again</button>
    </div>}
    {data && <>
      {!data.sentry.configured && <p role="alert" className="mb-5 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950">Sentry is not configured on this server (SENTRY_DSN), so no alert can reach your phone.</p>}
      {data.sentry.configured && data.sentry.sending_enabled === false && <p role="alert" className="mb-5 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950">Sentry has a DSN here but is switched off for this environment ({data.sentry.environment}). Add it to SENTRY_ENABLED_ENVIRONMENTS, or no alert will be sent.</p>}
      <WebhookHealth health={data.stripe_webhooks} />
      <SummaryPanel summary={data.summary} />
      <TestAlert identity={identity} kinds={data.test_alert_kinds} />
    </>}
  </AdminLayout>
}

export default function AdminMonitoringPage() {
  return <AdminSessionGate resourcePath={endpoint} Session={MonitoringSession} />
}
