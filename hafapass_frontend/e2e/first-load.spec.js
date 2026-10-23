import { expect, test } from '@playwright/test'

const json = (route, body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })

test('public browsing starts before health resolves and preserves the shell and draft on failure/recovery', async ({ page }) => {
  let finishHealth
  let healthy = false
  await page.route('**/api/v1/health', async route => {
    if (!healthy) await new Promise(resolve => { finishHealth = resolve })
    await json(route, {}, healthy ? 200 : 503)
  })
  await page.route('**/api/v1/config', route => json(route, {}))
  await page.route('**/api/v1/events', route => json(route, { events: [] }))
  await page.goto('/')
  await expect(page.getByRole('heading', { name: 'No upcoming events listed' })).toBeVisible()
  await page.evaluate(() => { window.originalShell = document.querySelector('.app-shell') })
  const search = page.getByRole('searchbox', { name: 'Event or venue' })
  await search.fill('Friday night')
  await expect.poll(() => Boolean(finishHealth)).toBe(true)
  finishHealth()
  await expect(page.getByRole('alert').filter({ hasText: 'We’re having trouble reaching HåfaPass' })).toBeVisible()
  await expect(search).toHaveValue('Friday night')
  healthy = true
  await page.getByRole('button', { name: 'Try again', exact: true }).click()
  await expect(page.getByText('We’re having trouble reaching HåfaPass', { exact: false })).toHaveCount(0)
  await expect(search).toHaveValue('Friday night')
  expect(await page.evaluate(() => window.originalShell === document.querySelector('.app-shell'))).toBe(true)
})

for (const viewport of [{ width: 390, height: 844 }, { width: 1280, height: 800 }]) {
  test(`missing-event loading keeps CLS below 0.1 at ${viewport.width}px`, async ({ page }) => {
    await page.setViewportSize(viewport)
    await page.addInitScript(() => {
      window.firstLoadCls = 0
      new PerformanceObserver(list => {
        for (const entry of list.getEntries()) if (!entry.hadRecentInput) window.firstLoadCls += entry.value
      }).observe({ type: 'layout-shift', buffered: true })
    })
    await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
    await page.route('**/api/v1/config', route => json(route, {}))
    let finishEvent
    await page.route('**/api/v1/events/nope', async route => {
      await new Promise(resolve => { finishEvent = resolve })
      await json(route, {}, 404)
    })
    await page.goto('/events/nope')
    await expect(page.locator('.route-loading')).toBeVisible()
    await page.evaluate(() => document.fonts.ready)
    const footerTop = await page.locator('footer').evaluate(element => element.getBoundingClientRect().top)
    await expect.poll(() => Boolean(finishEvent)).toBe(true)
    finishEvent()
    await expect(page.getByRole('heading', { name: 'We couldn’t find that event' })).toBeVisible()
    expect(await page.locator('footer').evaluate(element => element.getBoundingClientRect().top)).toBe(footerTop)
    expect(await page.evaluate(() => window.firstLoadCls)).toBeLessThan(0.1)
  })
}
