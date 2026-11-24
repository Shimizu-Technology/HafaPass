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
      await expect(deck.getByTestId('hero-brand-card')).toContainText('Guam · Digital pass')
      await expect(deck.getByTestId('hero-brand-card')).toContainText('Arrives by email in seconds')
      await expect(deck.getByTestId('hero-brand-card')).not.toContainText('All dates in Guam time.')
      await expect(deck.getByTestId('hero-brand-card')).not.toContainText('No account needed')
      await expect(deck.getByTestId('hero-deck-controls')).not.toContainText('1 / 4')

      // S4: Active dot is 20px pill, inactive dots are 8px circles (no scaleX squash).
      const dotWidths = await deck.locator('.hero-deck-dot').evaluateAll(els =>
        els.map(el => ({
          active: el.dataset.active === 'true',
          width: Math.round(el.getBoundingClientRect().width),
          transform: getComputedStyle(el).transform,
        })),
      )
      expect(dotWidths.find(d => d.active)?.width).toBe(20)
      for (const dot of dotWidths.filter(d => !d.active)) {
        expect(dot.width).toBe(8)
        expect(dot.transform).toBe('none')
      }

      // S6 & S10: No redundant phone toggle; desktop (1440) places search inside hero left column.
      if (vp.width < 640) {
        await expect(page.getByRole('button', { name: 'Choose a date or village' })).toHaveCount(0)
      }
      if (vp.width >= 1024) {
        await expect(page.getByTestId('home-hero-section').locator('form[role="search"]')).toBeVisible()
      }

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

      // 5. QR story settles dead straight and uses the neutral example pass (S5).
      const story = page.getByTestId('perforated-stub-story')
      await expect(story).toBeVisible()
      await expect(story).toContainText('Your night out')
      await expect(story).not.toContainText('Copa de Marianas')
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

  test('M1 & S1 & S3: keeps outgoing card opaque until 60% of glide, back cards solid with dark-teal veil, and zero opacity leak', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 })
    await page.goto('/')
    const deck = page.getByTestId('hero-fanned-deck')
    await expect(deck).toHaveAttribute('data-card-count', '4')
    await page.waitForTimeout(300)

    // Verify S1: solid dark-teal back veil and depth-1 scale clears the 14px notch.
    const restCheck = await deck.evaluate(root => {
      const stageWidth = root.querySelector('.hero-deck-stage').getBoundingClientRect().width
      const depth1 = root.querySelector('.hero-deck-card[data-depth="1"]')
      const veilBg = getComputedStyle(depth1.querySelector('.hero-deck-back-veil')).backgroundColor
      const depth1Width = depth1.getBoundingClientRect().width
      const sideInset = (stageWidth - depth1Width) / 2
      const cards = Array.from(root.querySelectorAll('.hero-deck-card')).map(el => ({
        depth: Number(el.dataset.depth),
        opacity: Number(getComputedStyle(el).opacity),
      }))
      return { veilBg, sideInset, cards }
    })
    expect(restCheck.veilBg).toBe('rgb(13, 63, 60)')
    expect(restCheck.sideInset).toBeGreaterThanOrEqual(14)
    expect(restCheck.cards.filter(c => c.depth <= 2).every(c => c.opacity === 1)).toBe(true)
    expect(restCheck.cards.find(c => c.depth === 3)?.opacity).toBe(0)

    // Trigger glide and sample every rAF frame for 760ms.
    const trace = await page.evaluate(() => new Promise(resolve => {
      const root = document.querySelector('[data-testid="hero-fanned-deck"]')
      const nextBtn = root.querySelector('button[aria-label="Next featured pass"]')
      const samples = []
      const start = performance.now()
      nextBtn.click()
      const sample = now => {
        const elapsed = now - start
        const exiting = root.querySelector('.hero-deck-card[data-exiting="true"]')
        const front = root.querySelector('.hero-deck-card[data-front="true"]')
        const depth1 = root.querySelector('.hero-deck-card[data-depth="1"]')
        const depth2 = root.querySelector('.hero-deck-card[data-depth="2"]')
        const depth3 = root.querySelector('.hero-deck-card[data-depth="3"]')
        samples.push({
          t: Math.round(elapsed),
          exitingOpacity: exiting ? Number(getComputedStyle(exiting).opacity) : null,
          frontOpacity: front ? Number(getComputedStyle(front).opacity) : null,
          depth1Opacity: depth1 ? Number(getComputedStyle(depth1).opacity) : null,
          depth2Opacity: depth2 ? Number(getComputedStyle(depth2).opacity) : null,
          depth3Opacity: depth3 ? Number(getComputedStyle(depth3).opacity) : null,
        })
        if (elapsed < 760) requestAnimationFrame(sample)
        else resolve(samples)
      }
      requestAnimationFrame(sample)
    }))

    // Outgoing card stays opaque (>= 0.99) through 55% of the 620ms glide (~340ms).
    const earlyExiting = trace.filter(s => s.t >= 30 && s.t <= 340 && s.exitingOpacity !== null)
    expect(earlyExiting.length).toBeGreaterThanOrEqual(3)
    for (const s of earlyExiting) {
      expect(s.exitingOpacity).toBeGreaterThanOrEqual(0.99)
      expect(s.frontOpacity).toBe(1)
      expect(s.depth1Opacity).toBe(1)
    }

    // By the end of the glide, outgoing card fades out and settles to depth 3 at opacity 0 (S3).
    const settledSamples = trace.filter(s => s.t >= 680)
    expect(settledSamples.length).toBeGreaterThan(0)
    for (const s of settledSamples) {
      expect(s.frontOpacity).toBe(1)
      expect(s.depth3Opacity).toBe(0)
    }
  })

  test('M2: keeps dragged card at opacity 1 and fades the next card veil proportionally', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 })
    await page.goto('/')
    const deck = page.getByTestId('hero-fanned-deck')
    await expect(deck).toHaveAttribute('data-card-count', '4')
    await page.waitForTimeout(300)

    const stageBox = await deck.locator('.hero-deck-stage').boundingBox()
    const startX = stageBox.x + stageBox.width * 0.75
    const y = stageBox.y + stageBox.height * 0.4

    await page.mouse.move(startX, y)
    await page.mouse.down()
    await page.mouse.move(startX - 120, y, { steps: 10 })

    const midDrag = await deck.evaluate(root => {
      const front = root.querySelector('.hero-deck-card[data-front="true"]')
      const next = root.querySelector('.hero-deck-card[data-depth="1"]')
      const nextVeil = next.querySelector('.hero-deck-back-veil')
      return {
        frontOpacity: Number(getComputedStyle(front).opacity),
        nextOpacity: Number(getComputedStyle(next).opacity),
        nextVeilOpacity: Number(getComputedStyle(nextVeil).opacity),
      }
    })

    expect(midDrag.frontOpacity).toBe(1)
    expect(midDrag.nextOpacity).toBe(1)
    expect(midDrag.nextVeilOpacity).toBeLessThan(0.65)
    expect(midDrag.nextVeilOpacity).toBeGreaterThan(0.2)

    // Move back under threshold and release so card snaps back cleanly with veil restored.
    await page.mouse.move(startX - 24, y, { steps: 6 })
    await page.mouse.up()
    await page.waitForTimeout(650)

    await expect(deck).toHaveAttribute('data-active-index', '0')
    const afterSnap = await deck.evaluate(root => {
      const front = root.querySelector('.hero-deck-card[data-front="true"]')
      const next = root.querySelector('.hero-deck-card[data-depth="1"]')
      return {
        frontOpacity: Number(getComputedStyle(front).opacity),
        nextVeilOpacity: Number(getComputedStyle(next.querySelector('.hero-deck-back-veil')).opacity),
      }
    })
    expect(afterSnap.frontOpacity).toBe(1)
    expect(afterSnap.nextVeilOpacity).toBe(1)
  })

  for (const vp of VIEWPORTS) {
    test(`M3: hero height stays identical from first paint to settled and after navigation back at ${vp.name}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })

      // Record every hero height observation from the very first painted frame.
      await page.addInitScript(() => {
        window.__heroHeights = []
        const poll = () => {
          const hero = document.querySelector('[data-testid="home-hero-section"]')
          if (hero) {
            const h = Math.round(hero.getBoundingClientRect().height)
            if (h > 0) window.__heroHeights.push(h)
          }
          if (window.__heroHeights.length < 60) requestAnimationFrame(poll)
        }
        requestAnimationFrame(poll)
      })

      await page.goto('/', { waitUntil: 'domcontentloaded' })
      await expect(page.getByTestId('hero-fanned-deck')).toHaveAttribute('data-card-count', '4')
      await page.waitForTimeout(700)

      const firstLoadHeights = await page.evaluate(() => {
        const hero = document.querySelector('[data-testid="home-hero-section"]')
        return {
          samples: window.__heroHeights,
          settled: Math.round(hero.getBoundingClientRect().height),
        }
      })
      expect(firstLoadHeights.samples.length).toBeGreaterThan(0)
      expect(Math.min(...firstLoadHeights.samples)).toBe(firstLoadHeights.settled)
      expect(Math.max(...firstLoadHeights.samples)).toBe(firstLoadHeights.settled)

      // Navigate to /events and back via logo link; verify zero shift and no headline replay (S8).
      await page.getByRole('link', { name: 'See all' }).click()
      await expect(page).toHaveURL(/\/events$/)
      await expect(page.getByRole('heading', { level: 1 })).toBeVisible()
      await page.evaluate(() => { window.__returnHeights = [] })
      await page.locator('header a[href="/"]').first().click()
      await expect(page).toHaveURL(/\/$/)
      const logoReturnHeights = await page.evaluate(() => new Promise(resolve => {
        const list = []
        const start = performance.now()
        const tick = now => {
          const hero = document.querySelector('[data-testid="home-hero-section"]')
          if (hero) list.push(Math.round(hero.getBoundingClientRect().height))
          if (now - start < 700) requestAnimationFrame(tick)
          else resolve(list)
        }
        requestAnimationFrame(tick)
      }))
      expect(Math.min(...logoReturnHeights)).toBe(firstLoadHeights.settled)
      expect(Math.max(...logoReturnHeights)).toBe(firstLoadHeights.settled)
      await expect(page.locator('h1.hero-rise')).toHaveAttribute('data-hero-animate', 'false')

      // Navigate to an event detail and return via browser Back; verify zero shift.
      await page.getByRole('list', { name: 'Coming up on Guam' }).locator('a').first().click()
      await expect(page).toHaveURL(/\/events\//)
      await page.goBack()
      await expect(page).toHaveURL(/\/$/)
      const backReturnHeights = await page.evaluate(() => new Promise(resolve => {
        const list = []
        const start = performance.now()
        const tick = now => {
          const hero = document.querySelector('[data-testid="home-hero-section"]')
          if (hero) list.push(Math.round(hero.getBoundingClientRect().height))
          if (now - start < 700) requestAnimationFrame(tick)
          else resolve(list)
        }
        requestAnimationFrame(tick)
      }))
      expect(Math.min(...backReturnHeights)).toBe(firstLoadHeights.settled)
      expect(Math.max(...backReturnHeights)).toBe(firstLoadHeights.settled)
    })
  }

  test('S2 & S9: pointer tap resumes auto-advance after idle while keyboard focus stays paused, and ticket wallet uses full 16:9 cover', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 })
    await page.goto('/')
    const deck = page.getByTestId('hero-fanned-deck')
    await expect(deck).toHaveAttribute('data-card-count', '4')

    // Simulate a touch tap on Next (dispatches pointerType='touch' + click, moves mouse clear).
    await page.evaluate(() => {
      const btn = document.querySelector('button[aria-label="Next featured pass"]')
      btn.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, pointerType: 'touch' }))
      btn.focus()
      btn.dispatchEvent(new MouseEvent('click', { bubbles: true, detail: 1 }))
    })
    await expect(deck).toHaveAttribute('data-active-index', '1')
    await expect(deck).toHaveAttribute('data-paused', 'true')

    // Resumes after ~6s idle.
    await expect(deck).toHaveAttribute('data-paused', 'false', { timeout: 7500 })

    // Keyboard focus stays paused past 6.5s until focus leaves the deck.
    await page.keyboard.press('Tab')
    await page.evaluate(() => {
      document.querySelector('button[aria-label="Next featured pass"]').focus()
    })
    await expect(deck).toHaveAttribute('data-paused', 'true')
    await page.waitForTimeout(1500)
    await expect(deck).toHaveAttribute('data-paused', 'true')

    // S9: Ticket wallet cover renders at full 16:9 ratio so badges aren't cropped.
    await page.goto('/tickets/demo-ticket-copa-adult-1?order=demo-copa-2027')
    const coverImg = page.locator('.wallet-ticket img').first()
    await expect(coverImg).toBeVisible()
    const coverBox = await coverImg.boundingBox()
    const ratio = coverBox.width / coverBox.height
    expect(ratio).toBeGreaterThanOrEqual(1.7)
    expect(ratio).toBeLessThanOrEqual(1.85)
  })

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
