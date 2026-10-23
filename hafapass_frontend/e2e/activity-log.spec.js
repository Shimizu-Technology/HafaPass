import { expect, test } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { readFile } from 'node:fs/promises'

// Uses the repo's playwright.config.js development-auth fixture (Clerk off)
// with isolated mocked API responses; no real audit records are modified.
const json = (route, body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
const organization = { id: 7, name: 'Island Community Events', role: 'owner', activity_access: true, permissions: { manage_members: true, view_activity_all: true } }
const event = { id: 4, title: `Reef Night ${'LongEventName'.repeat(12)}`, url: '/dashboard/events/4' }
const activity = { id: 31, occurred_at: '2026-10-23T18:00:00Z', sentence: 'Updated the ticket price.', area: 'events', outcome: 'succeeded',
  actor: { name: 'Mina Cruz' }, event, target: null, changes: [{ field: 'Price', before: '$20', after: '$25' }] }
const options = { actors: [{ id: 11, name: 'Mina Cruz', email: 'mina@example.test' }], areas: ['events', 'payouts'], events: [{ id: 4, title: event.title }] }
const csv = 'When,Activity\n2026-10-24,Updated the ticket price.\n'
const exportId = 'opaque.signed-export_9'

async function prepare(page, width) {
  await page.setViewportSize({ width, height: 900 })
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await page.clock.setFixedTime(new Date('2026-10-24T01:00:00Z'))
  await page.addInitScript(() => window.localStorage.setItem('hafapass_organization_id', '7'))
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { launch_capabilities: {}, payment_mode: 'simulate' }))
  await page.route('**/api/v1/organizer/organizations', route => json(route, [organization]))
  await page.route('**/api/v1/organizer/organization', route => json(route, organization))
}

async function openFilters(page, width) {
  if (width < 768) await page.getByText(/^Filters(?: · applied)?$/).click()
  await expect(page.getByLabel('From', { exact: true })).toBeVisible()
}

async function accessibleAndFits(page) {
  const results = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa']).analyze()
  expect(results.violations).toEqual([])
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual((await page.viewportSize()).width)
}

for (const width of [375, 1280]) {
  test(`organizer activity filters, timeline, recovery and CSV at ${width}px`, async ({ page }) => {
    await prepare(page, width)
    let failRead = false
    let failExport = true
    let exportParams
    const queries = []
    await page.route('**/api/v1/organizer/activity_logs*', route => {
      const query = new URL(route.request().url()).searchParams
      queries.push(Object.fromEntries(query))
      if (failRead) { failRead = false; return json(route, { error: 'Temporarily unavailable' }, 503) }
      return json(route, { activity_logs: query.get('q') === 'no matches' ? [] : query.get('cursor')
        ? [{ ...activity, id: 33, sentence: 'Requested a payout.', occurred_at: '2026-10-21T18:00:00Z', outcome: 'requested' }]
        : [activity, { ...activity, id: 32, occurred_at: '2026-10-22T18:00:00Z', sentence: 'A refund failed.', outcome: 'failed' }],
      meta: { activity_logging_started_at: '2026-10-22', next_cursor: query.get('cursor') || query.get('q') ? null : 'next-32' }, filters: options })
    })
    await page.route('**/api/v1/organizer/activity_log_exports', route => {
      exportParams = route.request().postDataJSON()
      const status = failExport ? 'failed' : 'ready'
      failExport = false
      return json(route, { export: { id: exportId, status, download_url: `/api/v1/organizer/activity_log_exports/${exportId}/download` } }, 201)
    })
    await page.route(`**/api/v1/organizer/activity_log_exports/${exportId}/download`, route => route.fulfill({ status: 200, contentType: 'text/csv', body: csv }))
    await page.goto('/dashboard/settings/activity?event_id=4')
    await expect(page.getByRole('heading', { name: 'Activity', exact: true })).toBeVisible()
    await expect(page.getByText(activity.sentence, { exact: true })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Today', exact: true })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Yesterday', exact: true })).toBeVisible()
    await expect(page.getByText('Activity is recorded from Oct 22, 2026. Earlier changes aren’t shown.')).toBeVisible()
    await page.getByText('Details for activity 31', { exact: true }).click()
    await expect(page.getByText('Before: $20').filter({ visible: true })).toBeVisible()
    await expect(page.getByText('After: $25').filter({ visible: true })).toBeVisible()
    await accessibleAndFits(page)
    await page.screenshot({ path: `test-results/activity-${width}.png`, fullPage: true })
    await page.getByRole('button', { name: 'Load more', exact: true }).click()
    await expect(page.getByRole('heading', { name: 'Oct 22', exact: true })).toBeVisible()
    expect(queries.at(-1)).toMatchObject({ event_id: '4', cursor: 'next-32', limit: '50' })
    await openFilters(page, width)
    await page.getByLabel('By', { exact: true }).selectOption('11')
    await expect.poll(() => queries.at(-1)?.actor_user_id).toBe('11')
    await page.getByLabel('Area', { exact: true }).selectOption('events')
    await expect.poll(() => queries.at(-1)?.area).toBe('events')
    await page.getByLabel('From', { exact: true }).fill('2026-10-22')
    await expect.poll(() => queries.at(-1)?.from).toBe('2026-10-22')
    await expect(page).toHaveURL(/event_id=4/)
    await page.getByRole('button', { name: 'Download CSV' }).click()
    await expect(page.getByRole('alert')).toContainText('CSV could not be downloaded')
    const [download] = await Promise.all([page.waitForEvent('download'), page.getByRole('button', { name: 'Retry CSV export' }).click()])
    expect(await readFile(await download.path(), 'utf8')).toBe(csv)
    expect(exportParams).toEqual({ event_id: '4', actor_user_id: '11', area: 'events', from: '2026-10-22' })
    failRead = true
    await page.getByLabel('Outcome', { exact: true }).selectOption('failed')
    await expect(page.getByRole('alert')).toContainText('Your filters have been kept')
    await page.getByRole('button', { name: 'Try again', exact: true }).click()
    await expect(page.getByText(activity.sentence, { exact: true })).toBeVisible()
    await page.getByRole('searchbox', { name: 'Search activity' }).fill('no matches')
    await page.getByRole('button', { name: 'Search', exact: true }).click()
    await expect(page.getByRole('heading', { name: 'No activity matches these filters.' })).toBeVisible()
    await page.reload()
    await expect(page.getByRole('heading', { name: 'No activity matches these filters.' })).toBeVisible()
    await openFilters(page, width)
    await expect(page.getByRole('searchbox', { name: 'Search activity' })).toHaveValue('no matches')
    await page.getByRole('button', { name: 'Clear all filters' }).click()
    await expect(page).toHaveURL('/dashboard/settings/activity')
    await expect(page.getByText(activity.sentence, { exact: true })).toBeVisible()
    await accessibleAndFits(page)
  })

  test(`admin exact filters, links, technical details and CSV at ${width}px`, async ({ page }) => {
    await prepare(page, width)
    const queries = []
    let exported
    await page.route('**/api/v1/admin/audit_logs*', route => {
      queries.push(Object.fromEntries(new URL(route.request().url()).searchParams))
      return json(route, { audit_logs: [{ ...activity, action: 'event.updated', source: 'admin',
        event: { ...event, url: '/admin/events/4' }, organization: { id: 7, name: organization.name, url: '/admin/organizations/7' },
        actor: { name: 'Mina Cruz', email: `${'long-email'.repeat(12)}@example.test` }, target: { type: 'Event', id: 4 },
        before_data: { price_cents: 2000 }, after_data: { price_cents: 2500 }, metadata: { source: 'admin', note: '<script>alert(1)</script>' }, request_id: 'req-activity-31' }],
      meta: { page: 1, total_pages: 1, total_count: 1 }, areas: ['events', 'payouts'], filters: { ...options, actions: ['event.updated'],
        organizations: [{ id: 7, name: organization.name }, { id: 8, name: 'Other Organizer' }] } })
    })
    await page.route('**/api/v1/admin/activity_log_exports', route => {
      exported = route.request().postDataJSON()
      return json(route, { export: { id: exportId, status: 'ready', download_url: `/api/v1/admin/activity_log_exports/${exportId}/download` } }, 201)
    })
    await page.route(`**/api/v1/admin/activity_log_exports/${exportId}/download`, route => route.fulfill({ status: 200, contentType: 'text/csv', body: csv }))
    await page.goto('/admin/audit-log')
    await expect(page.getByText(activity.sentence, { exact: true })).toBeVisible()
    await expect(page.getByRole('list', { name: 'Audit entries' }).getByText('event.updated', { exact: true })).toBeVisible()
    await expect(page.getByRole('link', { name: organization.name, exact: true })).toHaveAttribute('href', '/admin/organizations/7')
    await expect(page.getByRole('link', { name: event.title, exact: true })).toHaveAttribute('href', '/admin/events/4')
    await page.getByRole('button', { name: 'Details for entry 31', exact: true }).click()
    await expect(page.getByRole('heading', { name: 'What changed' })).toBeVisible()
    await page.getByText('Technical details', { exact: true }).click()
    await expect(page.locator('pre')).toContainText('<script>alert(1)</script>')
    await expect(page.locator('pre script')).toHaveCount(0)
    await expect(page.getByText(/request req-activity-31/)).toBeVisible()
    await accessibleAndFits(page)
    await openFilters(page, width)
    await page.getByRole('searchbox', { name: 'Find organization' }).fill('Island')
    await expect(page.getByRole('option', { name: 'Other Organizer', exact: true })).toHaveCount(0)
    await page.getByLabel('Organization', { exact: true }).selectOption('7')
    await expect.poll(() => queries.at(-1)?.organization_id).toBe('7')
    for (const [label, value, key] of [['By', '11', 'actor_user_id'], ['Action', 'event.updated', 'action'], ['Event', '4', 'event_id'], ['Outcome', 'failed', 'outcome'], ['Source', 'admin', 'source'], ['Area', 'events', 'area']]) {
      await page.getByLabel(label, { exact: true }).selectOption(value)
      await expect.poll(() => queries.at(-1)?.[key]).toBe(value)
    }
    const [download] = await Promise.all([page.waitForEvent('download'), page.getByRole('button', { name: 'Download CSV' }).click()])
    expect(await readFile(await download.path(), 'utf8')).toBe(csv)
    expect(exported).toEqual({ organization_id: '7', actor_user_id: '11', action: 'event.updated', event_id: '4', outcome: 'failed', source: 'admin', area: 'events' })
    await page.reload()
    await openFilters(page, width)
    await expect(page.getByLabel('Action', { exact: true })).toHaveValue('event.updated')
    await page.getByRole('button', { name: 'Clear all filters' }).click()
    await expect(page).toHaveURL('/admin/audit-log')
    await expect(page.getByText(/Personal details may be redacted for privacy or retention/)).toBeVisible()
    await accessibleAndFits(page)
  })
}

test('unassigned staff cannot request activity; assigned managers can use the explicit audience flag', async ({ page }) => {
  await prepare(page, 375)
  let assigned = false
  let reads = 0
  await page.route('**/api/v1/organizer/organization', route => json(route, { ...organization, role: 'marketer', permissions: { manage_marketing: true }, activity_access: assigned }))
  await page.route('**/api/v1/organizer/activity_logs*', route => {
    reads += 1
    return json(route, { activity_logs: [], meta: {}, filters: options })
  })
  await page.goto('/dashboard/settings/activity')
  await expect(page.getByText('Activity is not available for your role')).toBeVisible()
  expect(reads).toBe(0)
  await expect(page.getByRole('button', { name: 'Download CSV' })).toHaveCount(0)
  assigned = true
  await page.getByRole('button', { name: 'Retry activity access' }).click()
  await expect(page.getByRole('heading', { name: 'No activity yet' })).toBeVisible()
  expect(reads).toBe(1)
  await accessibleAndFits(page)
})

for (const width of [375, 1280]) {
  test(`settings role comparison preserves invite draft and passes axe at ${width}px`, async ({ page }) => {
    await prepare(page, width)
    await page.route('**/api/v1/organizer/memberships', route => json(route, []))
    await page.goto('/dashboard/settings')
    await expect(page.getByRole('link', { name: 'Activity', exact: true })).toBeVisible()
    await page.getByLabel('Teammate email').fill('door-staff@example.test')
    await page.getByRole('radio', { name: /^Finance/ }).check()
    const compare = page.getByRole('button', { name: 'Compare roles', exact: true }).first()
    await compare.click()
    const dialog = page.getByRole('dialog', { name: 'Compare roles', exact: true })
    await expect(dialog).toBeVisible()
    await expect(width >= 1024 ? dialog.getByRole('rowheader', { name: /^View activity log/ }) : dialog.getByRole('heading', { name: 'View activity log (all / events / money)', exact: true })).toBeVisible()
    await expect(dialog.getByText(/Managers can't cancel events or move money/)).toBeVisible()
    await expect(dialog.getByText(/up to 24 hours/)).toBeVisible()
    const matrix = width >= 1024 ? dialog.getByRole('table') : dialog.getByRole('region', { name: 'Stacked role comparison' })
    if (width >= 1024) await expect(matrix).toBeVisible()
    await accessibleAndFits(page)
    await page.screenshot({ path: `test-results/role-matrix-${width}.png`, fullPage: false })
    await page.keyboard.press('Escape')
    await expect(dialog).toHaveCount(0)
    await expect(compare).toBeFocused()
    await expect(page.getByLabel('Teammate email')).toHaveValue('door-staff@example.test')
    await expect(page.getByRole('radio', { name: /^Finance/ })).toBeChecked()
    await page.getByRole('link', { name: 'Activity', exact: true }).click()
    await expect(page).toHaveURL('/dashboard/settings/activity')
  })
}
