import { expect, test } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

const json = (route, body, status = 200) => route.fulfill({
  status, contentType: 'application/json', body: JSON.stringify(body),
})

test('admin requests a bounded hidden Gate H live-money authorization', async ({ page }) => {
  let submitted
  const event = {
    id: 42, title: '[LIVE MONEY TEST] Guam finance proof', slug: 'live-money-proof', status: 'draft',
    category: 'other', is_featured: false, starts_at: '2026-09-21T08:00:00Z', tickets_sold: 0,
    revenue_cents: 0, organizer_name: 'HafaPass Finance', live_money_proof_candidate: true,
    pilot_readiness: { approval_recorded: true }, pilot_validation: { approval_recorded: true },
    event_day_rehearsal: { approval_recorded: true }, live_money_proof: { approval_recorded: false },
  }
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/admin/events?*', route => json(route, {
    events: [event], meta: { page: 1, per_page: 20, total: 1, total_pages: 1 },
  }))
  await page.route('**/api/v1/admin/events/42/live_money_proof', route => json(route, {
    event, authorization: null, live_money_proof: { prerequisite_ready: true, approved: false },
  }))
  await page.route('**/api/v1/admin/events/42/live_money_proof_authorizations', async route => {
    submitted = route.request().postDataJSON()
    return json(route, { id: 88, requested_by_user_id: 7, max_amount_cents: submitted.max_amount_cents }, 201)
  })

  await page.goto('/admin/events')
  await page.getByRole('button', { name: 'Prepare Gate H live-money proof' }).click()
  await page.getByLabel('Proof buyer email').fill('finance-proof@example.com')
  await page.getByLabel('Maximum total cents').fill('400')

  const accessibility = await new AxeBuilder({ page }).analyze()
  expect(accessibility.violations.filter(item => ['serious', 'critical'].includes(item.impact))).toEqual([])
  const response = page.waitForResponse(item => item.url().includes('/live_money_proof_authorizations') && item.request().method() === 'POST')
  await page.getByRole('button', { name: 'Request proof authorization' }).click()
  await response

  expect(submitted).toMatchObject({ buyer_email: 'finance-proof@example.com', max_amount_cents: 400 })
  expect(new Date(submitted.expires_at).getTime()).toBeGreaterThan(Date.now())
})
