import { expect, test } from '@playwright/test'

// Block module execution so Navbar cannot repair a wrong startup color.
for (const [path, dark] of [
  ['/', true], ['/host', true], ['/events', true], ['/discover', true],
  ['/collections/this-weekend', true], ['/my-tickets', true], ['/saved', true],
  ['/tickets/display-qa', true], ['/events/community-night', false],
  ['/dashboard', false], ['/admin/events', false], ['/scan', false],
]) {
  test(`startup header theme before React: ${path}`, async ({ page }) => {
    await page.route('**/*', route => route.request().resourceType() === 'script'
      ? route.fulfill({ contentType: 'application/javascript', body: '' })
      : route.continue())
    await page.addInitScript(() => {
      document.addEventListener('DOMContentLoaded', () => {
        window.startupTheme = {
          meta: document.querySelector('meta[name="theme-color"]').content,
          bar: getComputedStyle(document.querySelector('.boot-splash'), '::before').backgroundColor,
          boot: Boolean(document.querySelector('#root > .boot-splash')),
        }
      }, { once: true })
    })
    await page.goto(path, { waitUntil: 'domcontentloaded' })
    expect(await page.evaluate(() => window.startupTheme)).toEqual({
      meta: dark ? '#032827' : '#ffffff',
      bar: dark ? 'rgb(3, 40, 39)' : 'rgb(255, 255, 255)',
      boot: true,
    })
    await expect(page.locator('header')).toHaveCount(0)
  })
}
