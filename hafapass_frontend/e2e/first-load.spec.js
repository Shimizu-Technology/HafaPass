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
  await page.route('**/api/v1/events', route => json(route, { events: [{ id: 1, slug: 'recovery-event', title: 'Service recovery event', starts_at: '2099-10-11T08:00:00Z', timezone: 'Pacific/Guam', ticket_types: [] }] }))
  await page.goto('/')
  await expect(page.getByRole('link', { name: /Service recovery event/ })).toBeVisible()
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

for (const width of [375, 1280]) {
  test(`discover loading keeps the footer stable through confirmed empty inventory at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 812 })
    await page.emulateMedia({ reducedMotion: 'reduce' })
    await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
    await page.route('**/api/v1/config', route => json(route, {}))
    await page.route('**/api/v1/events?**', route => json(route, { events: [], meta: { total_count: 0 } }))
    let finishCollections
    await page.route('**/api/v1/marketplace_collections', async route => {
      await new Promise(resolve => { finishCollections = resolve })
      await json(route, { collections: [] })
    })
    await page.goto('/discover')
    await expect(page.locator('main .animate-spin')).toBeVisible()
    // The route fallback also has a spinner. Measure only once Collections
    // itself has mounted and issued its held request, then settle its layout.
    await expect.poll(() => Boolean(finishCollections)).toBe(true)
    await page.evaluate(() => document.fonts.ready)
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
    const footerTop = await page.locator('footer').evaluate(element => element.getBoundingClientRect().top)
    finishCollections()
    await expect(page.getByRole('heading', { name: 'Events are coming soon' })).toBeVisible()
    // Read the settled layout after React commits the new utility classes.
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
    expect(await page.locator('footer').evaluate(element => element.getBoundingClientRect().top)).toBe(footerTop)
  })
}

for (const [path, color] of [['/', '#032827'], ['/host', '#032827'], ['/events', '#ffffff'], ['/discover', '#ffffff'], ['/dashboard', '#ffffff']]) {
  test(`cold-load theme color matches ${path} before the app mounts`, async ({ page }) => {
    await page.route('**/src/main.jsx*', route => route.abort())
    await page.goto(path)
    await expect(page.locator('.boot-splash')).toBeVisible()
    await expect(page.locator('meta[name="theme-color"]')).toHaveAttribute('content', color)
  })
}
