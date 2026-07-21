import { expect, test } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

const json = (route, body, status = 200) => route.fulfill({
  status, contentType: 'application/json', body: JSON.stringify(body),
})

test('admin records named Gate E ownership and complete event-bound evidence', async ({ page }) => {
  let submitted
  const event = {
    id: 42,
    title: 'Guam Community Night',
    slug: 'guam-community-night',
    status: 'draft',
    category: 'festival',
    is_featured: false,
    starts_at: '2026-09-21T08:00:00Z',
    tickets_sold: 0,
    revenue_cents: 0,
    organizer_name: 'Island Community Group',
    organizer_email: 'organizer@example.com',
    pilot_readiness: { required: true, approved: false, state_current: false, pending_submission: null },
  }

  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/admin/events?*', route => json(route, {
    events: [event], meta: { page: 1, per_page: 20, total: 1, total_pages: 1 },
  }))
  await page.route('**/api/v1/admin/events/42/pilot_readiness', route => json(route, {
    event,
    pilot_readiness: {
      required: true,
      approved: false,
      state_current: false,
      pending_submission: null,
      latest_approval: null,
    },
  }))
  await page.route('**/api/v1/admin/events/42/pilot_readiness_reviews', async route => {
    submitted = route.request().postDataJSON()
    return json(route, { id: 91, decision: 'submission' }, 201)
  })

  await page.goto('/admin/events')
  await page.getByRole('button', { name: 'Prepare pilot readiness' }).click()
  await page.getByLabel('Restricted evidence reference').fill('private/pilot/guam-community-night')
  await page.getByLabel(/^Evidence SHA-256/).fill('a'.repeat(64))

  const owners = [
    ['Primary on-call', 'Leon Shimizu', 'directory/primary'],
    ['Backup on-call', 'Backup Engineer', 'directory/backup'],
    ['Event commander', 'Event Commander', 'directory/commander'],
    ['Door lead', 'Door Lead', 'directory/door'],
    ['Finance contact', 'Finance Lead', 'directory/finance'],
    ['Venue safety contact', 'Venue Safety', 'directory/safety'],
  ]
  for (const [label, name, reference] of owners) {
    await page.getByLabel(`${label} name`).fill(name)
    await page.getByLabel(`${label} private contact reference`).fill(reference)
  }
  for (const checkbox of await page.getByRole('checkbox').all()) await checkbox.check()

  const submit = page.getByRole('button', { name: 'Submit readiness' })
  await expect(submit).toBeEnabled()
  const results = await new AxeBuilder({ page }).analyze()
  expect(results.violations.filter(violation => ['serious', 'critical'].includes(violation.impact))).toEqual([])

  const submissionResponse = page.waitForResponse(response =>
    response.url().includes('/api/v1/admin/events/42/pilot_readiness_reviews') &&
      response.request().method() === 'POST')
  await submit.click()
  await submissionResponse

  expect(submitted.evidence_digest).toBe('a'.repeat(64))
  expect(submitted.assignments.event_commander).toEqual({
    name: 'Event Commander', contact_reference: 'directory/commander',
  })
  expect(Object.values(submitted.controls).every(Boolean)).toBe(true)
})
