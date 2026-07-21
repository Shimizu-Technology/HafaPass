import { expect, test } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

const json = (route, body, status = 200) => route.fulfill({
  status, contentType: 'application/json', body: JSON.stringify(body),
})

test('admin records complete Gate G physical event-day rehearsal evidence', async ({ page }) => {
  let submitted
  const event = {
    id: 42, title: 'Guam Community Night', slug: 'guam-community-night', status: 'draft', category: 'festival',
    is_featured: false, starts_at: '2026-09-21T08:00:00Z', tickets_sold: 0, revenue_cents: 0,
    organizer_name: 'Island Community Group', pilot_readiness: { approval_recorded: true },
    pilot_validation: { approval_recorded: true }, event_day_rehearsal: { approval_recorded: false },
  }
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/admin/events?*', route => json(route, {
    events: [event], meta: { page: 1, per_page: 20, total: 1, total_pages: 1 },
  }))
  await page.route('**/api/v1/admin/events/42/event_day_rehearsal', route => json(route, {
    event, event_day_rehearsal: { prerequisite_ready: true, approved: false, pending_submission: null, latest_approval: null },
  }))
  await page.route('**/api/v1/admin/events/42/event_day_rehearsal_reviews', async route => {
    submitted = route.request().postDataJSON()
    return json(route, { id: 101, decision: 'submission' }, 201)
  })

  await page.goto('/admin/events')
  await page.getByRole('button', { name: 'Prepare Gate G rehearsal' }).click()
  await page.getByLabel('Restricted evidence reference').fill('private-rehearsal/gate-g/42')
  await page.getByLabel('Evidence SHA-256').fill('c'.repeat(64))
  await page.getByLabel('Controlled rehearsal event/reference').fill('isolated-rehearsal/42')
  await page.getByLabel('Manifest version').fill('3')
  await page.getByLabel('Manifest SHA-256').fill('d'.repeat(64))
  await page.getByLabel('Signing key ID').fill('pilot-signing-key')
  await page.getByLabel('Signed-manifest evidence reference').fill('private-rehearsal/manifest')
  await page.getByLabel('Emergency door-list reference').fill('private-rehearsal/door-list')
  await page.getByLabel('Emergency list SHA-256').fill('e'.repeat(64))

  const deviceTextFields = ['Device identifier', 'Physical model', 'OS version', 'Browser', 'Browser version',
    'Private tester reference', 'Evidence reference', 'Battery plan reference', 'Spare device reference']
  for (const index of [1, 2, 3]) {
    for (const field of deviceTextFields) await page.getByLabel(`Device ${index} ${field}`, { exact: true }).fill(`${field} ${index}`)
    await page.getByLabel(`Device ${index} Queued before sync`).fill('3')
    await page.getByLabel(`Device ${index} Conflicts observed`).fill(index === 1 ? '1' : '0')
    await page.getByLabel(`Device ${index} Offline feedback p95 (ms)`).fill('45')
  }

  const incidentLabels = ['Payment-provider outage', 'Venue internet loss', 'Worker failure',
    'Severe application error', 'Evacuation and sales pause', 'Refund incident', 'Support escalation']
  for (const label of incidentLabels) {
    await page.getByLabel(`${label} Evidence reference`).fill(`private-rehearsal/incidents/${label}`)
    await page.getByLabel(`${label} Alert acknowledgement reference`).fill(`private-rehearsal/alerts/${label}`)
    await page.getByLabel(`${label} Resolution reference`).fill(`private-rehearsal/resolutions/${label}`)
  }
  await page.getByLabel('Cash disablement reason').fill('Cash is disabled for the controlled pilot')
  await page.getByLabel('Cash signed disablement decision reference').fill('private-rehearsal/door-sales/cash-disabled')
  await page.getByLabel('Approved card-present disablement reason').fill('Card-present is disabled for the controlled pilot')
  await page.getByLabel('Approved card-present signed disablement decision reference').fill('private-rehearsal/door-sales/card-disabled')
  await page.getByLabel('Online scan p95 (ms)').fill('180')
  await page.getByLabel('Offline feedback p95 (ms)', { exact: true }).fill('48')

  const assignmentLabels = ['Event commander', 'Technical lead', 'Door lead', 'Finance contact',
    'Venue safety contact', 'Support escalation owner']
  for (const label of assignmentLabels) {
    await page.getByLabel(`${label} Name`).fill(`${label} Name`)
    await page.getByLabel(`${label} Private contact reference`).fill(`private-directory/${label}`)
    await page.getByLabel(`${label} Acknowledgement reference`).fill(`private-rehearsal/acks/${label}`)
  }
  for (const checkbox of await page.getByRole('checkbox').all()) {
    if (!(await checkbox.isChecked())) await checkbox.check()
  }

  const submit = page.getByRole('button', { name: 'Submit Gate G rehearsal' })
  await expect(submit).toBeEnabled()
  const accessibility = await new AxeBuilder({ page }).analyze()
  expect(accessibility.violations.filter(item => ['serious', 'critical'].includes(item.impact))).toEqual([])
  const response = page.waitForResponse(item => item.url().includes('/event_day_rehearsal_reviews') && item.request().method() === 'POST')
  await submit.click()
  await response

  expect(submitted.device_results).toHaveLength(3)
  expect(submitted.device_results.every(device => device.physical_device)).toBe(true)
  expect(submitted.scan_results.same_ticket_cross_device).toBe(true)
  expect(submitted.incident_drills.venue_network_loss.status).toBe('passed')
  expect(submitted.reconciliation_results).toMatchObject({ generated_ticket_count: 500, pending_queue_count: 0 })
})
