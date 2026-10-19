import { expect, test } from '@playwright/test'

const json = (route, body) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) })
const event = { id: 601, organization_id: 1, title: 'Synthetic Draft Event', status: 'draft', venue_name: 'Synthetic venue',
  starts_at: '2099-10-20T07:00:00Z', timezone: 'Pacific/Guam', category: 'other', age_restriction: 'all_ages',
  ticket_types: [], publish_checklist: [], permissions: { edit_event_content: true, manage_events: true, manage_inventory: true } }
async function prepare(page) {
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { launch_capabilities: {} }))
  await page.route('**/api/v1/event_categories', route => json(route, { categories: [] }))
  await page.route('**/api/v1/events', route => json(route, { events: [], meta: { current_page: 1, total_pages: 1, total_count: 0 } }))
  await page.route('**/api/v1/organizer/organizations', route => json(route, [{ id: 1, name: 'Synthetic Organizer', role: 'owner', permissions: { manage_organization: true, manage_events: true } }]))
  await page.route('**/api/v1/organizer_profile', route => json(route, { id: 1, business_name: 'Synthetic Organizer', policy_accepted: true, verification_status: 'verified', payout_ready: false }))
  await page.route(/\/api\/v1\/organizer\/events(?:\?.*)?$/, route => json(route, { events: [event] }))
  await page.route('**/api/v1/organizer/events/601', route => json(route, event))
}
for (const width of [390, 1440]) {
  test(`shared navigation protects a dirty event draft at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    await prepare(page)
    await page.goto('/dashboard/events/601/edit')
    const title = page.getByLabel(/Event Title/)
    await expect(title).toHaveValue(event.title)
    await title.fill('Unsaved event draft')
    if (width < 768) {
      const menu = page.getByRole('button', { name: 'Toggle menu', exact: true })
      if (await menu.getAttribute('aria-expanded') === 'false') await menu.click()
    }
    await page.getByRole('link', { name: 'View public site', exact: true }).click()
    await expect(page.getByRole('dialog', { name: 'Leave unsaved event changes?' })).toBeVisible()
    await expect(page).toHaveURL(/\/dashboard\/events\/601\/edit$/)
    await page.getByRole('button', { name: 'Stay and save', exact: true }).click()
    await expect(title).toHaveValue('Unsaved event draft')
    if (width < 768) {
      const menu = page.getByRole('button', { name: 'Toggle menu', exact: true })
      if (await menu.getAttribute('aria-expanded') === 'false') await menu.click()
    }
    await page.getByRole('link', { name: 'View public site', exact: true }).click()
    await expect(page.getByRole('dialog')).toHaveCount(1)
    await page.getByRole('button', { name: 'Leave without saving', exact: true }).click()
    await expect(page).toHaveURL(/^https?:\/\/[^/]+\/$/)
    await expect(title).toHaveCount(0)
  })
}

test('browser Back retains the editor until the user approves departure', async ({ page }) => {
  await prepare(page)
  await page.goto('/dashboard')
  await page.getByRole('link', { name: /Synthetic Draft Event.*Edit event/ }).click()
  const title = page.getByLabel(/Event Title/)
  await title.fill('Unsaved before Back')
  await page.goBack()
  await expect(page.getByRole('dialog', { name: 'Leave unsaved event changes?' })).toBeVisible()
  await expect(page).toHaveURL(/\/dashboard\/events\/601\/edit$/)
  await page.getByRole('button', { name: 'Stay and save' }).click()
  await expect(title).toHaveValue('Unsaved before Back')
  await page.goBack()
  await page.getByRole('button', { name: 'Leave without saving' }).click()
  await expect(page).toHaveURL(/\/dashboard$/)
})

test('reload requests native confirmation and dismissal retains the draft', async ({ page }) => {
  await prepare(page)
  await page.goto('/dashboard/events/601/edit')
  const title = page.getByLabel(/Event Title/)
  await title.fill('Unsaved before reload')
  let dialogType
  let finishDismissal
  const dismissed = new Promise(resolve => { finishDismissal = resolve })
  page.once('dialog', async dialog => {
    dialogType = dialog.type()
    await dialog.dismiss()
    finishDismissal()
  })
  await page.reload({ waitUntil: 'commit', timeout: 5000 }).catch(() => {})
  await dismissed
  expect(dialogType).toBe('beforeunload')
  await expect(title).toHaveValue('Unsaved before reload')
})
