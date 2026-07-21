import { expect, test } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

const json = (route, body, status = 200) => route.fulfill({
  status, contentType: 'application/json', body: JSON.stringify(body),
})

test('admin records complete Gate F device, accessibility, and load evidence', async ({ page }) => {
  let submitted
  const event = {
    id: 42, title: 'Guam Community Night', slug: 'guam-community-night', status: 'draft', category: 'festival',
    is_featured: false, starts_at: '2026-09-21T08:00:00Z', tickets_sold: 0, revenue_cents: 0,
    organizer_name: 'Island Community Group', pilot_readiness: { approval_recorded: true },
    pilot_validation: { approval_recorded: false, pending_submission: null },
  }
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/admin/events?*', route => json(route, {
    events: [event], meta: { page: 1, per_page: 20, total: 1, total_pages: 1 },
  }))
  await page.route('**/api/v1/admin/events/42/pilot_validation', route => json(route, {
    event, pilot_validation: { prerequisite_ready: true, approved: false, pending_submission: null, latest_approval: null },
  }))
  await page.route('**/api/v1/admin/events/42/pilot_validation_reviews', async route => {
    submitted = route.request().postDataJSON()
    return json(route, { id: 91, decision: 'submission' }, 201)
  })

  await page.goto('/admin/events')
  await page.getByRole('button', { name: 'Prepare Gate F evidence' }).click()
  await page.getByLabel('Restricted evidence reference').fill('private-qa/gate-f/guam-community-night')
  await page.getByLabel('Evidence SHA-256').fill('b'.repeat(64))

  for (const label of ['iOS Safari', 'Android Chrome', 'Desktop Chrome']) {
    await page.getByLabel(`${label} Device/model`).fill(`${label} test device`)
    await page.getByLabel(`${label} OS version`).fill('current')
    await page.getByLabel(`${label} Browser version`).fill('current')
    await page.getByLabel(`${label} Private tester reference`).fill(`private-qa/testers/${label}`)
    await page.getByLabel(`${label} Evidence reference`).fill(`private-qa/devices/${label}`)
  }
  for (const label of ['Desktop Safari', 'Desktop Firefox', 'Desktop Edge']) {
    await page.getByLabel(`${label} unavailable reason`).fill('Not in the documented pilot device pool')
  }
  for (const label of ['iOS VoiceOver', 'Android TalkBack', 'Desktop screen reader']) {
    await page.getByLabel(`${label} Device/platform`).fill(`${label} platform`)
    await page.getByLabel(`${label} AT version`).fill('current')
    await page.getByLabel(`${label} Private tester reference`).fill(`private-qa/at-testers/${label}`)
    await page.getByLabel(`${label} Evidence reference`).fill(`private-qa/at/${label}`)
  }
  await page.getByLabel('Qualified reviewer name').fill('Qualified Reviewer')
  await page.getByLabel('Qualification reference').fill('private-qa/qualifications/reviewer')
  await page.getByLabel('Sign-off evidence reference').fill('private-qa/signoff/accessibility')

  const textFields = [
    ['Scenario name', 'Expected pilot onsale'], ['Load tool and version', 'k6 1.0'],
    ['Isolated target environment', 'production-like candidate'],
  ]
  for (const [label, value] of textFields) await page.getByLabel(label).fill(value)
  const numericFields = [
    ['Expected concurrent buyers', '50'], ['Executed concurrent buyers', '60'], ['Request count', '1000'],
    ['Duration (seconds)', '300'], ['Observed p95 (ms)', '650'], ['p95 budget (ms)', '1500'],
    ['Observed error rate (%)', '0.2'], ['Error-rate budget (%)', '1'], ['Peak database connections', '12'],
    ['Database connection limit', '20'], ['Inventory contention attempts', '100'],
    ['Expected hold expirations', '10'], ['Observed hold expirations', '10'],
  ]
  for (const [label, value] of numericFields) await page.getByLabel(label).fill(value)
  for (const checkbox of await page.getByRole('checkbox').all()) {
    if (!(await checkbox.isChecked())) await checkbox.check()
  }

  const submit = page.getByRole('button', { name: 'Submit Gate F evidence' })
  await expect(submit).toBeEnabled()
  const accessibility = await new AxeBuilder({ page }).analyze()
  expect(accessibility.violations.filter(item => ['serious', 'critical'].includes(item.impact))).toEqual([])
  const response = page.waitForResponse(item => item.url().includes('/pilot_validation_reviews') && item.request().method() === 'POST')
  await submit.click()
  await response

  expect(submitted.device_matrix.ios_safari.physical_device).toBe(true)
  expect(submitted.accessibility_results.checks.no_medical_proof_request).toBe(true)
  expect(submitted.load_results).toMatchObject({ expected_concurrent_buyers: 50, oversell_count: 0 })
})
