import { expect, test } from '@playwright/test'

const json = (route, body) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) })
const event = { id: 601, title: 'Synthetic Community Event', organization_id: 1, organization_name: 'Synthetic Organizer',
  status: 'draft', venue_name: 'Synthetic venue', starts_at: '2099-10-20T07:00:00Z', timezone: 'Pacific/Guam',
  category: 'other', age_restriction: 'all_ages', ticket_types: [], publish_checklist: [],
  permissions: { edit_event_content: true, manage_events: true, manage_inventory: true, manage_attendees: true,
    view_attendees: true, manage_marketing: true, view_finance: true, refund: true, scan: true } }
async function prepare(page, permissions = event.permissions) {
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { launch_capabilities: {} }))
  await page.route('**/api/v1/event_categories', route => json(route, { categories: [{ value: 'other', label: 'Other' }] }))
  await page.route('**/api/v1/organizer/organizations', route => json(route, [{ id: 1, name: 'Synthetic Organizer' }]))
  await page.route('**/api/v1/organizer/events/601', route => json(route, { ...event, permissions }))
  await page.route('**/api/v1/organizer/events/601/guest_list', route => json(route, []))
}

for (const width of [390, 1440]) {
  test(`event workspace protects a dirty draft and keeps navigation reachable at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    await prepare(page)
    await page.goto('/dashboard/events/601/edit')
    const title = page.getByLabel(/Event Title/)
    await expect(title).toHaveValue(event.title)
    await title.fill('Unsaved event title')
    if (width < 1024) await page.getByRole('button', { name: 'Event navigation', exact: true }).click()
    const nav = page.getByRole('navigation', { name: 'Event workspace', exact: true })
    await expect(nav.getByRole('link', { name: 'Guest list', exact: true })).toBeVisible()
    await nav.getByRole('link', { name: 'Guest list', exact: true }).click()
    const leave = page.getByRole('dialog')
    await expect(leave.getByRole('heading', { name: 'Leave unsaved event changes?' })).toBeVisible()
    await leave.getByRole('button', { name: 'Stay and save', exact: true }).click()
    await expect(title).toHaveValue('Unsaved event title')
    if (width < 1024) await page.getByRole('button', { name: 'Event navigation', exact: true }).click()
    await nav.getByRole('link', { name: 'Guest list', exact: true }).click()
    await page.getByRole('button', { name: 'Leave without saving', exact: true }).click()
    await expect(page).toHaveURL(/\/dashboard\/events\/601\/guest-list$/)
    await expect(page.getByRole('heading', { name: event.title, exact: true })).toBeVisible()
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
  })
}

test('phone event navigation supports Escape and restores focus without exposing forbidden tools', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await prepare(page, { view_finance: true, refund: true })
  await page.goto('/dashboard/events/601/edit')
  const trigger = page.getByRole('button', { name: 'Event navigation', exact: true })
  await trigger.click()
  const drawer = page.getByRole('dialog', { name: 'Event navigation', exact: true })
  await expect(drawer).toBeVisible()
  await expect(drawer.getByRole('link', { name: 'Refunds', exact: true })).toBeVisible()
  await expect(drawer.getByRole('link', { name: 'Promo codes', exact: true })).toHaveCount(0)
  await expect(drawer.getByRole('link', { name: 'Edit event', exact: true })).toHaveCount(0)
  await page.keyboard.press('Escape')
  await expect(drawer).toHaveCount(0)
  await expect(trigger).toBeFocused()
})

for (const width of [320, 1440]) {
  test(`ticket navigation scrolls and focuses the editor section without losing a draft at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 }); await prepare(page)
    await page.goto('/dashboard/events/601/edit')
    const title = page.getByLabel(/Event Title/)
    await expect(title).toHaveValue(event.title)
    await title.fill('Preserved before ticket jump')
    if (width < 1024) await page.getByRole('button', { name: 'Event navigation', exact: true }).click()
    await page.getByRole('navigation', { name: 'Event workspace', exact: true }).getByRole('link', { name: 'Ticket types', exact: true }).click()
    const section = page.getByRole('region', { name: 'Ticket types', exact: true })
    await expect(section).toBeFocused()
    await expect(title).toHaveValue('Preserved before ticket jump')
    await expect(page.getByRole('dialog')).toHaveCount(0)
    await expect.poll(async () => (await section.boundingBox()).y).toBeLessThan(180)
    expect((await section.boundingBox()).y).toBeGreaterThanOrEqual(60)
    await title.focus()
    if (width < 1024) await page.getByRole('button', { name: 'Event navigation', exact: true }).click()
    await page.getByRole('navigation', { name: 'Event workspace', exact: true }).getByRole('link', { name: 'Ticket types', exact: true }).click()
    await expect(section).toBeFocused()
    await expect.poll(async () => (await section.boundingBox()).y).toBeLessThan(180)
    await expect(title).toHaveValue('Preserved before ticket jump')
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
  })
}
