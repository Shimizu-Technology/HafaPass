import { expect, test } from '@playwright/test'

for (const width of [375, 768, 1280]) {
  for (const accepted of [false, true]) {
    test(`event alerts ${accepted ? 'confirmation' : 'error'} reserves space at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 900 })
      await page.emulateMedia({ reducedMotion: 'reduce' })
      const json = (route, data, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(data) })
      await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
      await page.route('**/api/v1/config', route => json(route, {}))
      await page.route('**/api/v1/events*', route => json(route, { events: [] }))
      await page.route('**/api/v1/platform_subscriptions', async route => {
        expect(route.request().postDataJSON()).toEqual({ email: 'buyer@example.test', source: 'home' })
        await new Promise(resolve => setTimeout(resolve, 650))
        return json(route, accepted ? { accepted: true } : { error: 'unavailable' }, accepted ? 200 : 503)
      })
      await page.goto('/')
      await expect(page.getByRole('heading', { name: 'The first events are on their way.' })).toBeVisible()
      await page.evaluate(() => document.fonts.ready)
      const band = page.locator('section').filter({ has: page.getByRole('heading', { name: 'Get event alerts on Guam' }) }).first()
      const email = band.getByRole('textbox', { name: 'Email for event alerts' })
      await email.fill('buyer@example.test')
      const before = await band.boundingBox()
      await email.press('Enter')
      await expect(band.getByRole(accepted ? 'status' : 'alert')).toBeVisible()
      const after = await band.boundingBox()
      expect(after.height).toBe(before.height)
      expect(after.y).toBe(before.y)
      if (accepted) {
        await expect(email).not.toBeVisible()
        await expect(band.getByRole('button', { name: 'Subscribe' })).toHaveCount(0)
      } else {
        await expect(email).toHaveValue('buyer@example.test')
        await expect(band.getByRole('button', { name: 'Subscribe' })).toBeEnabled()
      }
    })
  }
}
