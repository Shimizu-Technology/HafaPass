import { expect, test } from '@playwright/test'

const json = (route, data) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(data) })
const hold = () => { let release; const promise = new Promise(resolve => { release = resolve }); return { promise, release } }
const profile = name => ({ business_name: name, business_description: '', policy_accepted: true, verification_status: 'unverified' })
const organizations = [1, 2].map(id => ({ id, name: id === 1 ? 'Alpha organization' : 'Beta organization', role: 'owner', permissions: { manage_organization: true, manage_events: true } }))

async function dashboardFixtures(page, profiles) {
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/organizer/organizations', route => json(route, organizations))
  await page.route('**/api/v1/organizer/events', route => json(route, { events: [] }))
  await page.route('**/api/v1/organizer_profile', route => json(route, profiles[route.request().headers()['x-organization-id']]))
}

test('a received Alpha review can finish without replacing Beta or losing its editor draft', async ({ page }) => {
  const profiles = { 1: profile('Alpha'), 2: profile('Beta') }
  const old = hold()
  let submittedOrganization
  await dashboardFixtures(page, profiles)
  await page.route('**/api/v1/organizer_profile/submit_verification', async route => {
    submittedOrganization = route.request().headers()['x-organization-id']
    await old.promise
    // Model an original server operation committing despite local cancellation.
    profiles[submittedOrganization] = { ...profiles[submittedOrganization], verification_status: 'pending' }
    await json(route, profiles[submittedOrganization]).catch(() => {})
  })
  await page.goto('/dashboard')
  await page.getByRole('button', { name: 'Submit for review' }).click()
  await expect.poll(() => submittedOrganization).toBe('1')
  await page.getByLabel('Organization').selectOption('2')
  await expect(page.getByRole('heading', { name: 'Welcome, Beta' })).toBeVisible()
  await page.getByTitle('Edit Profile').click()
  await page.getByLabel(/Business Name/).fill('Beta draft')
  old.release()
  await expect.poll(() => profiles[1].verification_status).toBe('pending')
  await expect(page.getByRole('heading', { name: 'Welcome, Beta' })).toBeVisible()
  await expect(page.getByLabel(/Business Name/)).toHaveValue('Beta draft')
  await page.getByRole('button', { name: 'Close profile editor' }).click()
  await page.getByLabel('Organization').selectOption('1')
  await expect(page.getByText('pending', { exact: true })).toBeVisible()
  expect(profiles[2].verification_status).toBe('unverified')
})

test('an old Alpha profile save does not close or reload a newly opened Beta editor', async ({ page }) => {
  const profiles = { 1: profile('Alpha'), 2: profile('Beta') }
  const old = hold()
  let received
  await dashboardFixtures(page, profiles)
  await page.route('**/api/v1/organizer_profile', async route => {
    const org = route.request().headers()['x-organization-id']
    if (route.request().method() !== 'PUT') return json(route, profiles[org])
    received = { org, body: route.request().postDataJSON() }
    await old.promise
    profiles[org] = { ...profiles[org], ...received.body }
    await json(route, profiles[org]).catch(() => {})
  })
  await page.goto('/dashboard')
  await page.getByTitle('Edit Profile').click()
  await page.getByLabel(/Business Name/).fill('Alpha saved operation')
  await page.getByRole('button', { name: 'Save', exact: true }).click()
  await expect.poll(() => received?.org).toBe('1')
  await page.getByRole('button', { name: 'Close profile editor' }).click()
  await page.getByLabel('Organization').selectOption('2')
  await page.getByTitle('Edit Profile').click()
  await page.getByLabel(/Business Name/).fill('Beta unsaved draft')
  old.release()
  await expect.poll(() => profiles[1].business_name).toBe('Alpha saved operation')
  await expect(page.getByRole('heading', { name: 'Edit Profile' })).toBeVisible()
  await expect(page.getByLabel(/Business Name/)).toHaveValue('Beta unsaved draft')
  expect(profiles[2].business_name).toBe('Beta')
})

test('returning through browser history keeps a delayed Alpha load out of the Beta event save', async ({ page }) => {
  const old = hold()
  let alphaRequested = false, saved
  const event = id => ({ id, title: id === 11 ? 'Alpha event' : 'Beta event', status: 'draft', venue_name: 'Synthetic venue',
    starts_at: '2026-11-20T07:00:00Z', timezone: 'Pacific/Guam', category: 'other', age_restriction: 'all_ages',
    permissions: { edit_event_content: true, manage_events: true }, ticket_types: [], publish_checklist: [] })
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { launch_capabilities: {} }))
  await page.route('**/api/v1/event_categories', route => json(route, { categories: [{ value: 'other', label: 'Other' }] }))
  await page.route('**/api/v1/organizer/events/11', async route => {
    alphaRequested = true
    await old.promise
    await json(route, event(11)).catch(() => {})
  })
  await page.route('**/api/v1/organizer/events/22', route => {
    if (route.request().method() === 'PUT') saved = route.request().postDataJSON()
    return json(route, { ...event(22), ...saved })
  })
  await page.goto('/dashboard/events/22/edit')
  await expect(page.getByLabel(/Event Title/)).toHaveValue('Beta event')
  // Add a history entry through the real BrowserRouter, then use browser Back.
  await page.evaluate(() => {
    window.history.pushState({ ...window.history.state, key: 'synthetic-alpha-entry' }, '', '/dashboard/events/11/edit')
    window.dispatchEvent(new PopStateEvent('popstate'))
  })
  await expect.poll(() => alphaRequested).toBe(true)
  await page.goBack()
  await expect(page.getByLabel(/Event Title/)).toHaveValue('Beta event')
  await page.getByLabel(/Event Title/).fill('Beta saved draft')
  old.release()
  await expect(page.getByLabel(/Event Title/)).toHaveValue('Beta saved draft')
  await page.getByRole('button', { name: 'Save Changes' }).click()
  await expect(page.getByText('Event updated successfully.')).toBeVisible()
  expect(saved.title).toBe('Beta saved draft')
})
