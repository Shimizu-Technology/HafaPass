import { chromium, webkit } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import { prepareRound2, verifySelect, verifyCardRows, openCheckout, verifyCheckout } from './audit-round-2-fixtures.mjs'

const root = new URL('../../../docs/qa/audit-fixes/', import.meta.url).pathname
const scenes = [
  ['home', '/'], ['events-populated', '/events'], ['filters-open', '/events'],
  ['checkout', '/events/community-night'], ['discover-populated', '/discover'],
  ['admin-selects', '/admin/refund_reconciliation'], ['dashboard-selects', '/dashboard/events/new'],
]
const report = []
for (const [engine, type] of [['chromium', chromium], ['webkit', webkit]]) {
  if (process.env.QA_ENGINE && process.env.QA_ENGINE !== engine) continue
  const browser = await type.launch()
  try {
    for (const width of [320, 390, 1024, 1280]) {
      for (const [name, path] of scenes) {
        const context = await browser.newContext({ viewport: { width, height: width < 640 ? 844 : width === 1024 ? 768 : 800 }, reducedMotion: 'reduce', hasTouch: width < 640 })
        try {
          const page = await context.newPage()
          await prepareRound2(page)
          if (name === 'checkout') await openCheckout(page)
          else await page.goto('http://localhost:5241' + path)
          let metrics = {}
          if (['home', 'events-populated', 'filters-open', 'discover-populated'].includes(name)) metrics.cards = await verifyCardRows(page)
          if (name === 'filters-open' && width < 640) await page.getByRole('button', { name: /^Filters/ }).click()
          if (name === 'filters-open' || name === 'home' || name.endsWith('selects')) {
            if (name.endsWith('selects')) await page.locator('main select.input').first().waitFor()
            metrics.selects = []
            for (const select of await page.locator('select.input:visible').all()) metrics.selects.push(await verifySelect(select))
          }
          if (name === 'checkout') metrics.zone = await verifyCheckout(page)
          if (name === 'admin-selects') {
            await page.getByRole('combobox', { name: 'Status', exact: true }).selectOption('failed')
            await page.reload()
            await page.getByRole('combobox', { name: 'Status', exact: true }).waitFor()
            assert.equal(await page.getByRole('combobox', { name: 'Status', exact: true }).inputValue(), 'failed')
          }
          if (name === 'dashboard-selects') {
            await page.getByLabel('Age Restriction', { exact: true }).selectOption('eighteen_plus')
            await page.reload()
            await page.getByLabel('Age Restriction', { exact: true }).waitFor()
            assert.equal(await page.getByLabel('Age Restriction', { exact: true }).inputValue(), 'eighteen_plus')
          }
          await page.evaluate(() => document.fonts.ready)
          await page.locator('main h1').first().waitFor()
          await page.locator('main h1').first().focus()
          await page.evaluate(() => { document.activeElement?.blur(); window.scrollTo(0, 0) })
          const contentWidth = await page.evaluate(() => document.documentElement.scrollWidth)
          assert.ok(contentWidth <= width, `${engine} ${width} ${name}: overflow ${contentWidth}`)
          const axe = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa']).analyze()
          const violations = axe.violations.map(({ id, impact, nodes }) => ({ id, impact, targets: nodes.map(n => n.target) }))
          assert.deepEqual(violations, [], `${engine} ${width} ${name}: axe`)
          await page.screenshot({ path: `${root}after/${engine}-${width}-${name}.png`, fullPage: true })
          report.push({ engine, width, name, contentWidth, violations, metrics, result: 'passed' })
          process.stdout.write(`${engine} ${width} ${name}: passed\n`)
        } finally { await context.close() }
      }
    }
  } finally {
    await browser.close()
    await fs.writeFile(`${root}round-2-${engine}-results.json`, JSON.stringify(report.filter(r => r.engine === engine), null, 2) + '\n')
  }
}
