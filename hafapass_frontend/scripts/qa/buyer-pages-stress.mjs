// Browser-only fixture controls; no QA route or data bypass ships in the app.
import { chromium, webkit } from '@playwright/test'
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import { event, events, tickets, prepare } from './buyer-pages-fixtures.mjs'

const root = new URL('../../../docs/qa/buyer-pages-pass/', import.meta.url).pathname
const worstEvent = { ...event, title: 'An evening of food, music and stories with neighbors from Mongmong-Toto-Maite — family reunion and community fundraiser 🎟️', venue_name: 'MongmongTotoMaiteCommunityCenter.guam.events', venue_city: 'Mongmong-Toto-Maite' }
const worstTickets = [
  { ...tickets[0], event: worstEvent, attendee_name: 'Aleksandra Wiśniewska-Kowalczyk', ticket_type: { name: 'General admission with dinner, live entertainment and a take-home print from the community art workshop' }, seat: { display_label: 'Community table — seat 12' } },
  { ...tickets[1], event: { ...event, id: 604, title: '夜市 🎟️', venue_name: '' }, attendee_name: '', ticket_type: { name: 'Jo' } },
  { ...tickets[0], id: 703, status: 'issued', admission_allowed: false, admission_block_reason: 'Entry is paused while the organizer reviews your refund request. Check the order for the latest status.', event: { ...event, id: 605, title: 'Printmaking' }, attendee_name: '', ticket_type: { name: 'Workshop' } },
]
const variants = {
  Demo: { events, tickets },
  'Worst case': { events: [{ ...worstEvent, ticket_types: [{ ...event.ticket_types[0], all_in_price_cents: 12345678 }] }, { ...events[1], title: '夜市 🎟️' }, { ...events[2], title: 'Printmaking' }], tickets: worstTickets },
  Empty: { empty: true },
  One: { events: [event], tickets: [tickets[0]] },
  '1,000 tickets': { events, tickets: Array.from({ length: 1000 }, (_, i) => ({ ...tickets[0], id: i + 1000, attendee_name: i ? '' : 'Jo' })) },
}
const results = []
for (const [engine, type] of [['chromium', chromium], ['webkit', webkit]]) {
  const browser = await type.launch()
  try {
    for (const [width, zoom] of [[320, 1], [375, 2], [1280, 1]]) {
      const context = await browser.newContext({ viewport: { width, height: 900 }, reducedMotion: 'reduce' })
      try {
        const page = await context.newPage()
        page.setDefaultTimeout(15_000)
        let state = { ...variants.Demo }
        await prepare(page, state)
        await page.exposeFunction('selectFixture', async label => {
          for (const key of Object.keys(state)) delete state[key]
          Object.assign(state, variants[label])
          await page.reload()
        })
        await page.addInitScript(({ zoom, labels }) => {
          document.addEventListener('DOMContentLoaded', () => {
            document.documentElement.style.fontSize = `${zoom * 100}%`
            const control = document.createElement('div')
            control.setAttribute('aria-label', 'Demo data / Worst case')
            control.style.cssText = 'position:fixed;bottom:8px;left:8px;right:8px;z-index:9999;display:flex;flex-wrap:wrap;gap:4px;padding:6px;background:#e5e5e5;color:#171717;font:12px system-ui;border-radius:8px'
            for (const label of labels) {
              const button = document.createElement('button')
              button.textContent = label
              button.style.cssText = 'min-height:44px;padding:4px 8px;background:white;border-radius:6px'
              button.onclick = () => window.selectFixture(label)
              control.append(button)
            }
            document.body.append(control)
          })
        }, { zoom, labels: Object.keys(variants) })
        for (const path of ['/events', '/my-tickets', '/saved']) {
          for (const [label, value] of Object.entries(variants)) {
            if (label === '1,000 tickets' && path !== '/my-tickets') continue
            for (const key of Object.keys(state)) delete state[key]
            Object.assign(state, value)
            await page.goto(`http://localhost:5236${path}`)
            if (path === '/events') await page.waitForFunction(() => !document.querySelector('[aria-label="Loading events"]'))
            if (path === '/my-tickets') await page.waitForFunction(() => document.querySelector('.ticket') && !document.querySelector('main p.sr-only')?.textContent?.includes('Checking'))
            if (path === '/saved') await page.getByRole('heading', { name: 'Reminders', exact: true }).waitFor()
            await page.evaluate(() => document.fonts.ready)
            const size = await page.evaluate(() => ({ available: innerWidth, content: document.documentElement.scrollWidth, passes: document.querySelectorAll('main .ticket').length, buyerPasses: document.querySelectorAll('main .ticket:has(a[href^="/tickets/"])').length }))
            assert.ok(size.content <= size.available, `${engine} ${width}/${zoom} ${path} ${label}: overflow ${JSON.stringify(size)}`)
            if (path === '/my-tickets') assert.equal(size.buyerPasses, value.empty ? 0 : value.tickets.length, `${engine} ${width}/${zoom} ${label}: buyer ticket count`)
            const file = `${engine}-${width}-${zoom}x-${path.slice(1)}-${label.toLowerCase().replaceAll(' ', '-')}.png`
            if (label === 'Worst case' || label === 'Demo') await page.screenshot({ path: `${root}after/${file}`, fullPage: true })
            results.push({ engine, width, zoom, path, label, ...size })
            process.stdout.write(`${engine} ${width} ${zoom}x ${path} ${label}: passed\n`)
          }
        }
      } finally { await context.close() }
    }
  } finally { await browser.close(); await fs.writeFile(`${root}stress-results.json`, JSON.stringify(results, null, 2) + '\n') }
}
