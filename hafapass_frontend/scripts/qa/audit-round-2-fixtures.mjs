import assert from 'node:assert/strict'
import { prepare, config } from './buyer-pages-fixtures.mjs'

// Isolated API fixtures and the existing no-Clerk development shell. These do
// not establish live account authorization, payments or production writes.
export async function prepareRound2(page) {
  await prepare(page)
  await page.route('**/api/v1/config', route => route.fulfill({ json: { ...config, support_email: 'shimizutechnology@gmail.com', support_phone: '(671) 483-0219' } }))
  await page.route('**/api/v1/organizer/organization', route => route.fulfill({ json: { id: 1, permissions: { manage_events: true } } }))
  await page.route('**/api/v1/organizer/organizations', route => route.fulfill({ json: [{ id: 1, name: 'Synthetic QA organizer' }] }))
  await page.route('**/api/v1/admin/refund_reconciliation*', route => route.fulfill({ json: { items: [], meta: { total_count: 0, total_pages: 1, current_page: 1 } } }))
}

export async function verifySelect(select) {
  await select.waitFor({ state: 'visible' })
  await select.focus()
  const metrics = await select.evaluate(el => {
    const style = getComputedStyle(el)
    const box = el.getBoundingClientRect()
    const context = document.createElement('canvas').getContext('2d')
    context.font = `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`
    const selectedWidth = context.measureText(el.selectedOptions[0].textContent).width + parseFloat(style.paddingLeft) + parseFloat(style.paddingRight) + 2
    return { selectedWidth, height: box.height, width: box.width, appearance: style.appearance, fontSize: style.fontSize, border: style.borderTopWidth, radius: style.borderTopLeftRadius, paddingRight: style.paddingRight, backgroundImage: style.backgroundImage, focus: style.boxShadow }
  })
  assert.ok(metrics.height >= 44, `select target height: ${JSON.stringify(metrics)}`)
  assert.ok(metrics.width >= metrics.selectedWidth, `selected label fits beside chevron: ${JSON.stringify(metrics)}`)
  assert.equal(metrics.appearance, 'none')
  assert.equal(metrics.fontSize, '16px')
  assert.ok(parseFloat(metrics.border) >= 1 && parseFloat(metrics.radius) > 0)
  assert.ok(parseFloat(metrics.paddingRight) >= 36 && metrics.backgroundImage.includes('svg'))
  assert.notEqual(metrics.focus, 'none')
  return metrics
}

export async function verifyCardRows(page) {
  await page.locator('.event-card').first().waitFor()
  const cards = await page.locator('.event-card').evaluateAll(elements => elements.map(card => {
    const calendar = card.querySelector('.lucide-calendar')
    const clock = card.querySelector('.lucide-clock')
    const pin = card.querySelector('.lucide-map-pin')
    const firstTextBox = icon => {
      const range = document.createRange()
      range.selectNodeContents(icon.nextElementSibling)
      return range.getClientRects()[0]
    }
    const date = firstTextBox(calendar), time = firstTextBox(clock)
    const box = card.getBoundingClientRect()
    return { dateY: date.y, timeY: time.y, calendarY: calendar.getBoundingClientRect().y, clockY: clock.getBoundingClientRect().y, pinY: pin?.getBoundingClientRect().y, venueY: pin ? firstTextBox(pin).y : null, left: box.left, right: box.right }
  }))
  for (const card of cards) {
    assert.ok(card.timeY > card.dateY, 'date and time have distinct rows')
    assert.ok(Math.abs(card.calendarY - card.dateY) <= 5, 'calendar stays with date')
    assert.ok(Math.abs(card.clockY - card.timeY) <= 5, 'clock stays with first time line')
    if (card.venueY !== null) assert.ok(Math.abs(card.pinY - card.venueY) <= 5, 'pin stays with long venue name')
  }
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'page fits viewport')
  return cards
}

export async function openCheckout(page) {
  await page.goto('http://localhost:5241/events/community-night')
  await page.getByRole('button', { name: 'Increase quantity for General admission', exact: true }).click()
  await page.getByRole('button', { name: /Buy Tickets/ }).click()
  await page.getByLabel('Full Name').waitFor()
}

export async function verifyCheckout(page) {
  const help = page.locator('main').getByRole('link', { name: 'Contact support', exact: true })
  await help.waitFor()
  assert.match(await help.getAttribute('href'), /^mailto:shimizutechnology@gmail\.com\?/)
  assert.equal(await page.locator('main').getByRole('link', { name: '(671) 483-0219', exact: true }).getAttribute('href'), 'tel:6714830219')
  assert.equal(await page.locator('footer').count(), 0)
  const zone = await page.locator('main p').filter({ hasText: 'Guam\u00a0time' }).first().evaluate(el => {
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT)
    let node
    while ((node = walker.nextNode())) {
      const start = node.textContent.indexOf('Guam\u00a0time')
      if (start < 0) continue
      const range = document.createRange()
      range.setStart(node, start); range.setEnd(node, start + 'Guam\u00a0time'.length)
      return [...range.getClientRects()].map(rect => ({ x: rect.x, y: rect.y, right: rect.right }))
    }
    return []
  })
  assert.equal(zone.length, 1, 'Guam time stays together')
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'checkout fits viewport')
  return zone
}
