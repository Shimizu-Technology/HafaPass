import { chromium, webkit, expect } from '@playwright/test'
import { prepare, event } from './buyer-pages-fixtures.mjs'
import fs from 'node:fs/promises'

const results = []
for (const [engine, type] of [['chromium', chromium], ['webkit', webkit]]) {
  const browser = await type.launch()
  try {
    for (const width of [375, 390, 1280]) {
      const page = await browser.newPage({ viewport: { width, height: width === 1280 ? 800 : 844 }, reducedMotion: 'reduce' })
      try {
        await prepare(page)
        const saved = { favorite: false, follow: false, reminder: false }
        const json = (route, body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
        let failed = false
        await page.route('**/api/v1/me/event_favorites**', route => {
          if (route.request().method() === 'POST') { saved.favorite = true; return json(route, {}) }
          return json(route, { events: saved.favorite ? [event] : [] }, failed ? 503 : 200)
        })
        await page.route('**/api/v1/me/organizer_follows**', route => {
          if (route.request().method() === 'POST') { saved.follow = true; return json(route, {}) }
          return json(route, { organizers: saved.follow ? [{ id: 1, slug: 'island-events', name: 'Island events' }] : [] })
        })
        await page.route('**/api/v1/me/event_reminders**', route => {
          if (route.request().method() === 'POST') { saved.reminder = true; return json(route, {}) }
          return json(route, { reminders: saved.reminder ? [{ id: 1, status: 'pending', event, remind_at: '2099-11-19T08:00:00Z' }] : [] })
        })
        await page.goto('http://localhost:5236/events/community-night')
        await page.getByRole('button', { name: 'Save', exact: true }).click()
        await expect(page.getByRole('button', { name: 'Saved', exact: true })).toHaveAttribute('aria-pressed', 'true')
        await page.getByRole('button', { name: 'Follow', exact: true }).click()
        await expect(page.getByRole('button', { name: 'Following', exact: true })).toHaveAttribute('aria-pressed', 'true')
        await page.getByRole('button', { name: 'Remind me', exact: true }).click()
        await expect(page.getByRole('button', { name: 'Reminder set', exact: true })).toHaveAttribute('aria-pressed', 'true')
        await page.goto('http://localhost:5236/saved')
        for (let reload = 0; reload < 2; reload++) {
          if (reload) await page.reload()
          await expect(page.locator('.event-card')).toHaveCount(1)
          await expect(page.locator('#followed-organizers-heading + div a')).toHaveAttribute('href', '/organizers/island-events')
          await expect(page.locator('#reminders-heading + div a')).toHaveAttribute('href', '/events/community-night')
        }
        await page.locator('#reminders-heading + div a').click()
        await expect(page).toHaveURL(/\/events\/community-night$/)
        await expect(page.getByRole('heading', { level: 1, name: event.title, exact: true })).toBeVisible()
        failed = true
        await page.goto('http://localhost:5236/saved')
        await expect(page.getByRole('alert')).toContainText("We couldn't load your saved items.")
        await expect(page.getByText('Tap Save on an event to keep it here.')).toHaveCount(0)
        failed = false
        await page.getByRole('button', { name: 'Try again', exact: true }).click()
        await expect(page.locator('.event-card')).toHaveCount(1)
        await page.locator('.event-card').click()
        await expect(page.getByRole('heading', { level: 1, name: event.title, exact: true })).toBeVisible()
        results.push({ engine, width, case: 'Save, follow, remind → Saved reload → event link; outage → retry preserves saved outcomes', status: 'passed', boundary: 'API fixtures, no Clerk authentication or email delivery' })
        process.stdout.write(`${engine} ${width}: Saved actions, reload, navigation and recovery passed\n`)
      } finally { await page.close() }
    }
  } finally { await browser.close(); await fs.writeFile(new URL('../../../docs/qa/buyer-pages-pass/journey-results.json', import.meta.url), JSON.stringify(results, null, 2) + '\n') }
}
