import { expect, test } from '@playwright/test'

for (const width of [390, 1440]) {
  test(`content-only marketer can recover from a blank title at ${width}px`, async ({ page }) => {
    let saved = { id: 601, organization_id: 1, title: 'Marketer event', status: 'draft', category: 'other',
      permissions: { edit_event_content: true }, ticket_types: [] }
    let writes = 0
    await page.setViewportSize({ width, height: 900 })
    await page.route('**/api/v1/**', async route => {
      const path = new URL(route.request().url()).pathname
      let body = {}
      if (path.endsWith('/health')) body = { status: 'ok' }
      else if (path.endsWith('/config')) body = { launch_capabilities: {}, service_fee_percent: '5.0', service_fee_flat_cents: 100, processing_fee_bearer: 'platform', payout_schedule_text: 'within 3 to 5 business days after your event' }
      else if (path.endsWith('/event_categories')) body = { categories: [] }
      else if (path.endsWith('/organizer/organizations')) body = [{ id: 1, name: 'Synthetic marketer organization' }]
      else if (path.endsWith('/organizer/events/601')) {
        if (route.request().method() === 'PUT') { writes += 1; saved = { ...saved, ...route.request().postDataJSON() } }
        body = saved
      }
      await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) })
    })
    await page.goto('/dashboard/events/601/edit')
    const title = page.getByLabel(/Event Title/)
    await expect(title).toHaveValue('Marketer event')
    await title.fill('')
    const save = page.getByRole('button', { name: 'Save Changes', exact: true })
    await save.click()
    await expect(title).toBeFocused()
    await expect(title).toHaveAttribute('aria-invalid', 'true')
    await expect(title).toHaveAttribute('aria-describedby', 'title-error')
    await expect(page.getByRole('link', { name: 'Title is required', exact: true })).toBeVisible()
    expect((await title.boundingBox()).y).toBeGreaterThanOrEqual(64)
    expect((await title.boundingBox()).y).toBeLessThan(800)
    expect(writes).toBe(0)
    await title.fill('Corrected marketer event')
    await save.click()
    await expect(page.getByRole('status').filter({ hasText: 'Event updated successfully.' })).toBeVisible()
    expect(saved.title).toBe('Corrected marketer event')
    expect(writes).toBe(1)
  })
}

for (const width of [390, 1440]) {
  test(`canonical city/capacity saves recover publication readiness at ${width}px`, async ({ page }) => {
    let saved = { id: 602, organization_id: 1, title: 'Canonical saved event', status: 'draft', category: 'other',
      venue_name: 'Synthetic venue', venue_city: 'Tamuning', starts_at: '2099-10-20T07:00:00Z', timezone: 'Pacific/Guam',
      max_capacity: 1, permissions: { edit_event_content: true, manage_events: true }, ticket_types: [],
      publish_checklist: [{ code: 'event_details', label: 'Details', complete: true }] }
    const requests = []
    await page.setViewportSize({ width, height: 900 })
    await page.route('**/api/v1/**', async route => {
      const path = new URL(route.request().url()).pathname
      let body = {}
      if (path.endsWith('/health')) body = { status: 'ok' }
      else if (path.endsWith('/config')) body = { launch_capabilities: {}, service_fee_percent: '5.0', service_fee_flat_cents: 100, processing_fee_bearer: 'platform', payout_schedule_text: 'within 3 to 5 business days after your event' }
      else if (path.endsWith('/event_categories')) body = { categories: [] }
      else if (path.endsWith('/organizer/organizations')) body = [{ id: 1, name: 'Synthetic organizer' }]
      else if (path.endsWith('/organizer/events/602')) {
        if (route.request().method() === 'PUT') {
          const payload = route.request().postDataJSON()
          requests.push(payload)
          if (requests.length === 1) {
            await route.fulfill({ status: 500, contentType: 'application/json', body: JSON.stringify({ error: 'Synthetic save failure' }) })
            return
          }
          saved = { ...saved, ...payload, venue_city: payload.venue_city, max_capacity: Number(payload.max_capacity) }
        }
        body = saved
      }
      await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) })
    })
    await page.goto('/dashboard/events/602/edit')
    const city = page.getByLabel('Village or city', { exact: true })
    const capacity = page.getByLabel('Max Capacity', { exact: true })
    const save = page.getByRole('button', { name: 'Save Changes', exact: true })
    const publish = page.getByRole('button', { name: 'Publish Event', exact: true })
    await expect(city).toHaveValue('Tamuning')
    await city.fill('')
    await capacity.fill('0200')
    await expect(publish).toBeDisabled()
    await save.click()
    await expect(page.getByRole('alert')).toHaveText('Synthetic save failure')
    await expect(city).toHaveValue('')
    await expect(capacity).toHaveValue('0200')
    await expect(publish).toBeDisabled()
    await save.click()
    await expect(page.getByRole('status').filter({ hasText: 'Event updated successfully.' })).toBeVisible()
    await expect(city).toHaveValue('')
    await expect(capacity).toHaveValue('200')
    await expect(publish).toBeEnabled()
    await expect(page.getByText(/Preview shows the last saved event/)).toHaveCount(0)
    expect(saved).toMatchObject({ venue_city: '', max_capacity: 200 })
    await capacity.fill('200.2')
    await expect(publish).toBeDisabled()
    await save.click()
    await expect(page.getByRole('link', { name: 'Max capacity must be a positive integer', exact: true })).toBeVisible()
    expect(requests).toHaveLength(2)
    await capacity.fill('1e2')
    expect(await capacity.evaluate(input => input.validity.valid)).toBe(true)
    await save.click()
    await expect(capacity).toHaveValue('100')
    expect(requests[2].max_capacity).toBe(100)
    expect(saved.max_capacity).toBe(100)
    await expect(publish).toBeEnabled()
    await publish.click()
    await expect(page.getByRole('dialog')).toContainText('Publish the saved event “Canonical saved event”?')
  })
}

test('new event capacity uses the validated number and retains draft recovery until creation succeeds', async ({ page }) => {
  let created
  await page.setViewportSize({ width: 390, height: 900 })
  await page.route('**/api/v1/**', async route => {
    const path = new URL(route.request().url()).pathname
    let body = {}
    if (path.endsWith('/health')) body = { status: 'ok' }
    else if (path.endsWith('/config')) body = { launch_capabilities: {}, service_fee_percent: '5.0', service_fee_flat_cents: 100, processing_fee_bearer: 'platform', payout_schedule_text: 'within 3 to 5 business days after your event' }
    else if (path.endsWith('/event_categories')) body = { categories: [] }
    else if (path.endsWith('/organizer/organization')) body = { id: 1, permissions: { manage_events: true } }
    else if (path.endsWith('/organizer/organizations')) body = [{ id: 1, name: 'Synthetic organizer' }]
    else if (path.endsWith('/organizer/events') && route.request().method() === 'POST') {
      created = { ...route.request().postDataJSON(), id: 603, status: 'draft', permissions: { edit_event_content: true, manage_events: true }, ticket_types: [] }
      body = created
    } else if (path.endsWith('/organizer/events/603')) body = created
    await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) })
  })
  await page.goto('/dashboard/events/new')
  await page.getByLabel(/Event Title/).fill('Numeric create event')
  await page.getByLabel(/Venue Name/).fill('Synthetic venue')
  await page.locator('#starts_at').fill('2099-10-20T17:00')
  const capacity = page.getByLabel('Max Capacity', { exact: true })
  await capacity.fill('1.2')
  await page.getByRole('button', { name: 'Create Event', exact: true }).click()
  await expect(page.getByRole('link', { name: 'Max capacity must be a positive integer', exact: true })).toBeVisible()
  await expect(capacity).toBeFocused()
  expect(created).toBeUndefined()
  expect(await page.evaluate(() => Object.keys(sessionStorage).some(key => key.startsWith('hafapass:new-event:')))).toBe(true)
  await capacity.fill('1e2')
  expect(await capacity.evaluate(input => input.validity.valid)).toBe(true)
  await page.getByRole('button', { name: 'Create Event', exact: true }).click()
  await expect(page).toHaveURL(/\/dashboard\/events\/603\/edit$/)
  await expect(page.getByLabel('Max Capacity', { exact: true })).toHaveValue('100')
  expect(created.max_capacity).toBe(100)
  expect(created.venue_city).toBe('')
  await expect(page.getByLabel('Village or city')).toHaveValue('')
  expect(await page.evaluate(() => Object.keys(sessionStorage).some(key => key.startsWith('hafapass:new-event:')))).toBe(false)
})
