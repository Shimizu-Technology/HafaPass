import { expect, test } from '@playwright/test'

// Block module execution so Navbar cannot repair a wrong startup color.
// darkPage: the whole first screen is dark (hero, pricing band, ticket), so
// the splash page is dark too instead of flashing light first.
for (const [path, dark, darkPage = false] of [
  ['/', true, true], ['/host', true, true], ['/events', true], ['/discover', true],
  ['/collections/this-weekend', true], ['/my-tickets', true], ['/saved', true],
  ['/tickets/display-qa', true, true], ['/events/community-night', false],
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
          page: getComputedStyle(document.querySelector('.boot-splash')).backgroundColor,
          wordmark: getComputedStyle(document.querySelector('.boot-splash span')).color,
          boot: Boolean(document.querySelector('#root > .boot-splash')),
        }
      }, { once: true })
    })
    await page.goto(path, { waitUntil: 'domcontentloaded' })
    expect(await page.evaluate(() => window.startupTheme)).toEqual({
      meta: dark ? '#032827' : '#ffffff',
      bar: dark ? 'rgb(3, 40, 39)' : 'rgb(255, 255, 255)',
      page: darkPage ? 'rgb(3, 40, 39)' : 'rgb(248, 250, 251)',
      wordmark: darkPage ? 'rgb(255, 255, 255)' : 'rgb(11, 101, 99)',
      boot: true,
    })
    await expect(page.locator('header')).toHaveCount(0)
  })
}
