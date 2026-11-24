import { env } from 'node:process'
import { expect, test } from '@playwright/test'

const demoEnabled = env.VITE_HAFAPASS_DEMO_DATA === '1' || Boolean(env.DEMO_PREVIEW_BASE_URL)

const VIEWPORTS = [
  { name: '375px', width: 375, height: 667 },
  { name: '390px', width: 390, height: 844 },
  { name: '430px', width: 430, height: 932 },
  { name: '1440px', width: 1440, height: 900 },
]

async function expectNoHorizontalOverflow(page) {
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
  expect(overflow).toBeLessThanOrEqual(1)
}

async function expectAllChipRowsSingleLine(page) {
  const violations = await page.evaluate(() => {
    const rows = Array.from(document.querySelectorAll('[data-chip-row="true"]'))
    const bad = []
    for (const row of rows) {
      const style = getComputedStyle(row)
      if (style.display === 'none' || row.offsetParent === null) continue
      const children = Array.from(row.children).filter(el => el.getBoundingClientRect().height > 0)
      if (children.length < 2) continue
      const tops = children.map(el => Math.round(el.getBoundingClientRect().top))
      const minTop = Math.min(...tops)
      const maxTop = Math.max(...tops)
      if (maxTop - minTop > 8) {
        bad.push({ label: row.getAttribute('aria-label') || row.className, tops })
      }
    }
    return bad
  })
  expect(violations).toEqual([])
}

function isPureTranslateOrNone(transform) {
  if (!transform || transform === 'none') return true
  const m = transform.match(/^matrix\(([^)]+)\)$/)
  if (!m) return false
  const [a, b, c, d] = m[1].split(',').map(v => Number(v.trim()))
  return Math.abs(a - 1) < 0.001 && Math.abs(b) < 0.001 && Math.abs(c) < 0.001 && Math.abs(d - 1) < 0.001
}

async function measureHeroHeadline(page) {
  return page.evaluate(() => {
    const h1 = document.querySelector('h1.hero-rise')
    if (!h1) return null
    const cs = getComputedStyle(h1)
    const rect = h1.getBoundingClientRect()
    const range = document.createRange()
    range.selectNodeContents(h1)
    const lineTops = [...new Set(Array.from(range.getClientRects()).filter(r => r.width > 1).map(r => Math.round(r.top)))]
    return {
      fontSize: cs.fontSize,
      maxWidth: cs.maxWidth,
      width: Math.round(rect.width),
      height: Math.round(rect.height),
      lineCount: lineTops.length,
    }
  })
}

test.describe('Mockup E — Smooth Deck Hero + Clean Home Flow', () => {
  test.skip(!demoEnabled, 'Runs only against a VITE_HAFAPASS_DEMO_DATA=1 build or deploy preview')

  for (const vp of VIEWPORTS) {
    test(`meets all layout, deck, cover badge, single-line chip, and no-reflow gates at ${vp.name}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })

      // 1. Fresh load: prove zero h1 reflow across t=0, 100ms, 300ms, and settled.
      await page.goto('/', { waitUntil: 'domcontentloaded' })
      const h1 = page.locator('h1.hero-rise')
      await expect(h1).toBeVisible()
      const t0 = await measureHeroHeadline(page)
      await page.waitForTimeout(100)
      const t100 = await measureHeroHeadline(page)
      await page.waitForTimeout(200)
      const t300 = await measureHeroHeadline(page)
      await page.waitForTimeout(450)
      const settled = await measureHeroHeadline(page)

      expect(t0.lineCount).toBe(2)
      expect(t100.lineCount).toBe(t0.lineCount)
      expect(t300.lineCount).toBe(t0.lineCount)
      expect(settled.lineCount).toBe(t0.lineCount)
      expect(t100.height).toBe(t0.height)
      expect(t300.height).toBe(t0.height)
      expect(settled.height).toBe(t0.height)
      expect(settled.width).toBe(t0.width)

      // 2. Hero deck: first card is HåfaPass default ticket, all cards identical height, swipe advances.
      const deck = page.getByTestId('hero-fanned-deck')
      await expect(deck).toBeVisible()
      await expect(deck).toHaveAttribute('data-active-index', '0')
      await expect(deck).toHaveAttribute('data-card-count', '4')
      await expect(deck.locator('[data-front="true"]')).toHaveAttribute('data-card-kind', 'brand')
      await expect(deck.getByTestId('hero-brand-card')).toContainText('Your pass to what’s on across Guam')

      // All cards in the stack share the exact same outer height.
      const cardHeights = await deck.locator('.hero-deck-card').evaluateAll(els =>
        els.map(el => Math.round(el.getBoundingClientRect().height / (getComputedStyle(el).transform === 'none' ? 1 : 1))),
      )
      // Check unscaled offsetHeight matches across all cards.
      const offsetHeights = await deck.locator('.hero-deck-card').evaluateAll(els => els.map(el => el.offsetHeight))
      expect(new Set(offsetHeights).size).toBe(1)
      expect(cardHeights.length).toBe(4)

      // Controls >= 44px.
      const nextBtn = deck.getByRole('button', { name: 'Next featured pass' })
      const prevBtn = deck.getByRole('button', { name: 'Previous featured pass' })
      expect((await nextBtn.boundingBox()).height).toBeGreaterThanOrEqual(44)
      expect((await nextBtn.boundingBox()).width).toBeGreaterThanOrEqual(44)
      expect((await prevBtn.boundingBox()).height).toBeGreaterThanOrEqual(44)

      // Swipe gesture moves to card 1 (Copa).
      const stageBox = await deck.locator('.hero-deck-stage').boundingBox()
      await page.mouse.move(stageBox.x + stageBox.width * 0.75, stageBox.y + stageBox.height * 0.4)
      await page.mouse.down()
      await page.mouse.move(stageBox.x + stageBox.width * 0.2, stageBox.y + stageBox.height * 0.4, { steps: 10 })
      await page.mouse.up()
      await expect(deck).toHaveAttribute('data-active-index', '1')
      await expect(deck.locator('[data-front="true"]')).toContainText('From $11.50')
      await expect(deck.locator('[data-front="true"]')).toContainText('Free tickets available')
      await page.waitForTimeout(700)
      await expectNoHorizontalOverflow(page)

      // 3. Cover art: all visible event covers keep 16:9 ratio (~1.778) so badges are never cropped.
      const coverRatios = await page.locator('img[src^="data:image/svg+xml"]').evaluateAll(imgs =>
        imgs.map(img => {
          const r = img.getBoundingClientRect()
          return r.height > 0 ? Number((r.width / r.height).toFixed(2)) : 0
        }).filter(ratio => ratio > 0),
      )
      expect(coverRatios.length).toBeGreaterThan(0)
      for (const ratio of coverRatios) {
        expect(ratio).toBeGreaterThanOrEqual(1.7)
        expect(ratio).toBeLessThanOrEqual(1.85)
      }

      // 4. Separate "Featured on Guam" stub deck is gone; quick filters filter carousel in place.
      await expect(page.getByTestId('event-stub-deck')).toHaveCount(0)
      await expect(page.getByRole('heading', { name: 'Featured on Guam' })).toHaveCount(0)
      await expectAllChipRowsSingleLine(page)
      await expectNoHorizontalOverflow(page)

      const mangilaoChip = page.getByRole('group', { name: 'Quick filters' }).getByRole('button', { name: 'Mangilao' })
      await mangilaoChip.click()
      await expect(mangilaoChip).toHaveAttribute('aria-pressed', 'true')
      const filteredCards = await page.getByRole('list', { name: 'Coming up on Guam' }).locator('li').count()
      expect(filteredCards).toBe(3)
      await mangilaoChip.click()
      await expect(mangilaoChip).toHaveAttribute('aria-pressed', 'false')

      // 5. QR story settles dead straight.
      const story = page.getByTestId('perforated-stub-story')
      await expect(story).toBeVisible()
      if (vp.height < 680) {
        await expect(story).toHaveAttribute('data-mode', 'still')
      } else {
        await story.evaluate(el => {
          const rect = el.getBoundingClientRect()
          window.scrollTo({ top: window.scrollY + rect.top + el.offsetHeight - window.innerHeight + 40, behavior: 'instant' })
        })
        await page.waitForTimeout(450)
      }
      expect(isPureTranslateOrNone(await page.getByTestId('stub-story-stub').evaluate(el => getComputedStyle(el).transform))).toBe(true)
      expect(isPureTranslateOrNone(await page.getByTestId('stub-story-admitted').evaluate(el => getComputedStyle(el).transform))).toBe(true)
    })
  }

  for (const vp of [{ name: '390px', width: 390, height: 844 }, { name: '1440px', width: 1440, height: 900 }]) {
    test(`keeps hero headline identical on fresh load, in-app navigation back, and browser Back at ${vp.name}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await page.goto('/')
      await expect(page.locator('h1.hero-rise')).toBeVisible()
      await page.waitForTimeout(700)
      const fresh = await measureHeroHeadline(page)
      expect(fresh.lineCount).toBe(2)

      // Navigate to /events and back via in-app logo link.
      await page.getByRole('link', { name: 'See all' }).click()
      await expect(page).toHaveURL(/\/events$/)
      await page.locator('header a[href="/"]').first().click()
      await expect(page).toHaveURL(/\/$/)
      await expect(page.locator('h1.hero-rise')).toBeVisible()
      await page.waitForTimeout(700)
      const afterInAppBack = await measureHeroHeadline(page)
      expect(afterInAppBack).toEqual(fresh)

      // Navigate to an event detail page and return via browser Back.
      await page.getByRole('list', { name: 'Coming up on Guam' }).locator('a').first().click()
      await expect(page).toHaveURL(/\/events\//)
      await page.goBack()
      await expect(page).toHaveURL(/\/$/)
      await expect(page.locator('h1.hero-rise')).toBeVisible()
      await page.waitForTimeout(700)
      const afterBrowserBack = await measureHeroHeadline(page)
      expect(afterBrowserBack).toEqual(fresh)
    })
  }

  test('honors prefers-reduced-motion with static headline, no deck auto-advance, and instant swaps', async ({ browser }) => {
    const context = await browser.newContext({ reducedMotion: 'reduce', viewport: { width: 390, height: 844 } })
    const page = await context.newPage()

    await page.goto('/')
    const h1 = page.locator('h1.hero-rise')
    await expect(h1).toBeVisible()
    await expect(h1).toHaveCSS('animation-name', 'none')

    const deck = page.getByTestId('hero-fanned-deck')
    await expect(deck).toHaveAttribute('data-paused', 'true')
    await expect(deck).toHaveAttribute('data-active-index', '0')
    await deck.getByRole('button', { name: 'Next featured pass' }).click()
    await expect(deck).toHaveAttribute('data-active-index', '1')
    await expect(deck.locator('[data-exiting="true"]')).toHaveCount(0)

    const story = page.getByTestId('perforated-stub-story')
    await expect(story).toHaveAttribute('data-mode', 'still')
    await expect(story).toHaveAttribute('data-step', 'done')
    await expectNoHorizontalOverflow(page)

    await context.close()
  })
})
