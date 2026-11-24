import { expect, test } from '@playwright/test'
import { env } from 'node:process'
import { mkdirSync } from 'node:fs'
const states = [
  ['paid', 'copa-de-marianas-2027', 'Get tickets'],
  ['free-selection', 'fd-alumni-basketball-night-1', 'Get tickets'],
  ['soldout', 'tumon-bay-acoustic-sessions', 'Join waitlist'],
  ['prelaunch', 'guam-night-market-spring-preview', 'Notify me'],
  ['pass', 'fd-alumni-basketball-night-2', 'Get tickets'],
]
for (const [state, slug, label] of states) test(`preview event ${state} is actionable and cover-first`, async ({ page }, testInfo) => {
  await page.goto(`/events/${slug}`)
  await expect(page.getByTestId('demo-preview-banner')).toBeVisible()
  const art = page.locator('.event-art')
  await expect(art).toBeVisible()
  expect((await art.boundingBox()).y).toBeLessThan((await page.locator('h1').boundingBox()).y)
  await expect(page.locator('a.event-buy').first()).toHaveText(label)
  await expect(page.getByRole('heading', { name: 'Location', exact: true })).toHaveCount(0)
  if (state === 'paid' || state === 'pass') {
    await page.getByRole('button', { name: /^Increase quantity for/ }).first().click()
    const submit = page.locator('#tickets button.event-buy')
    await expect(submit).toContainText('Checkout · $')
    if ((await page.viewportSize()).width >= 1024) {
      const box = await submit.boundingBox()
      expect(box.y + box.height).toBeLessThanOrEqual((await page.viewportSize()).height)
    }
  } else if (state === 'free-selection') {
    await page.getByRole('button', { name: /Increase quantity for Free Alumni/ }).click()
    await expect(page.locator('#tickets button.event-buy')).toHaveText('Reserve 1 ticket')
  } else if (state === 'soldout') {
    await expect(page.locator('#waitlist')).toBeVisible()
    await page.getByPlaceholder('Your name').fill('Fictional Demo Visitor')
    await page.getByPlaceholder('Email address', { exact: true }).fill('visitor@example.invalid')
    await page.locator('#waitlist').getByRole('button', { name: 'Join waitlist', exact: true }).click()
    await expect(page.locator('#waitlist')).toContainText("#14")
  } else if (state === 'prelaunch') {
    await expect(page.locator('#tickets')).toContainText('Opens Feb 15')
    await page.locator('#tickets').getByRole('button', { name: 'Notify me', exact: true }).click()
    await expect(page.getByText('Saved for this demo visit.', { exact: false })).toBeVisible()
    await expect(page).toHaveURL(new RegExp(`/events/${slug}$`))
  }
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'instant' }))
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  if (env.HP_QA_SCREEN_DIR) {
    mkdirSync(env.HP_QA_SCREEN_DIR, { recursive: true })
    await page.screenshot({ path: `${env.HP_QA_SCREEN_DIR}/${testInfo.project.name}-${state}.png`, fullPage: true })
  }
  expect(await page.evaluate(() => document.documentElement.scrollWidth - innerWidth)).toBeLessThanOrEqual(1)
})

test('preview Save, Remind me, Follow, PDF, account and pass summary have clear outcomes', async ({ page }) => {
  await page.goto('/events/copa-de-marianas-2027')
  for (const [label, result] of [['Save', 'Saved'], ['Remind me', 'Reminder set'], ['Follow', 'Following']]) {
    await page.getByRole('button', { name: label, exact: true }).click()
    await expect(page.getByRole('button', { name: result, exact: true })).toHaveAttribute('aria-pressed', 'true')
    await expect(page).toHaveURL(/\/events\/copa-de-marianas-2027$/)
  }
  await expect(page.getByText('Saved. Your preference is up to date.', { exact: true })).toBeVisible()
  await page.goto('/tickets/demo-ticket-copa-adult-1?order=demo-copa-2027')
  await page.getByRole('button', { name: /Download PDF/ }).click()
  await expect(page.getByText(/PDF download is off in this demo preview/)).toBeVisible()
  await expect(page.getByText(/check your connection/i)).toHaveCount(0)
  await page.goto('/sign-in')
  await expect(page.getByText(/Sign-in is off in this demo preview/)).toBeVisible()
  await expect(page.getByRole('link', { name: 'Sample ticket', exact: true }).last()).toBeVisible()
  await page.goto('/my-tickets')
  await expect(page.getByRole('heading', { name: 'Your tickets in this preview' })).toBeVisible()
  await page.goto('/tickets/demo-ticket-fd-pass-1?order=demo-pass-2027')
  await expect(page.getByRole('heading', { level: 1 })).toHaveText(/2-Night Tournament Pass|FD Alumni Basketball Tournament 2027/)
})


test('selected mobile buy bar reflects quantities and checks out directly', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await page.goto('/events/copa-de-marianas-2027')
  const plus = page.getByRole('button', { name: 'Increase quantity for Adult Spectator', exact: true })
  await plus.click()
  await plus.click()
  await page.getByRole('heading', { name: 'About', exact: true }).evaluate(el => el.scrollIntoView({ block: 'start' }))
  const bar = page.getByTestId('mobile-buy-bar')
  await expect(bar).toHaveAttribute('data-visible', 'true')
  await expect(bar).toContainText('2 tickets · $33.50')
  await bar.getByRole('link', { name: 'Checkout', exact: true }).click()
  await expect(page).toHaveURL(/checkout\/copa-de-marianas-2027$/)
  await expect(page.getByTestId('demo-payments-off-notice')).toBeVisible()
})
