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

// A section jump must bring the section near the top unless the document ends
// first: once the browser has scrolled as far as it can, the section only has
// to sit below the sticky header and be visible.
async function sectionTopOrScrollLimit(page, section) {
  const { y } = await section.boundingBox()
  const atEnd = await page.evaluate(() => Math.ceil(window.scrollY + window.innerHeight) >= document.documentElement.scrollHeight - 1)
  return y < 180 || (atEnd && y < (await page.viewportSize()).height - 40)
}

for (const width of [320, 1440]) {
  test(`ticket navigation scrolls and focuses the editor section without losing a draft at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 }); await prepare(page)
    await page.goto('/dashboard/events/601/edit')
    const title = page.getByLabel(/Event Title/)
    await expect(title).toHaveValue(event.title)
    await title.fill('Preserved before ticket jump')
    if (width < 1024) await page.getByRole('button', { name: 'Event navigation', exact: true }).click()
    const firstStart = await page.evaluate(() => window.scrollY)
    await page.getByRole('navigation', { name: 'Event workspace', exact: true }).getByRole('link', { name: 'Ticket types', exact: true }).click()
    const section = page.getByRole('region', { name: 'Ticket types', exact: true })
    await expect(section).toBeFocused()
    // The first jump must actually move the page, not just pass the position check.
    await expect.poll(() => page.evaluate(() => window.scrollY)).not.toBe(firstStart)
    await expect(title).toHaveValue('Preserved before ticket jump')
    await expect(page.getByRole('dialog')).toHaveCount(0)
    await expect.poll(() => sectionTopOrScrollLimit(page, section)).toBe(true)
    expect((await section.boundingBox()).y).toBeGreaterThanOrEqual(60)
    await title.focus()
    if (width < 1024) await page.getByRole('button', { name: 'Event navigation', exact: true }).click()
    const secondStart = await page.evaluate(() => window.scrollY)
    await page.getByRole('navigation', { name: 'Event workspace', exact: true }).getByRole('link', { name: 'Ticket types', exact: true }).click()
    await expect(section).toBeFocused()
    // If focusing the title left the section in place, it must already end within view.
    await expect.poll(async () => await page.evaluate(() => window.scrollY) !== secondStart
      || (await section.boundingBox()).y + (await section.boundingBox()).height <= (await page.viewportSize()).height).toBe(true)
    await expect.poll(() => sectionTopOrScrollLimit(page, section)).toBe(true)
    expect((await section.boundingBox()).y).toBeGreaterThanOrEqual(60)
    await expect(title).toHaveValue('Preserved before ticket jump')
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
  })
}

for (const width of [390, 1440]) {
  test(`attendee sales filters and export stay usable at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    await prepare(page)
    await page.route('**/api/v1/organizer/events/601/attendees?**', route => json(route, {
      attendees: [{ id: 7, attendee_name: 'Mina Cruz', attendee_email: 'mina@example.invalid',
        order_number: 'HP-DEMO7', ticket_type: 'Entry', status: 'issued' }],
      meta: { total_count: 1, total_pages: 1 }
    }))
    await page.route('**/api/v1/organizer/events/601/sales_exports', route => {
      if (route.request().method() !== 'POST') return json(route, { exports: [] })
      return route.fulfill({
        status: 200, contentType: 'text/csv; charset=utf-8',
        headers: { 'Content-Disposition': 'attachment; filename="sales.csv"' },
        body: '\uFEFF"Name","Order #"\n"Mina Cruz","HP-DEMO7"\n'
      })
    })
    await page.goto('/dashboard/events/601/attendees')
    await expect(page.getByRole('status').filter({ hasText: '1 attendee' })).toBeVisible()
    await page.getByRole('button', { name: 'Filters & sort' }).click()
    await page.getByRole('combobox', { name: 'Sales channel' }).selectOption('box_office')
    await page.getByRole('button', { name: 'Show results' }).click()
    await expect(page).toHaveURL(/channel=box_office/)
    await expect(page.getByRole('region', { name: 'Active filters' })).toContainText('Sales channel: Box office')
    await expect(width < 640 ? page.locator('.sm\\:hidden').getByText('Mina Cruz') : page.locator('table').getByText('Mina Cruz')).toBeVisible()
    await page.getByRole('button', { name: 'Export this list' }).click()
    await expect(page.getByRole('dialog', { name: 'Export this list' })).toContainText('1 attendee')
    const download = page.waitForEvent('download')
    await page.getByRole('button', { name: 'Download CSV' }).click()
    expect((await download).suggestedFilename()).toContain('attendees.csv')
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
  })
}
