import { expect, test } from '@playwright/test'
import { prepare, event as baseEvent } from '../scripts/qa/buyer-pages-fixtures.mjs'

const coverSvg = encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="900"><rect width="1600" height="900" fill="#075c59"/></svg>')
const base = { ...baseEvent, cover_image_url: 'https://images.example.invalid/uploads/cover.svg', image_asset_host: 'images.example.invalid', venue: { slug: 'community-hall' }, venue_address: '42 Community Road, Hagåtña', doors_open_at: '2099-11-20T07:00:00Z', page_customization: { accent: '#ffff00' } }
const variants = {
  paid: base,
  free: { ...base, ticket_types: base.ticket_types.map(t => ({ ...t, price_cents: 0, current_price_cents: 0, all_in_price_cents: 0, service_fee_cents: 0 })) },
  soldout: { ...base, purchasable: false, ticket_types: base.ticket_types.map(t => ({ ...t, quantity_remaining: 0, quantity_available: 20, quantity_sold: 20 })) },
  prelaunch: { ...base, purchasable: false, ticket_types: base.ticket_types.map(t => ({ ...t, on_sale: false, pricing_schedule: { next_tier: { starts_at: '2099-10-15T00:00:00Z' }, timezone: 'Pacific/Guam' } })) },
  pass: { ...base, ticket_types: [{ ...base.ticket_types[0], name: 'Two-night pass', is_pass: true, included_events: [{ id: 1, title: 'Night one', starts_at: base.starts_at }, { id: 2, title: 'Night two', starts_at: '2099-11-21T08:00:00Z' }] }] },
  past: { ...base, starts_at: '2020-01-01T00:00:00Z', ends_at: '2020-01-01T04:00:00Z' },
  cancelled: { ...base, status: 'cancelled' },
  postponed: { ...base, status: 'postponed' },
  private: { ...base, private_preview: true, purchasable: false },
}
async function openEvent(page, value = base) {
  await prepare(page)
  await page.route('https://images.example.invalid/uploads/cover.svg', route => route.fulfill({ contentType: 'image/svg+xml', body: decodeURIComponent(coverSvg) }))
  await page.route('**/api/v1/events/community-night', route => route.fulfill({ json: value }))
  await page.goto('/events/community-night')
  await expect(page.getByRole('heading', { level: 1, name: base.title })).toBeVisible()
}

for (const state of Object.keys(variants)) {
  test(`event page ${state}: cover first, unique facts and correct state action`, async ({ page }) => {
    await openEvent(page, variants[state])
    // cover precedes title, facts, and purchase controls in DOM and visually.
    const art = page.locator('.event-art')
    await expect(art).toBeVisible()
    expect(await art.evaluate(el => !!(el.compareDocumentPosition(document.querySelector('h1')) & Node.DOCUMENT_POSITION_FOLLOWING))).toBe(true)
    expect((await art.boundingBox()).y).toBeLessThan((await page.locator('h1').boundingBox()).y)
    await expect(page.getByText(base.venue_name, { exact: true })).toHaveCount(1)
    await expect(page.getByText(base.organizer.business_name, { exact: true })).toHaveCount(1)
    await expect(page.getByRole('heading', { name: 'Location', exact: true })).toHaveCount(0)
    expect(await page.evaluate(() => document.documentElement.scrollWidth - innerWidth)).toBeLessThanOrEqual(1)
    if (['paid', 'free', 'pass'].includes(state)) {
      const label = state === 'free' ? 'Reserve' : 'Get tickets'
      const hero = page.locator('a.event-buy').first()
      await expect(hero).toHaveText(label)
      expect(await hero.evaluate(el => getComputedStyle(el).backgroundColor)).toBe('rgb(11, 101, 99)')
      await page.getByRole('button', { name: /^Increase quantity for/ }).first().click()
      const submit = page.locator('#tickets button.event-buy')
      await expect(submit).toHaveText(state === 'free' ? 'Reserve 1 ticket' : 'Checkout · $27.25')
      if ((await page.viewportSize()).width >= 1024) {
        const box = await submit.boundingBox()
        expect(box.y).toBeGreaterThanOrEqual(0)
        expect(box.y + box.height).toBeLessThanOrEqual((await page.viewportSize()).height)
      }
      if (state === 'pass') {
        await page.getByRole('button', { name: 'View included nights (2)' }).click()
        await expect(page.getByText('Night two', { exact: true })).toBeVisible()
      }
      await submit.click()
      await expect(page).toHaveURL(/\/checkout\/community-night$/)
      if (state === 'free') {
        await expect(page.getByText('Payment', { exact: true })).toHaveCount(0)
        await expect(page.getByText('HåfaPass service fee', { exact: true })).toHaveCount(0)
      }
    } else if (state === 'soldout') {
      await expect(page.locator('a.event-buy').first()).toHaveText('Join waitlist')
      if ((await page.viewportSize()).width < 1024) {
        await page.locator('a.event-buy').first().click()
        await expect(page.locator('#waitlist input').first()).toBeFocused()
      }
      const waitlist = page.locator('#waitlist')
      await expect(waitlist.getByRole('heading', { name: 'Sold out — join the waitlist' })).toBeVisible()
      await expect(page.locator('#tickets details').last()).not.toHaveAttribute('open')
      await waitlist.getByPlaceholder('Your name').fill('Fictional Visitor')
      await waitlist.getByPlaceholder('Email address', { exact: true }).fill('visitor@example.invalid')
      await page.route('**/api/v1/events/community-night/waitlist', route => route.fulfill({ json: { id: 1, position: 14, email: 'visitor@example.invalid', management_token: 'synthetic' } }))
      await waitlist.getByRole('button', { name: 'Join waitlist', exact: true }).click()
      await expect(waitlist.getByText(/#14/)).toBeVisible()
    } else if (state === 'prelaunch') {
      await expect(page.locator('a.event-buy').first()).toHaveText('Notify me')
      await expect(page.locator('#tickets')).toContainText('Sales open')
      await expect(page.locator('#tickets')).toContainText('Opens Oct 15')
      await expect(page.getByRole('button', { name: /^Increase quantity/ })).toHaveCount(0)
      await expect(page.getByRole('button', { name: 'Remind me', exact: true })).toHaveCount(0)
    } else if (state === 'past') {
      await expect(page.getByRole('button', { name: 'Event ended' })).toBeDisabled()
      await expect(page.locator('#tickets')).toHaveCount(0)
    } else {
      await expect(page.locator('a.event-buy')).toHaveCount(0)
      await expect(page.getByRole('button', { name: /^Increase quantity/ })).toHaveCount(0)
    }
  })
}

test('desktop long panel keeps selected submit visible while content scrolls internally', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  await openEvent(page, { ...base, ticket_types: Array.from({ length: 7 }, (_, i) => ({ ...base.ticket_types[0], id: i + 1, name: `Admission ${i + 1}`, description: 'A detailed admission option for this night.' })) })
  await page.getByRole('button', { name: 'Increase quantity for Admission 1', exact: true }).click()
  const submit = page.locator('#tickets button.event-buy')
  await expect(submit).toBeVisible()
  const box = await submit.boundingBox()
  expect(box.y + box.height).toBeLessThanOrEqual(900)
  await submit.click()
  await expect(page).toHaveURL(/checkout/)
})

test('mobile menu focuses its first link, closes on Escape anywhere, returns focus and closes on query navigation', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await openEvent(page)
  const trigger = page.locator('button[aria-controls="primary-mobile-navigation"]')
  await trigger.click()
  await expect(page.locator('#primary-mobile-navigation a').first()).toBeFocused()
  await page.locator('h1').evaluate(el => { el.tabIndex = -1; el.focus() })
  await page.keyboard.press('Escape')
  await expect(trigger).toBeFocused()
  await expect(page.locator('#primary-mobile-navigation')).toHaveCount(0)
  await trigger.click()
  await page.evaluate(() => {
    window.history.pushState({}, '', '?category=concert')
    window.dispatchEvent(new PopStateEvent('popstate'))
  })
  await expect(page.locator('#primary-mobile-navigation')).toHaveCount(0)
})

for (const [label, action, collection] of [['Save', 'favorite', 'event_favorites'], ['Remind me', 'reminder', 'event_reminders'], ['Follow', 'follow', 'organizer_follows']]) {
  test(`${label} carries returnTo and completes its action once on return`, async ({ page }) => {
    await openEvent(page)
    let authorized = false
    let saves = 0
    await page.route(`**/api/v1/me/${collection}`, route => {
      if (route.request().method() === 'GET') return route.fulfill({ json: { organizers: [{ id: 7, email_opt_in: false }] } })
      if (authorized) { saves++; return route.fulfill({ json: {} }) }
      return route.fulfill({ status: 401, json: {} })
    })
    await page.getByRole('button', { name: label, exact: true }).click()
    await expect(page).toHaveURL(/\/sign-in\?returnTo=/)
    const returnTo = new URL(page.url()).searchParams.get('returnTo')
    expect(returnTo).toBe(`/events/community-night?marketplace_action=${action}`)
    authorized = true
    await page.goto(returnTo)
    await expect(page).toHaveURL(/\/events\/community-night$/)
    await expect(page.getByRole('button', { name: action === 'follow' ? 'Following' : action === 'favorite' ? 'Saved' : 'Reminder set', exact: true })).toHaveAttribute('aria-pressed', 'true')
    expect(saves).toBe(1)
  })
}
