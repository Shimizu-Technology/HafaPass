import { expect, test } from '@playwright/test'

function json(route, body, status = 200) {
  return route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
}

test.beforeEach(async ({ page }) => {
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
})

test('owner can review team roles, choose check payouts, and create an invitation', async ({ page }) => {
  await page.route('**/api/v1/organizer/organization', route => json(route, {
    id: 7, name: 'Island Events', role: 'owner', payout_ready: false, timezone: 'Pacific/Guam'
  }))
  await page.route('**/api/v1/organizer/memberships', route => {
    if (route.request().method() === 'POST') return json(route, {
      id: 2, email: 'finance@example.com', role: 'finance', status: 'invited', invitation_status: 'pending', invitation_token: 'browser-signed-token'
    }, 201)
    return json(route, [{ id: 1, email: 'owner@example.com', name: 'Island Owner', role: 'owner', status: 'active', invitation_status: 'accepted' }])
  })
  await page.route('**/api/v1/organizer/connected_accounts', route => json(route, []))

  await page.goto('/dashboard/settings')

  await expect(page.getByRole('heading', { name: 'Island Events' })).toBeVisible()
  const payouts = page.getByRole('region', { name: 'How you get paid' })
  await expect(payouts.getByRole('radio', { name: /Check/ })).toBeChecked()
  await expect(payouts.getByLabel('Pay to (name on the check)')).toBeVisible()
  const team = page.getByRole('region', { name: 'Organization team' })
  await team.getByLabel('Teammate email').fill('finance@example.com')
  await team.getByRole('radio', { name: /Finance/ }).check()
  await team.getByRole('button', { name: 'Invite', exact: true }).click()
  await expect(team.getByText('Invitation sent to finance@example.com as Finance.')).toBeVisible()
  await expect(team.getByRole('textbox', { name: 'Invitation link' })).toHaveValue(/browser-signed-token/)
})

test('finance dashboard separates ticket economics and immutable payout state', async ({ page }) => {
  let requested = false
  let requests = 0
  await page.route('**/api/v1/organizer/events/42/finance/payout', route => { requested = true; requests += 1; return json(route, { id: 31, status: 'processing' }) })
  await page.route('**/api/v1/organizer/events/42/stats', route => json(route, {
    total_tickets_sold: 1,
    total_revenue_cents: 5250,
    tickets_checked_in: 0,
    tickets_by_type: [{ name: 'General Admission', sold: 1, available: 9, revenue_cents: 5000 }],
    recent_orders: []
  }))
  await page.route('**/api/v1/organizer/events/42/finance', route => json(route, {
    preview: {
      gross_cents: 5000, refund_cents: 0, processing_fee_cents: 183,
      payable_cents: 4817, negative_balance_cents: 0
    },
    settlements: [{ id: 9, version: 1, status: 'finalized', available_to_payout_cents: requested ? 0 : 4817 }],
    payouts: requested ? [{ id: 31, provider: 'manual', status: 'processing', amount_cents: 4817 }] : [],
    connected_account: { provider: 'paypal', payout_ready: true }
  }))
  await page.route('**/api/v1/organizer/events/42', route => json(route, {
    id: 42, organization_id: 1, permissions: { view_finance: true, manage_finance: true, payout: true, view_attendees: true }, title: 'Guam Night Market', status: 'completed'
  }))

  await page.goto('/dashboard/events/42/analytics')

  await expect(page.getByRole('heading', { name: 'Settlement and payout' })).toBeVisible()
  await expect(page.getByText('$48.17').first()).toBeVisible()
  await expect(page.getByText('paypal ready')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Request payout $48.17' })).toBeEnabled()
  await page.setViewportSize({ width: 390, height: 844 })
  page.once('dialog', async dialog => {
    expect(dialog.message()).toContain('not confirmation that money has been sent')
    await dialog.accept()
  })
  await page.getByRole('button', { name: 'Request payout $48.17' }).click()
  await expect(page.getByRole('status').filter({ hasText: 'Payout requested.' })).toContainText('Processing does not confirm that money has been sent.')
  await expect(page.getByText('manual · processing')).toBeVisible()
  await page.reload()
  await expect(page.getByText('manual · processing')).toBeVisible()
  await expect(page.getByRole('button', { name: /^Request payout/ })).toHaveCount(0)
  expect(requests).toBe(1)

})
