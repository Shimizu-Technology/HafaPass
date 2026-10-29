import { chromium, webkit } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import { prepare, config } from './buyer-pages-fixtures.mjs'

const phase = process.env.QA_PHASE || 'after'
const base = 'http://localhost:5241'
const root = new URL('../../../docs/qa/audit-fixes/', import.meta.url).pathname
const scenes = [
  ['home', '/', {}], ['events-empty', '/events', { empty: true }], ['discover-empty', '/discover', { empty: true }],
  ['events-populated', '/events', {}], ['filters-open', '/events', {}],
  ['event', '/events/community-night', {}], ['checkout', '/events/community-night', {}],
  ['confirmation', '/orders/601/confirmation', {}], ['ticket', '/tickets/display-qa?order=601', {}],
  ['sign-in', '/sign-in', {}], ['sign-up', '/sign-up', {}], ['host', '/host', {}], ['mobile-menu', '/', {}], ['footer', '/events', {}],
]
const report = []
for (const [engine, type] of [['chromium', chromium], ['webkit', webkit]]) {
  if (process.env.QA_ENGINE && process.env.QA_ENGINE !== engine) continue
  const browser = await type.launch()
  try {
    for (const [width, height] of [[390, 844], [1024, 768], [1280, 800]]) {
      for (const [name, path, state] of scenes) {
        const context = await browser.newContext({ viewport: { width, height }, reducedMotion: 'reduce', hasTouch: width < 640 })
        try {
          const page = await context.newPage()
          await prepare(page, state)
          await page.route('**/api/v1/config', route => route.fulfill({ json: { ...config, support_email: 'shimizutechnology@gmail.com', payout_schedule_text: 'within 3 to 5 business days after your event' } }))
          await page.goto(base + path)
          await page.locator('main h1').waitFor()
          if (name === 'checkout') {
            await page.getByRole('button', { name: 'Increase quantity for General admission', exact: true }).click()
            await page.getByRole('button', { name: /Buy Tickets/ }).click()
            await page.getByLabel('Full Name').waitFor()
          }
          if (name.startsWith('events') || name === 'filters-open') {
            await page.getByRole('status', { name: 'Loading events', exact: true }).waitFor({ state: 'hidden' })
            if (name !== 'events-empty') await page.locator('.event-card').first().waitFor()
          }
          if (name === 'filters-open' && phase === 'after' && width < 640) await page.getByRole('button', { name: /^Filters/ }).click()
          if (name === 'mobile-menu' && width < (phase === 'before' ? 1280 : 1024)) await page.getByRole('button', { name: 'Toggle menu' }).click()
          if (name === 'ticket') await page.locator('.ticket svg').first().waitFor()
          await page.evaluate(() => document.fonts.ready)
          await page.waitForTimeout(350)
          if (name === 'footer') await page.locator('footer').scrollIntoViewIfNeeded()
          await page.screenshot({ path: `${root}${phase}/${engine}-${width}-${name}.png`, fullPage: name !== 'footer' })
          const measurements = await page.evaluate(() => ({ width: innerWidth, contentWidth: document.documentElement.scrollWidth, headerHeight: document.querySelector('header').getBoundingClientRect().height, header: getComputedStyle(document.querySelector('header')).backgroundColor, title: document.title }))
          const axe = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa']).analyze()
          const violations = axe.violations.map(({ id, impact, nodes }) => ({ id, impact, targets: nodes.map(n => n.target) }))
          report.push({ engine, width, name, ...measurements, violations })
          process.stdout.write(`${phase} ${engine} ${width} ${name}: width ${measurements.contentWidth}, header ${measurements.headerHeight}, axe ${violations.length}\n`)
          if (phase === 'after') {
            assert.ok(measurements.contentWidth <= width, `${engine} ${width} ${name}: overflow`)
            assert.deepEqual(violations, [], `${engine} ${width} ${name}: axe`)
          }
        } finally { await context.close() }
      }
    }
  } finally { await browser.close(); await fs.writeFile(`${root}${phase}-${engine}-results.json`, JSON.stringify(report.filter(r => r.engine === engine), null, 2) + '\n') }
}
