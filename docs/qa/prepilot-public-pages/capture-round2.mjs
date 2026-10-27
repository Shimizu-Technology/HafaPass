import { chromium, expect } from '../../../hafapass_frontend/node_modules/@playwright/test/index.mjs'
import { execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('../../../', import.meta.url))
const evidence = fileURLToPath(new URL('./', import.meta.url))
const session = process.env.LIFECYCLE_SESSION
if (!session) throw new Error('Set LIFECYCLE_SESSION before starting the QA browser')
const baseURL = 'http://localhost:5232'
const fixtureState = state => execFileSync('bundle', ['exec', 'rails', 'runner', '../docs/qa/prepilot-public-pages/fixture-state.rb', state], {
  cwd: `${root}/hafapass_api`, env: { ...process.env, DATABASE_URL: 'postgresql://localhost/hafapass_prepilot_b' }, stdio: 'inherit',
})
const server = await chromium.launchServer()
const pid = String(server.process().pid)
execFileSync('dev-lifecycle', ['claim', 'process', pid, '--session', session, '--reason', 'Round 2 QA Chromium'])
const browser = await chromium.connect(server.wsEndpoint())
const results = []
try {
  const context = await browser.newContext({ baseURL, reducedMotion: 'reduce' })
  await context.addInitScript(() => {
    window.publicPageCLS = 0
    new PerformanceObserver(list => {
      for (const entry of list.getEntries()) if (!entry.hadRecentInput) window.publicPageCLS += entry.value
    }).observe({ type: 'layout-shift', buffered: true })
  })
  const page = await context.newPage()
  const settled = async () => {
    await page.evaluate(async () => {
      await document.fonts.ready
      await Promise.all([...document.images].map(image => image.decode().catch(() => {})))
    })
    await page.waitForTimeout(350)
    expect(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)).toBe(false)
  }
  const capture = async (state, width) => {
    await settled()
    const cls = await page.evaluate(() => window.publicPageCLS)
    expect(cls).toBeLessThan(0.1)
    await page.screenshot({ path: `${evidence}/after/${state}-${width}.png`, fullPage: true })
    return cls
  }
  fixtureState('empty')
  for (const [width, height] of [[375, 812], [768, 1024], [1280, 800]]) {
    await page.setViewportSize({ width, height })
    await page.goto('/')
    await expect(page.getByRole('heading', { name: 'Events are coming soon' })).toBeVisible()
    const photo = page.getByRole('img', { name: /A food vendor grills at the Chamorro Village/ })
    await expect(photo).toHaveAttribute('loading', 'eager')
    await expect(photo).toHaveAttribute('fetchpriority', 'high')
    await expect(photo).toHaveAttribute('width', '1280')
    await expect(photo).toHaveAttribute('height', '960')
    await expect(photo).toHaveAttribute('srcset', /480w.*800w.*1280w/)
    await expect(page.getByText('Chamorro Village night market, Hagåtña.', { exact: true })).toBeVisible()
    const homeEmptyCLS = await capture('home-empty', width)
    await page.getByRole('link', { name: 'Start Hosting', exact: true }).click()
    await expect(page.getByRole('heading', { level: 1, name: 'Host your event with HåfaPass' })).toBeVisible()
    await page.goto('/host')
    await expect(page.getByTestId('host-fee-summary')).toContainText('5% + $1.00 per paid ticket')
    const hostCLS = await capture('host', width)
    const passed = page.getByRole('region', { name: 'Buyer pays the fee', exact: true })
    const absorbed = page.getByRole('region', { name: 'You absorb the fee', exact: true })
    const price = page.getByLabel('Ticket price', { exact: true })
    for (const [amount, buyer, proceeds] of [[10, '$11.50', '$8.50'], [25, '$27.25', '$22.75'], [59, '$62.95', '$55.05']]) {
      const button = page.getByRole('button', { name: `$${amount}`, exact: true })
      await button.focus()
      await page.keyboard.press(amount === 25 ? 'Space' : 'Enter')
      await expect(button).toHaveAttribute('aria-pressed', 'true')
      await expect(price).toHaveValue(String(amount))
      await expect(passed).toContainText(buyer)
      await expect(absorbed).toContainText(proceeds)
      await expect(button).toBeFocused()
      await expect(button).not.toHaveCSS('box-shadow', 'none')
    }
    await price.fill('12.50')
    await page.getByLabel('Tickets', { exact: true }).fill('2')
    await expect(passed).toContainText('$28.26')
    await expect(absorbed).toContainText('$21.74')
    await expect(page.getByRole('group', { name: 'Try a ticket price' }).getByRole('button', { pressed: true })).toHaveCount(0)
    await price.fill('0')
    await expect(page.getByText('Free tickets have no HåfaPass fee.', { exact: true })).toBeVisible()
    await price.fill('bad')
    await expect(price).toHaveAttribute('aria-invalid', 'true')
    await price.fill('25')
    await expect(price).not.toHaveAttribute('aria-invalid', 'true')
    await expect(passed).toContainText('$54.50')
    await expect(page.getByText('What it looks like for one ticket')).toHaveCount(0)
    await expect(page.locator('img[src*="chamorro-village"]')).toHaveCount(0)
    await expect(page.getByRole('link', { name: 'Talk to us about your event' })).toHaveAttribute('href', /^mailto:public-pages-qa@example.test/)
    const faq = page.locator('summary').filter({ hasText: 'Does my door staff need an app?' })
    await faq.focus()
    await page.keyboard.press('Enter')
    await expect(faq.locator('..')).toHaveAttribute('open', '')
    await expect(faq.locator('..')).toContainText('Each device must be prepared online before the event.')
    writeFileSync(`${evidence}/host-copy.txt`, await page.locator('main').innerText())
    await page.goto('/')
    const credits = page.locator('footer summary').filter({ hasText: 'Photo credits' })
    await credits.focus()
    await page.keyboard.press('Enter')
    await expect(credits.locator('..').getByRole('link')).toHaveCount(4)
    await expect(credits.locator('..')).toContainText('Junpei Abe')
    await expect(credits.locator('..')).toContainText('Daniel Ramirez')
    for (const link of await credits.locator('..').getByRole('link').all()) {
      await link.focus()
      await expect(link).toBeFocused()
      await expect(link).toHaveCSS('outline-style', 'solid')
    }
    await page.evaluate(() => window.scrollTo(0, 0))
    await page.waitForTimeout(100)
    await page.screenshot({ path: `${evidence}/after/footer-credits-${width}.png`, fullPage: true })
    results.push({ width, height, homeEmptyCLS, hostCLS, R01: 'passed', R03: 'passed', R04: 'passed' })
  }
  fixtureState('populated')
  for (const result of results) {
    const { width, height } = result
    await page.setViewportSize({ width, height })
    await page.goto('/')
    const featured = page.getByRole('article', { name: 'Featured event' })
    await expect(featured.getByRole('heading', { name: 'QA music night', exact: true })).toBeVisible()
    await expect(featured.locator('img')).toHaveCount(0)
    await expect(featured.locator('[class*="aspect-"]')).toHaveCount(0)
    await expect(featured.getByText('Featured event', { exact: true })).toHaveCSS('text-transform', 'none')
    await expect(featured.getByText('Featured event', { exact: true })).toHaveCSS('font-size', '14px')
    const events = await page.request.get('http://localhost:3062/api/v1/events').then(response => response.json())
    expect(events.events).toHaveLength(4)
    for (const event of events.events) {
      const date = new Date(event.starts_at)
      const localLabel = date.toLocaleDateString('en-US', { timeZone: 'Pacific/Guam', weekday: 'long', month: 'short', day: 'numeric', year: 'numeric' })
      const tile = page.locator(`time[datetime="${event.starts_at}"]`).first()
      await expect(tile).toHaveAttribute('aria-label', localLabel)
      await expect(tile).toContainText(date.toLocaleDateString('en-US', { timeZone: 'Pacific/Guam', day: 'numeric' }))
    }
    result.homePopulatedCLS = await capture('home-populated', width)
    // Explicit no-art filenames let the next consumer find this acceptance state.
    await page.screenshot({ path: `${evidence}/after/home-no-art-featured-${width}.png`, fullPage: true })
    await featured.getByRole('link', { name: 'Get Tickets' }).click()
    await expect(page.getByRole('heading', { level: 1, name: 'QA music night', exact: true })).toBeVisible()
    await page.goto('/')
    await page.getByRole('searchbox', { name: 'Event or venue' }).fill('QA music')
    await page.getByRole('button', { name: 'Search', exact: true }).click()
    await expect(page).toHaveURL(/\/events\?search=QA\+music$/)
    await page.goto('/')
    await page.getByRole('link', { name: 'Food & Drink', exact: true }).click()
    await expect(page).toHaveURL(/\/events\?category=dining$/)
    result.R02 = 'passed'
  }
  await page.emulateMedia({ reducedMotion: 'no-preference' })
  await page.goto('/host')
  const faq = page.locator('summary').filter({ hasText: 'Does my door staff need an app?' })
  await faq.click()
  await expect(faq.locator('..')).toHaveAttribute('open', '')
  await faq.click()
  await expect(faq.locator('..')).not.toHaveAttribute('open', '')
  writeFileSync(`${evidence}/round2-results.json`, JSON.stringify({ date: new Date().toISOString(), fixture: 'hafapass_prepilot_b (4 owned events)', results, normalMotionFAQ: 'passed' }, null, 2) + '\n')
  console.log(JSON.stringify(results))
  await context.close()
} finally {
  await browser.close()
  await server.close()
  execFileSync('dev-lifecycle', ['release', 'process', pid, '--session', session])
}
