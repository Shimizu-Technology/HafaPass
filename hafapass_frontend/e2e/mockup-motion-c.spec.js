import { env } from 'node:process'
import { expect, test } from '@playwright/test'

const demoEnabled = env.VITE_HAFAPASS_DEMO_DATA === '1' || Boolean(env.DEMO_PREVIEW_BASE_URL)

const VIEWPORTS = [
  { name: '390px', width: 390, height: 844 },
  { name: '1440px', width: 1440, height: 900 },
]

async function expectNoHorizontalOverflow(page) {
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
  expect(overflow).toBeLessThanOrEqual(1)
}

test.describe('Option C — Bold Extras checks', () => {
  test.skip(!demoEnabled, 'Runs only against a VITE_HAFAPASS_DEMO_DATA=1 build or deploy preview')

  for (const vp of VIEWPORTS) {
    test(`renders Guam village pins, flickable stub deck, kinetic cover, and price odometer at ${vp.name}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })

      // 1. Home: Guam village pin + flickable event stub deck above the regular event grid
      await page.goto('/')
      const deck = page.getByTestId('guam-stub-deck')
      await expect(deck).toBeVisible()
      await expect(deck.getByTestId('deck-counter')).toHaveText(/Event 1 of \d+/)
      await deck.getByRole('button', { name: /Next event stub/i }).click()
      await expect(deck.getByTestId('deck-counter')).toHaveText(/Event 2 of \d+/)
      await expectNoHorizontalOverflow(page)

      // 2. Event Detail: desktop clip-path expanding cover + rolling price odometer
      await page.goto('/events/copa-de-marianas-2027')
      const cover = page.getByTestId('event-cover-frame')
      await expect(cover).toBeVisible()
      const clipPath = await cover.evaluate(el => el.style.clipPath)
      if (vp.width >= 1024) {
        expect(clipPath).toContain('inset(')
      } else {
        expect(clipPath).toBe('')
      }
      const incBtn = page.getByRole('button', { name: /increase quantity for adult spectator/i })
      await incBtn.click()
      await expect(page.getByTestId('price-odometer')).toBeVisible()
      await expect(page.getByRole('button', { name: /buy tickets/i })).toContainText('$16.75')
      await incBtn.click()
      await expect(page.getByRole('button', { name: /buy tickets/i })).toContainText('$33.50')
      await expectNoHorizontalOverflow(page)
    })
  }

  test('honors prefers-reduced-motion cleanly on Option C moments', async ({ browser }) => {
    const context = await browser.newContext({ reducedMotion: 'reduce', viewport: { width: 390, height: 844 } })
    const page = await context.newPage()

    await page.goto('/')
    const deck = page.getByTestId('guam-stub-deck')
    await expect(deck).toBeVisible()
    await deck.getByRole('button', { name: /Next event stub/i }).click()
    await expect(deck.getByTestId('deck-counter')).toHaveText(/Event 2 of \d+/)
    await expectNoHorizontalOverflow(page)

    await page.goto('/events/copa-de-marianas-2027')
    const cover = page.getByTestId('event-cover-frame')
    expect(await cover.evaluate(el => el.style.clipPath)).toBe('')
    await page.getByRole('button', { name: /increase quantity for adult spectator/i }).click()
    await expect(page.getByTestId('price-odometer')).toHaveCount(0)
    await expect(page.getByRole('button', { name: /buy tickets/i })).toContainText('$16.75')
    await expectNoHorizontalOverflow(page)

    await context.close()
  })
})
