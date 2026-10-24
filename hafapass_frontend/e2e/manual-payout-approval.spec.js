import { test, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

const json = (route, data, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(data) })
const accountFixture = () => ({ id: 11, provider: 'check', organization_id: 7,
  organization_name: 'IslandEvents'.repeat(12), owner_email: `${'organizer'.repeat(12)}@example.test`, status: 'onboarding', payout_ready: false,
  payout_details: { payee_name: 'Island Events LLC', delivery_method: 'mail', mailing_address: 'PO Box 1, Hagåtña GU 96910', bank_name: 'Island Bank', account_holder_name: 'IslandEvents'.repeat(12), masked_account: '••••1234', account_number: 'NEVER_RENDER_BANK_NUMBER' },
  tax_information: { w9_on_file: true, legal_name: 'IslandEvents'.repeat(12), business_name: 'Island Events', tax_classification: 'llc_c', certified_at: '2026-10-23T00:00:00Z', masked_tin: '***-**-5678', tin: 'NEVER_RENDER_TIN' },
  payout_review: { manual: true, status: 'waiting', missing: [], can_approve: true, review_state_digest: 'current-digest', note: null, review_by: null } })
const dashboard = account => ({ total_events: {}, total_users: {}, total_revenue_cents: 0, total_tickets_sold: 0, recent_events: [], recent_orders: [], organizers_awaiting_verification: [], verified_organizers: [], payout_setups_awaiting_approval: { count: account.payout_ready ? 0 : 1, items: account.payout_ready ? [] : [account] } })
async function base(page) {
  // Same no-Clerk, mocked API setup as verification-gate.spec.js / organization-finance.spec.js.
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await page.route('**/api/v1/**', route => json(route, {}))
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { launch_capabilities: {}, payment_mode: 'simulate' }))
}
async function accessible(page, width) {
  const result = await new AxeBuilder({ page }).analyze()
  expect(result.violations.filter(item => ['serious', 'critical'].includes(item.impact))).toEqual([])
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
}
for (const width of [375, 1280]) {
  test(`dashboard approval: keyboard, retry, masked values and saved outcome at ${width}`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 }); await base(page)
    const account = accountFixture(); let attempts = 0; let payload
    await page.route('**/api/v1/admin/dashboard', route => json(route, dashboard(account)))
    await page.route('**/api/v1/admin/connected_accounts/11/approve_payout_method', route => {
      attempts += 1; payload = route.request().postDataJSON()
      if (attempts === 1) return json(route, { errors: ['Could not save. Please try again.'] }, 422)
      account.payout_ready = true; account.payout_review.status = 'approved'
      return json(route, account)
    })
    await page.goto('/admin')
    await expect(page.getByRole('heading', { name: 'Payout setups awaiting approval (1)' })).toBeVisible()
    await expect(page.getByText('Island Events LLC', { exact: true })).toBeVisible()
    await expect(page.getByText('NEVER_RENDER_BANK_NUMBER')).toHaveCount(0)
    await expect(page.getByText('NEVER_RENDER_TIN')).toHaveCount(0)
    await accessible(page, width)
    const trigger = page.getByRole('button', { name: 'Approve payout method' })
    await trigger.focus(); await page.keyboard.press('Enter')
    let dialog = page.getByRole('dialog', { name: 'Approve payout method' })
    await expect(dialog.getByText('PO Box 1, Hagåtña GU 96910')).toBeVisible()
    await expect(dialog.getByText('***-**-5678')).toBeVisible()
    await expect(dialog.getByRole('heading', { name: 'Approve payout method' })).toBeFocused()
    await page.keyboard.press('Escape'); await expect(trigger).toBeFocused()
    await page.keyboard.press('Enter')
    dialog = page.getByRole('dialog', { name: 'Approve payout method' })
    const submit = dialog.getByRole('button', { name: 'Approve payout method' })
    await expect(submit).toBeDisabled()
    await page.keyboard.press('Tab')
    for (let index = 0; index < 3; index += 1) { await page.keyboard.press('Space'); await page.keyboard.press('Tab') }
    await expect(dialog.getByRole('checkbox').nth(2)).toBeChecked()
    await dialog.getByLabel(/Note \(optional/).fill('Confirmed with the organizer by phone.')
    await accessible(page, width)
    await submit.click()
    await expect(dialog.getByRole('alert')).toContainText('Could not save')
    await expect(dialog.getByLabel(/Note \(optional/)).toHaveValue('Confirmed with the organizer by phone.')
    await submit.click()
    await expect(page.getByRole('heading', { name: 'Payout setups awaiting approval (0)' })).toBeVisible()
    expect(payload).toEqual({ controls: { payee_matches: true, details_complete: true, organization_confirmed: true }, note: 'Confirmed with the organizer by phone.', review_by: expect.stringMatching(/^\d{4}-\d{2}-\d{2}$/), expected_digest: 'current-digest' })
    expect(attempts).toBe(2)
    await page.reload(); await expect(page.getByText('No payout setups are waiting for approval.')).toBeVisible()
  })
  test(`organization blocked review and required changes note at ${width}`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 }); await base(page)
    const account = accountFixture(); account.payout_review = { ...account.payout_review, can_approve: false, status: 'incomplete', missing: ['A certified W-9 is required.'] }
    await page.route('**/api/v1/admin/organizations/7', route => json(route, { id: 7, name: account.organization_name, events_count: 0, memberships: [], payout_accounts: [account] }))
    await page.route('**/api/v1/admin/organizations/7/memberships', route => json(route, []))
    await page.route('**/api/v1/admin/connected_accounts/11/request_payout_changes', route => {
      expect(route.request().postDataJSON()).toEqual({ note: 'Please certify your W-9.', expected_digest: 'current-digest' })
      account.payout_review.status = 'changes_requested'; account.payout_review.note = 'Please certify your W-9.'
      return json(route, account)
    })
    await page.goto('/admin/organizations/7')
    await expect(page.getByRole('button', { name: 'Approve payout method' })).toBeDisabled()
    await expect(page.getByText('A certified W-9 is required.')).toBeVisible()
    await page.getByRole('button', { name: 'Ask for changes' }).click()
    const dialog = page.getByRole('dialog', { name: 'Ask for changes' })
    await expect(dialog.getByRole('button', { name: 'Send changes request' })).toBeDisabled()
    await dialog.getByLabel(/What needs to change/).fill('Please certify your W-9.')
    await accessible(page, width)
    await dialog.getByRole('button', { name: 'Send changes request' }).click()
    await expect(page.getByText('Changes requested', { exact: true })).toBeVisible()
    await expect(page.getByText('Note to organizer: Please certify your W-9.')).toBeVisible()
    await page.reload(); await expect(page.getByText('Changes requested', { exact: true })).toBeVisible()
    await accessible(page, width)
  })
  test(`organizer check-only selection persists at ${width}`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 }); await base(page)
    const account = { ...accountFixture(), selected: false, payout_ready: true, payout_review: { ...accountFixture().payout_review, status: 'approved' } }
    await page.route('**/api/v1/organizer/organizations', route => json(route, [{ id: 7, name: 'Island Events', role: 'owner', permissions: { manage_payout_settings: true, manage_organization: true } }]))
    await page.route('**/api/v1/organizer/organization', route => json(route, { id: 7, name: 'Island Events', role: 'owner', permissions: { manage_payout_settings: true, manage_organization: true } }))
    await page.route('**/api/v1/organizer/tax_information', route => json(route, { tax_information: null, edit_locked: false, certification: 'I certify.' }))
    await page.route('**/api/v1/organizer/connected_accounts', route => json(route, [account]))
    await page.route('**/api/v1/organizer/connected_accounts/11', route => {
      expect(route.request().postDataJSON()).toEqual({})
      account.selected = true
      return json(route, account)
    })
    await page.goto('/dashboard/settings')
    const payouts = page.getByRole('region', { name: 'How you get paid' })
    await expect(payouts.getByRole('radio', { name: /Bank transfer/ })).toBeDisabled()
    await expect(payouts.getByText('Not available yet — HåfaPass currently pays by check.')).toBeVisible()
    await expect(payouts.getByLabel('Account number', { exact: true })).toHaveCount(0)
    await payouts.getByRole('button', { name: 'Use this check payout method' }).click()
    await expect(payouts.getByText('Selected payout method')).toBeVisible()
    await page.reload()
    await expect(payouts.getByText('Selected payout method')).toBeVisible()
    await accessible(page, width)
  })
}
