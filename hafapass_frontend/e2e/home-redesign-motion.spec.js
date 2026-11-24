import { expect, test } from '@playwright/test'
for (const restore of [false, true]) test(`WAAPI exit survives empty inventory${restore ? ' and reload' : ''}`, async ({ page }) => {
  await page.goto('/e2e/fixtures/deck-race.html')
  const deck = page.getByTestId('hero-fanned-deck')
  await expect(deck).toHaveAttribute('data-card-count', '4')
  const observed = await page.evaluate(() => new Promise(resolve => {
    document.querySelector('button[aria-label="Next featured pass"]').click()
    setTimeout(() => {
      const count = document.querySelector('[data-exiting="true"]').getAnimations().length
      window.setDeckInventory(false)
      resolve(count)
    }, 60)
  }))
  expect(observed).toBeGreaterThan(0) // This regression must exercise real WAAPI.
  await expect(deck).toHaveAttribute('data-card-count', '1')
  if (restore) {
    await page.evaluate(() => window.setDeckInventory(true))
    await expect(deck).toHaveAttribute('data-card-count', '4')
  }
  const brand = deck.locator('[data-card-kind="brand"]')
  await expect(brand).toHaveAttribute('data-front', 'true')
  await expect(brand).toHaveCSS('opacity', '1')
  await expect.poll(() => brand.evaluate(el => el.getAnimations().length)).toBe(0)
  await expect(brand.locator('.ticket')).toHaveCSS('visibility', 'visible')
})
