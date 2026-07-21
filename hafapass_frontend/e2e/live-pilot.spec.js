import { expect, test } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

const json = (route, body, status = 200) => route.fulfill({
  status, contentType: 'application/json', body: JSON.stringify(body),
})

test('admin monitors an active Gate I pilot and reports a mandatory-pause incident', async ({ page }) => {
  let checkpointPayload; let incidentPayload
  const event = {
    id: 42, title: 'Guam Community Night', slug: 'guam-community-night', status: 'published',
    category: 'festival', is_featured: false, starts_at: '2026-09-21T08:00:00Z',
    ends_at: '2026-09-21T12:00:00Z', tickets_sold: 3, revenue_cents: 9000,
    organizer_name: 'Island Community Group', live_money_proof_candidate: false,
    pilot_readiness: { approval_recorded: true }, pilot_validation: { approval_recorded: true },
    event_day_rehearsal: { approval_recorded: true }, live_money_proof: { approval_recorded: true },
    live_pilot: { approval_recorded: true, run_status: 'active' },
  }
  const run = {
    id: 91, status: 'active', inventory_cap: 50, committed_ticket_quantity: 3,
    started_at: '2026-09-20T08:00:00Z', incidents: [], latest_metric_snapshot: null,
  }
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/admin/events?*', route => json(route, {
    events: [event], meta: { page: 1, per_page: 20, total: 1, total_pages: 1 },
  }))
  await page.route('**/api/v1/admin/events/42/live_pilot', route => json(route, {
    event, live_pilot: { prerequisite_ready: true, approved: true, latest_run: run },
  }))
  await page.route('**/api/v1/admin/live_pilot_runs/91/checkpoint', async route => {
    checkpointPayload = route.request().postDataJSON()
    return json(route, { id: 101, breached_thresholds: {} }, 201)
  })
  await page.route('**/api/v1/admin/live_pilot_runs/91/incidents', async route => {
    incidentPayload = route.request().postDataJSON()
    return json(route, { id: 102, pause_required: true }, 201)
  })

  await page.goto('/admin/events')
  await page.getByRole('button', { name: 'Gate I pilot · active' }).click()
  await page.getByLabel('Checkpoint evidence reference').fill('restricted-pilot/checkpoints/91')
  await page.getByLabel('Evidence SHA-256').first().fill('a'.repeat(64))
  await page.getByLabel('Provider status reference').fill('provider-status/healthy')
  await page.getByLabel('Checkout p95 (ms)').fill('425')
  await page.getByLabel('Scanner sync lag (seconds)').fill('9')

  const accessibility = await new AxeBuilder({ page }).analyze()
  expect(accessibility.violations.filter(item => ['serious', 'critical'].includes(item.impact))).toEqual([])
  const checkpointResponse = page.waitForResponse(item => item.url().endsWith('/checkpoint') && item.request().method() === 'POST')
  const checkpointReload = page.waitForResponse(item => item.url().endsWith('/events/42/live_pilot') && item.request().method() === 'GET')
  await page.getByRole('button', { name: 'Record checkpoint' }).click()
  await Promise.all([checkpointResponse, checkpointReload])

  expect(checkpointPayload.external_metrics).toMatchObject({
    provider_healthy: true, checkout_p95_ms: 425, scanner_sync_lag_seconds: 9,
    support_coverage_confirmed: true, guam_communications_current: true,
  })

  await page.getByRole('button', { name: 'Gate I pilot · active' }).click()
  await page.getByLabel('Incident severity').waitFor()
  await page.getByLabel('Incident severity').selectOption('p1')
  await page.getByLabel('Incident category').selectOption('uncertain_payment')
  await page.getByLabel('Summary').fill('Provider returned an uncertain charge result; no blind retry was made')
  await page.getByLabel('Evidence reference', { exact: true }).fill('restricted-pilot/incidents/uncertain-payment')
  await page.getByLabel('Evidence SHA-256').nth(1).fill('b'.repeat(64))
  const incidentResponse = page.waitForResponse(item => item.url().endsWith('/incidents') && item.request().method() === 'POST')
  await page.getByRole('button', { name: 'Report incident' }).click()
  await incidentResponse

  expect(incidentPayload).toMatchObject({ severity: 'p1', category: 'uncertain_payment' })
})
