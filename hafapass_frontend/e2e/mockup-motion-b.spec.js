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

test.describe('Option B — Signature Moments checks', () => {
  test.skip(!demoEnabled, 'Runs only against a VITE_HAFAPASS_DEMO_DATA=1 build or deploy preview')

  for (const vp of VIEWPORTS) {
    test(`renders all Option B signature moments cleanly at ${vp.name} with zero overflow`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })

      // 1. Home: 3D double-sided hero pass + flip + pinned 1.4svh tear/QR canvas story
      await page.goto('/')
      const passWrap = page.getByTestId('featured-pass-3d')
      await expect(passWrap).toBeVisible()
      const flipBtn = passWrap.getByRole('button', { name: /Flip to QR back/i })
      await flipBtn.click()
      await expect(passWrap.locator('.featured-pass-body')).toHaveAttribute('data-flipped', 'true')
      await passWrap.getByRole('button', { name: /Flip to event front/i }).click()
      await expect(passWrap.locator('.featured-pass-body')).toHaveAttribute('data-flipped', 'false')

      const story = page.getByTestId('perforated-stub-story')
      await expect(story).toBeVisible()
      await expect(story).toHaveAttribute('data-mode', 'live')
      await expect(story.locator('canvas')).toBeVisible()
      await expectNoHorizontalOverflow(page)

      // 2. Event Detail: desktop cover straighten at 1440px, still at 390px
      await page.goto('/events/copa-de-marianas-2027')
      const cover = page.getByTestId('event-cover-frame')
      await expect(cover).toBeVisible()
      const initialTransform = await cover.evaluate(el => el.style.transform)
      if (vp.width >= 1024) {
        expect(initialTransform).toContain('rotateX(')
      } else {
        expect(initialTransform).toBe('')
      }
      await expectNoHorizontalOverflow(page)

      // 3. Confirmation: notched punched pass row with glint + Open ticket clickable immediately
      await page.goto('/orders/demo-copa-2027/confirmation')
      await expect(page.getByTestId('order-confirmed-badge')).toBeVisible()
      await expect(page.locator('[data-punched="true"]').first()).toBeVisible()
      await expect(page.getByRole('link', { name: /open ticket/i }).first()).toBeVisible()
      await expectNoHorizontalOverflow(page)

      // 4. /host: 400ms scan laser + live check-in counter
      await page.goto('/host')
      await expect(page.getByTestId('door-checked-count')).toHaveText('186')
      await page.getByRole('button', { name: /Free Alumni Ticket/i }).click()
      await expect(page.locator('[data-door-state="alumni-hold"]')).toBeVisible({ timeout: 2000 })
      await page.getByRole('button', { name: /Confirm & Admit/i }).click()
      await expect(page.getByTestId('door-checked-count')).toHaveText('187')
      await expectNoHorizontalOverflow(page)
    })
  }

  test('honors prefers-reduced-motion with unpinned still story and instant states', async ({ browser }) => {
    const context = await browser.newContext({ reducedMotion: 'reduce', viewport: { width: 390, height: 844 } })
    const page = await context.newPage()

    await page.goto('/')
    const story = page.getByTestId('perforated-stub-story')
    await expect(story).toHaveAttribute('data-mode', 'still')
    await expect(story).toHaveAttribute('data-step', 'done')
    await expectNoHorizontalOverflow(page)

    await page.goto('/events/copa-de-marianas-2027')
    const cover = page.getByTestId('event-cover-frame')
    await expect(cover).toBeVisible()
    expect(await cover.evaluate(el => el.style.transform)).toBe('')
    await expectNoHorizontalOverflow(page)

    await page.goto('/host')
    await page.getByRole('button', { name: /Free Alumni Ticket/i }).click()
    await expect(page.locator('[data-door-state="alumni-hold"]')).toBeVisible()
    await expectNoHorizontalOverflow(page)

    await context.close()
  })
})
