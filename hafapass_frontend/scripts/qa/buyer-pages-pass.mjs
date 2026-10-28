import { chromium, webkit } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import { prepare } from './buyer-pages-fixtures.mjs'

const phase = process.env.QA_PHASE || 'after'
const base = 'http://localhost:5236'
const root = new URL('../../../docs/qa/buyer-pages-pass/', import.meta.url).pathname
const scenes = [
  ['events-empty', '/events', { empty: true }], ['events-populated', '/events', {}], ['events-no-match', '/events?search=nothing', { noMatch: true }],
  ['discover-empty', '/discover', { empty: true }], ['discover-populated', '/discover', {}], ['collection', '/collections/this-weekend', {}],
  ['my-tickets-empty', '/my-tickets', { empty: true }], ['my-tickets-populated', '/my-tickets', {}],
  ['saved-empty', '/saved', { empty: true }], ['saved-populated', '/saved', {}],
  ['event', '/events/community-night', {}], ['checkout', '/checkout/community-night', {}], ['confirmation', '/orders/601/confirmation', {}], ['ticket', '/tickets/display-qa?order=601', {}],
]
const report = []
const selected = process.env.QA_SCENES?.split(',')
const widths = process.env.QA_WIDTHS?.split(',').map(Number)
for (const [engine, type] of [['chromium', chromium], ...(phase === 'after' && process.env.QA_ENGINE !== 'chromium' ? [['webkit', webkit]] : [])]) {
  const browser = await type.launch()
  try {
    for (const [width, height] of [[375, 812], [390, 844], [1280, 800]]) {
      if (widths && !widths.includes(width)) continue
      for (const [name, path, state] of scenes) {
        if (selected && !selected.includes(name)) continue
        const context = await browser.newContext({ viewport: { width, height }, reducedMotion: 'reduce', hasTouch: width < 640 })
        try {
          const page = await context.newPage()
          page.setDefaultTimeout(15_000)
          await prepare(page, state)
          await page.goto(base + (name === 'checkout' ? '/events/community-night' : path))
          if (name === 'checkout') {
            await page.getByRole('button', { name: 'Increase quantity for General admission', exact: true }).click()
            await page.getByRole('button', { name: /Buy Tickets/ }).click()
          }
          await page.locator('main h1').waitFor()
          if (name.startsWith('events')) await page.waitForFunction(() => !document.querySelector('[aria-label="Loading events"]'))
          if (name === 'events-populated') await page.locator('.event-card').first().waitFor()
          if (name.includes('my-tickets')) await page.getByRole('tablist').waitFor()
          if (name.startsWith('saved')) await page.getByRole('heading', { name: /Reminders/ }).waitFor()
          if (name === 'checkout') await page.getByLabel('Full Name').waitFor()
          await page.evaluate(() => document.fonts.ready)
          await page.waitForTimeout(600)
          const filename = `${engine === 'webkit' ? 'webkit-' : ''}${width}-${name}.png`
          await page.screenshot({ path: `${root}${phase}/${filename}`, fullPage: true })
          const measurements = await page.evaluate(() => ({ width: innerWidth, contentWidth: document.documentElement.scrollWidth, cls: window.qaCLS, clsAvailable: window.qaCLSAvailable, shifts: window.qaShifts, header: getComputedStyle(document.querySelector('header')).backgroundColor, theme: document.querySelector('meta[name="theme-color"]').content }))
          assert.ok(measurements.contentWidth <= width, `${engine} ${width} ${name}: overflow`)
          const axe = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa']).analyze()
          const violations = axe.violations.map(({ id, impact, nodes }) => ({ id, impact, targets: nodes.map(n => n.target) }))
          report.push({ engine, width, name, ...measurements, violations })
          process.stdout.write(`${engine} ${width} ${name}: CLS ${measurements.clsAvailable ? measurements.cls : 'unavailable'}, axe ${violations.length}\n`)
          if (phase === 'after') {
            assert.deepEqual(violations, [], `${engine} ${width} ${name}: axe`)
            if (measurements.clsAvailable) assert.ok(measurements.cls < 0.1, `${engine} ${width} ${name}: CLS ${measurements.cls}`)
          }
        } finally { await context.close() }
      }
    }
  } finally { await browser.close(); await fs.writeFile(`${root}${process.env.QA_SCENES ? 'targeted-' : ''}${phase}-results.json`, JSON.stringify(report, null, 2) + '\n') }
}
