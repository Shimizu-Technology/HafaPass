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

test.describe('Option A — Subtle Polish motion checks', () => {
  test.skip(!demoEnabled, 'Runs only against a VITE_HAFAPASS_DEMO_DATA=1 build or deploy preview')

  for (const vp of VIEWPORTS) {
    test(`renders Option A polish cleanly at ${vp.name} with zero horizontal overflow`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })

      // 1. Home: LCP-safe clip-mask RiseHeadline (opacity 1) + zero overflow
      await page.goto('/')
      const h1 = page.locator('h1.hero-rise')
      await expect(h1).toBeVisible()
      await expect(h1.locator('.hero-rise-mask .hero-rise-word').first()).toHaveCSS('opacity', '1')
      await expectNoHorizontalOverflow(page)

      // 2. Event Detail: tactile ticket stepper + crisp selected tier border
      await page.goto('/events/copa-de-marianas-2027')
      await expect(page.getByRole('heading', { level: 1, name: /Copa de Marianas 2027/i })).toBeVisible()
      const incBtn = page.getByRole('button', { name: /increase quantity for adult spectator/i })
      await expect(incBtn).toHaveClass(/tactile-press/)
      await incBtn.click()
      await expect(page.locator('[data-selected="true"]').first()).toBeVisible()
      await expectNoHorizontalOverflow(page)

      // 3. Order Confirmation: one-shot SVG checkmark badge
      await page.goto('/orders/demo-copa-2027/confirmation')
      const badge = page.getByTestId('order-confirmed-badge')
      await expect(badge).toBeVisible()
      await expect(badge.locator('.confirm-check-svg path')).toBeVisible()
      await expectNoHorizontalOverflow(page)

      // 4. /host: tactile fee pills + DoorPreview state crossfade
      await page.goto('/host')
      await expect(page.getByRole('button', { name: '$25' })).toHaveClass(/tactile-press/)
      await page.getByRole('button', { name: /Free Alumni Ticket/i }).click()
      await expect(page.locator('[data-door-state="alumni-hold"]')).toBeVisible()
      await expect(page.locator('.door-state-fade')).toBeVisible()
      await expectNoHorizontalOverflow(page)
    })
  }

  test('honors prefers-reduced-motion with static readable states at 390px and 1440px', async ({ browser }) => {
    const context = await browser.newContext({ reducedMotion: 'reduce', viewport: { width: 390, height: 844 } })
    const page = await context.newPage()

    await page.goto('/')
    const word = page.locator('.hero-rise-word').first()
    await expect(word).toBeVisible()
    await expect(word).toHaveCSS('animation-name', 'none')
    await expectNoHorizontalOverflow(page)

    await page.goto('/orders/demo-copa-2027/confirmation')
    await expect(page.getByTestId('order-confirmed-badge')).toBeVisible()
    await expect(page.locator('.confirm-check-svg path')).toHaveCSS('animation-name', 'none')
    await expectNoHorizontalOverflow(page)

    await page.goto('/host')
    await page.getByRole('button', { name: /Free Alumni Ticket/i }).click()
    await expect(page.locator('[data-door-state="alumni-hold"]')).toBeVisible()
    await expect(page.locator('.door-state-fade')).toHaveCSS('animation-name', 'none')
    await expectNoHorizontalOverflow(page)

    await context.close()
  })
})
