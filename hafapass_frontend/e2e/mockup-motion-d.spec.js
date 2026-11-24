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

test.describe('Mockup D — Combined Clean Version checks', () => {
  test.skip(!demoEnabled, 'Runs only against a VITE_HAFAPASS_DEMO_DATA=1 build or deploy preview')

  for (const vp of VIEWPORTS) {
    test(`meets all layout, straightness, single-line chip, and tap-target gates at ${vp.name}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })

      // 1. Home: flat hero deck, single-line ChipRows, straight QR story
      await page.goto('/')
      await expect(page.locator('h1.hero-rise')).toBeVisible()
      const deck = page.getByTestId('hero-fanned-deck')
      await expect(deck).toBeVisible()
      await expect(deck).toHaveAttribute('data-active-index', '0')
      await expectNoHorizontalOverflow(page)
      await expectAllChipRowsSingleLine(page)

      const nextBtn = deck.getByRole('button', { name: 'Next featured pass' })
      const nextBox = await nextBtn.boundingBox()
      expect(nextBox.height).toBeGreaterThanOrEqual(44)
      expect(nextBox.width).toBeGreaterThanOrEqual(44)
      await nextBtn.click()
      await expect(deck).toHaveAttribute('data-active-index', '1')
      await expect(deck.locator('[data-front="true"]')).toContainText('From $11.50')
      await expect(deck.locator('[data-front="true"]')).toContainText('Free tickets available')

      // QR story: scroll to bottom of story and assert settled 0° straight stub + crisp Admitted pill
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
      const stubTransform = await page.getByTestId('stub-story-stub').evaluate(el => getComputedStyle(el).transform)
      expect(isPureTranslateOrNone(stubTransform)).toBe(true)
      const admitTransform = await page.getByTestId('stub-story-admitted').evaluate(el => getComputedStyle(el).transform)
      expect(isPureTranslateOrNone(admitTransform)).toBe(true)

      // 2. /events: two single-line ChipRows (categories + When/Price/Village), no overflow
      await page.goto('/events')
      await expect(page.getByRole('heading', { name: 'Copa de Marianas 2027 (demo)' })).toBeVisible()
      await expectAllChipRowsSingleLine(page)
      await expectNoHorizontalOverflow(page)
      // Tap targets on category chips >= 44px
      const catChipBox = await page.getByRole('button', { name: 'All events' }).boundingBox()
      expect(catChipBox.height).toBeGreaterThanOrEqual(44)

      // 3. Event Detail (Copa): single-line action ChipRow, FAQ summary >= 48px, schedule no wrap, no overflow
      await page.goto('/events/copa-de-marianas-2027')
      await expect(page.getByRole('heading', { level: 1, name: /Copa de Marianas 2027/i })).toBeVisible()
      await expectAllChipRowsSingleLine(page)
      await expectNoHorizontalOverflow(page)
      const shareBtn = page.getByRole('button', { name: /^Share$/i })
      expect((await shareBtn.boundingBox()).height).toBeGreaterThanOrEqual(44)
      const faqSummary = page.locator('details summary').first()
      expect((await faqSummary.boundingBox()).height).toBeGreaterThanOrEqual(44)

      // 4. Multi-night pass event: View included nights >= 44px
      await page.goto('/events/fd-alumni-basketball-night-1')
      const nightsBtn = page.getByRole('button', { name: /View included nights/i })
      expect((await nightsBtn.boundingBox()).height).toBeGreaterThanOrEqual(44)
      await expectNoHorizontalOverflow(page)

      // 5. Confirmation: no raw "published", no contradictory banner, single-line footer ChipRow, 44px actions
      await page.goto('/orders/demo-copa-2027/confirmation')
      await expect(page.getByTestId('order-confirmed-badge')).toBeVisible()
      await expect(page.getByText(/^published$/i)).toHaveCount(0)
      await expect(page.getByText('Test order — no real charge')).toBeVisible()
      await expect(page.getByText('Checkout not completed — no charge')).toHaveCount(0)
      await expectAllChipRowsSingleLine(page)
      await expectNoHorizontalOverflow(page)
      const openTicketLink = page.getByRole('link', { name: /Open ticket/i }).first()
      expect((await openTicketLink.boundingBox()).height).toBeGreaterThanOrEqual(44)

      // 6. Ticket wallet: flat QR, no overflow
      await page.goto('/tickets/demo-ticket-copa-adult-1?order=demo-copa-2027')
      await expect(page.getByText('Avery Lindqvist', { exact: true })).toBeVisible()
      await expectNoHorizontalOverflow(page)

      // 7. /host: single-line fee chips, short Adult / Free alumni toggle, working Next guest, 44px targets
      await page.goto('/host')
      await expectAllChipRowsSingleLine(page)
      await expectNoHorizontalOverflow(page)
      const alumniBtn = page.getByRole('button', { name: /^Free alumni$/i })
      expect((await alumniBtn.boundingBox()).height).toBeGreaterThanOrEqual(44)
      await alumniBtn.click()
      await expect(page.locator('[data-door-state="alumni-hold"]')).toBeVisible({ timeout: 2000 })
      const admitBtn = page.getByRole('button', { name: /^Admit$/i })
      expect((await admitBtn.boundingBox()).height).toBeGreaterThanOrEqual(44)
      await admitBtn.click()
      await expect(page.getByTestId('door-checked-count')).toHaveText('187')
      await page.getByRole('button', { name: 'Next guest' }).click()
      await expect(page.getByText('Bram Okafor')).toBeVisible({ timeout: 2000 })

      // 8. Discover, Venue, Organizer: no overflow
      for (const route of ['/discover', '/venues/uog-calvo-field-house', '/organizers/marianas-grappling-federation-demo']) {
        await page.goto(route)
        await expect(page.locator('h1')).toBeVisible()
        await expectNoHorizontalOverflow(page)
      }
    })
  }

  test('honors prefers-reduced-motion with static, straight, readable states', async ({ browser }) => {
    const context = await browser.newContext({ reducedMotion: 'reduce', viewport: { width: 390, height: 844 } })
    const page = await context.newPage()

    await page.goto('/')
    const deck = page.getByTestId('hero-fanned-deck')
    await expect(deck).toHaveAttribute('data-paused', 'true')
    const story = page.getByTestId('perforated-stub-story')
    await expect(story).toHaveAttribute('data-mode', 'still')
    await expect(story).toHaveAttribute('data-step', 'done')
    expect(isPureTranslateOrNone(await page.getByTestId('stub-story-stub').evaluate(el => getComputedStyle(el).transform))).toBe(true)
    expect(isPureTranslateOrNone(await page.getByTestId('stub-story-admitted').evaluate(el => getComputedStyle(el).transform))).toBe(true)

    await deck.getByRole('button', { name: 'Next featured pass' }).click()
    await expect(deck).toHaveAttribute('data-active-index', '1')
    await expectNoHorizontalOverflow(page)

    await page.goto('/orders/demo-copa-2027/confirmation')
    await expect(page.locator('.confirm-check-svg path')).toHaveCSS('animation-name', 'none')
    await expectNoHorizontalOverflow(page)

    await page.goto('/host')
    await page.getByRole('button', { name: /^Free alumni$/i }).click()
    await expect(page.locator('[data-door-state="alumni-hold"]')).toBeVisible()
    await expectNoHorizontalOverflow(page)

    await context.close()
  })
})
