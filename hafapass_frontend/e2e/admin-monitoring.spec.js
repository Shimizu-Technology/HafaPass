import process from 'node:process'
import { expect, test } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

const json = (route, body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
const shots = process.env.QA_SCREENSHOT_DIR

const monitoring = (overrides = {}, title = 'Copa de Marianas') => ({
  stripe_webhooks: {
    checked_at: '2027-01-05T10:00:00Z', last_receipt_at: '2027-01-05T09:58:00Z', last_processed_at: '2027-01-05T09:58:00Z',
    receipts_last_hour: 12, failed_in_window: 0, stuck_processing: 0, failed_total: 0, paid_without_webhook: 0, unresolved_paid_without_webhook: 0,
    recent_payment_attempts: 3, silent: false, failing: false, unverified_failing: false, rejected_in_window: 0, mode: 'live',
    thresholds: { failure_window_minutes: 15, failure_threshold: 3, silence_minutes: 30, silence_lookback_minutes: 360, silence_min_attempts: 10 },
    ...overrides,
  },
  summary: {
    guam_date: '2027-01-04', window: { partial: false },
    sales: { orders: 20, tickets: 31, gross_cents: 52700, refund_cents: 1200, online: { gross_cents: 50000, orders: 19 }, door_cash: { gross_cents: 2700, orders: 1 } },
    on_sale: [{ event_id: 1, title, max_capacity: 900, capacity_remaining: 212 }],
    health: { readiness: 'ready', job_queue: { available: true, ready: 0 } },
  },
  sentry: { configured: true, sending_enabled: true, environment: 'production' },
  test_alert_kinds: ['stripe_webhooks_silent', 'stripe_webhook_failures', 'checkout', 'webhook', 'scanner', 'sentry_connectivity'],
})

for (const [name, viewport] of [['390', { width: 390, height: 844 }], ['1280', { width: 1280, height: 900 }]]) {
  test(`admin monitoring page works at ${name}px, with worst-case data`, async ({ page }) => {
    await page.setViewportSize(viewport)
    let sent
    const worstTitle = '🏆 コパ・デ・マリアナス '.repeat(6) + 'Supercalifragilisticexpialidocious_unbreakable_event_name_'.repeat(2)
    await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
    await page.route('**/api/v1/admin/monitoring', route => json(route, monitoring({}, worstTitle)))
    await page.route('**/api/v1/admin/monitoring/test_alert', async route => { sent = route.request().postDataJSON(); return json(route, { sent: true }) })

    await page.goto('/admin/monitoring')
    await expect(page.getByText(/Webhooks are arriving and being processed/)).toBeVisible()
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
    if (shots) await page.screenshot({ path: `${shots}/monitoring-${name}-healthy.png`, fullPage: true })

    await page.getByLabel('Alert to test').selectOption('stripe_webhooks_silent')
    await page.getByRole('button', { name: 'Send test alert' }).click()
    await expect(page.getByText(/Sentry accepted the test alert/)).toBeVisible()
    expect(sent).toEqual({ kind: 'stripe_webhooks_silent' })

    const results = await new AxeBuilder({ page }).analyze()
    expect(results.violations.filter(item => ['serious', 'critical'].includes(item.impact))).toEqual([])
  })

  test(`admin monitoring page shows a silent-webhook incident at ${name}px`, async ({ page }) => {
    await page.setViewportSize(viewport)
    await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
    await page.route('**/api/v1/admin/monitoring', route => json(route, monitoring({ silent: true, failing: true, paid_without_webhook: 12345678, failed_in_window: 99999, receipts_last_hour: 0, last_receipt_at: null, last_processed_at: null })))
    await page.goto('/admin/monitoring')
    await expect(page.getByText(/Webhooks look silent while payments are being made/)).toBeVisible()
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
    if (shots) await page.screenshot({ path: `${shots}/monitoring-${name}-incident.png`, fullPage: true })
  })
}
