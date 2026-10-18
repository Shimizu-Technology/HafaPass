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
      else if (path.endsWith('/config')) body = { launch_capabilities: {} }
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
