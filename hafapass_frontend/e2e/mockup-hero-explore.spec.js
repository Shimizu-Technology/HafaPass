import { env } from 'node:process'
import { expect, test } from '@playwright/test'

const demoEnabled = env.VITE_HAFAPASS_DEMO_DATA === '1' || Boolean(env.DEMO_PREVIEW_BASE_URL)
const VARIANTS = [1, 2, 3, 4]
const VIEWPORTS = [
  { name: 'mobile-375', width: 375, height: 812 },
  { name: 'mobile-390', width: 390, height: 844 },
  { name: 'mobile-430', width: 430, height: 932 },
  { name: 'desktop-1440', width: 1440, height: 900 },
]

test.describe('hero exploration variants (?hero=1..4)', () => {
  test.skip(!demoEnabled, 'Runs only against a VITE_HAFAPASS_DEMO_DATA=1 build or deploy preview')

  for (const vp of VIEWPORTS) {
    test(`all 4 hero variants render cleanly with zero overflow and >=44px tap targets at ${vp.name}`, async ({ page }) => {
      const consoleErrors = []
      const pageErrors = []
      page.on('console', msg => {
        if (msg.type() !== 'error') return
        const text = msg.text()
        // Netlify injects its Collaborate preview drawer iframe from app.netlify.com,
        // which logs a report-only CSP notice unrelated to HåfaPass.
        if (text.includes('app.netlify.com')) return
        consoleErrors.push(text)
      })
      page.on('pageerror', err => pageErrors.push(err.message))

      await page.setViewportSize({ width: vp.width, height: vp.height })

      for (const variant of VARIANTS) {
        await page.goto(`/?hero=${variant}`)
        const hero = page.locator(`section[data-hero-variant="${variant}"]`)
        await expect(hero).toBeVisible()

        // Headline stays visible at opacity 1 (LCP-safe)
        const h1 = hero.locator('h1')
        await expect(h1).toBeVisible()
        const h1Opacity = await h1.evaluate(el => Number.parseFloat(getComputedStyle(el).opacity))
        expect(h1Opacity).toBe(1)

        // Zero horizontal overflow
        const overflow = await page.evaluate(() => ({
          scrollWidth: document.documentElement.scrollWidth,
          innerWidth: window.innerWidth,
        }))
        expect(overflow.scrollWidth, `overflow on hero ${variant} at ${vp.name}`).toBeLessThanOrEqual(overflow.innerWidth)

        // Variant-specific presence & no 3D matrix transforms
        if (variant === 1) {
          const pass = hero.locator('.featured-pass')
          await expect(pass).toBeVisible()
          const transform = await pass.evaluate(el => getComputedStyle(el).transform)
          expect(transform).not.toContain('matrix3d')
        } else if (variant === 2) {
          const deck = hero.getByTestId('hero-fanned-deck')
          await expect(deck).toBeVisible()
          const frontCard = deck.locator('.hero-deck-card-front')
          const transform = await frontCard.evaluate(el => getComputedStyle(el).transform)
          expect(transform).not.toContain('matrix3d')
        } else if (variant === 3) {
          await expect(hero.getByRole('link', { name: /Browse events/i })).toBeVisible()
          await expect(hero.getByTestId('hero-event-marquee')).toBeVisible()
        } else if (variant === 4) {
          const island = hero.getByTestId('hero-island-pass')
          await expect(island).toBeVisible()
          const pass = island.locator('.featured-pass')
          const transform = await pass.evaluate(el => getComputedStyle(el).transform)
          expect(transform).not.toContain('matrix3d')
        }

        // Switcher buttons & hero controls meet >=44px tap target minimum
        const switcher = page.getByTestId('hero-variant-switcher')
        await expect(switcher).toBeVisible()
        const switcherBox = await switcher.boundingBox()
        expect(switcherBox.x).toBeGreaterThanOrEqual(0)
        expect(switcherBox.x + switcherBox.width).toBeLessThanOrEqual(vp.width + 1)

        const buttons = switcher.locator('button')
        const buttonCount = await buttons.count()
        expect(buttonCount).toBe(4)
        for (let i = 0; i < buttonCount; i += 1) {
          const box = await buttons.nth(i).boundingBox()
          expect(box.height, `switcher btn ${i + 1} height at ${vp.name}`).toBeGreaterThanOrEqual(44)
          expect(box.width, `switcher btn ${i + 1} width at ${vp.name}`).toBeGreaterThanOrEqual(44)
        }
      }

      // Interactive switcher updates ?hero= param
      await page.goto('/')
      await expect(page.locator('section[data-hero-variant="1"]')).toBeVisible()
      await page.getByTestId('hero-variant-switcher').getByRole('button', { name: /Hero 2/i }).click()
      await expect(page).toHaveURL(/\?hero=2/)
      await expect(page.getByTestId('hero-fanned-deck')).toBeVisible()

      expect(consoleErrors).toEqual([])
      expect(pageErrors).toEqual([])
    })
  }

  test('all 4 hero variants stay static under prefers-reduced-motion: reduce', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' })
    await page.setViewportSize({ width: 390, height: 844 })

    for (const variant of VARIANTS) {
      await page.goto(`/?hero=${variant}`)
      const hero = page.locator(`section[data-hero-variant="${variant}"]`)
      await expect(hero).toBeVisible()

      const wordAnim = await hero.locator('.hero-rise-word').first().evaluate(el => getComputedStyle(el).animationName)
      expect(wordAnim).toBe('none')

      if (variant === 2) {
        const deck = hero.getByTestId('hero-fanned-deck')
        await expect(deck).toHaveAttribute('data-paused', 'true')
        await expect(deck).toHaveAttribute('data-active-index', '0')
      } else if (variant === 3) {
        const marquee = hero.getByTestId('hero-event-marquee')
        await expect(marquee).toHaveAttribute('data-static', 'true')
        const trackAnim = await marquee.locator('.hero-marquee-track').evaluate(el => getComputedStyle(el).animationName)
        expect(trackAnim).toBe('none')
      } else if (variant === 4) {
        const island = hero.getByTestId('hero-island-pass')
        await expect(island).toHaveAttribute('data-qr-settled', 'true')
      }
    }
  })
})
