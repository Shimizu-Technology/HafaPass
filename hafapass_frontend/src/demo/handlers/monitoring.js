// Demo data for Admin → Monitoring & alerts. Fictional only; nothing is sent.
import { json, unprocessable } from './respond'

const MINUTE = 60 * 1000
const KINDS = ['stripe_webhooks_silent', 'stripe_webhook_failures', 'checkout', 'webhook', 'scanner', 'box_office', 'sentry_connectivity']

function build(now) {
  const iso = offset => new Date(now - offset * MINUTE).toISOString()
  return {
    stripe_webhooks: {
      checked_at: iso(0), last_receipt_at: iso(4), last_processed_at: iso(4), receipts_last_hour: 18,
      failed_in_window: 0, stuck_processing: 0, failed_total: 0, paid_without_webhook: 0, recent_payment_attempts: 6,
      silent: false, failing: false,
      thresholds: { failure_window_minutes: 15, failure_threshold: 3, silence_minutes: 30, silence_lookback_minutes: 360, silence_min_attempts: 10 },
    },
    summary: {
      guam_date: new Date(now).toISOString().slice(0, 10), window: { partial: true },
      sales: { orders: 24, tickets: 41, gross_cents: 68900, refund_cents: 1700,
        online: { gross_cents: 64400, orders: 22 }, door_cash: { gross_cents: 4500, orders: 2 } },
      on_sale: [{ event_id: 101, title: 'Isla Demo Open (demo)', max_capacity: 900, capacity_remaining: 212 }],
      health: { readiness: 'ready', job_queue: { available: true, ready: 0 } },
    },
    sentry: { configured: true, environment: 'demo' },
    test_alert_kinds: KINDS,
  }
}

export async function handle({ method, path, body, state, serverNow }) {
  if (path === '/admin/monitoring' && method === 'get') {
    return json(build(Date.parse(serverNow) || Date.now()))
  }
  if (path === '/admin/monitoring/test_alert' && method === 'post') {
    if (!KINDS.includes(body?.kind)) return unprocessable('Unknown alert kind')
    state.monitoring = state.monitoring || { testAlertsSent: 0 }
    state.monitoring.testAlertsSent += 1
    return json({ sent: true, kind: body.kind, demo: true })
  }
  return undefined
}
