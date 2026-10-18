import { expect, test } from '@playwright/test'

for (const width of [390, 1440]) {
  test(`refused draft deletion recovers by archiving without a stale error at ${width}px`, async ({ page }) => {
    let saved = { id: 604, organization_id: 1, title: 'Synthetic draft with scanner history', status: 'draft', category: 'other',
      venue_name: 'Synthetic venue', starts_at: '2099-10-20T07:00:00Z', timezone: 'Pacific/Guam', ticket_types: [],
      permissions: { edit_event_content: true, manage_events: true } }
    const refusal = 'This event has saved history or related records and cannot be deleted. Archive it instead to keep those records.'
    let archiveStarted
    const started = new Promise(resolve => { archiveStarted = resolve })
    let releaseArchive
    const pending = new Promise(resolve => { releaseArchive = resolve })
    await page.setViewportSize({ width, height: 900 })
    await page.route('**/api/v1/**', async route => {
      const path = new URL(route.request().url()).pathname
      let body = {}
      if (path.endsWith('/health')) body = { status: 'ok' }
      else if (path.endsWith('/config')) body = { launch_capabilities: {} }
      else if (path.endsWith('/event_categories')) body = { categories: [] }
      else if (path.endsWith('/organizer/organizations')) body = [{ id: 1, name: 'Synthetic organizer' }]
      else if (path.endsWith('/organizer/events/604')) {
        if (route.request().method() === 'DELETE') {
          await route.fulfill({ status: 422, contentType: 'application/json', body: JSON.stringify({ error: refusal }) })
          return
        }
        body = saved
      } else if (path.endsWith('/organizer/events/604/archive')) {
        archiveStarted()
        await pending
        saved = { ...saved, status: 'archived' }
        body = saved
      }
      await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) })
    })
    await page.goto('/dashboard/events/604/edit')
    await page.getByRole('button', { name: 'Delete', exact: true }).click()
    await page.getByRole('button', { name: 'Yes, Delete', exact: true }).click()
    await expect(page.getByRole('alert')).toHaveText(refusal)
    await page.getByRole('button', { name: 'Archive', exact: true }).click()
    await started
    await expect(page.getByRole('alert')).toHaveCount(0)
    releaseArchive()
    await expect(page.getByRole('status').filter({ hasText: 'Event archived.' })).toBeVisible()
    await expect(page.getByRole('alert')).toHaveCount(0)
    await expect(page.getByRole('button', { name: 'Delete', exact: true })).toHaveCount(0)
    expect(saved.status).toBe('archived')
    await page.reload()
    await expect(page.getByLabel(/Event Title/)).toHaveValue(saved.title)
    await expect(page.getByRole('button', { name: 'Archive', exact: true })).toHaveCount(0)
    await expect(page.getByRole('alert')).toHaveCount(0)
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
  })
}
