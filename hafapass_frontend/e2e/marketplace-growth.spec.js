import { expect, test } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

const json = (route, body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
const startsAt = new Date(Date.now() + 2 * 86400_000).toISOString()
const event = {
  id: 42, title: 'Family Night Market', slug: 'family-night-market', short_description: 'Food and fun',
  starts_at: startsAt, ends_at: new Date(Date.now() + 2 * 86400_000 + 7200_000).toISOString(), timezone: 'Pacific/Guam',
  category: 'family', category_label: 'Family', venue_name: 'Guam Museum', venue_city: 'Hagåtña', purchasable: true,
  organizer: { name: 'Island Events', slug: 'island-events', verified: true },
  ticket_types: [{ id: 3, name: 'Entry', price_cents: 2000, current_price_cents: 2000, quantity_remaining: 10, on_sale: true }],
}
// The production catalog has ten categories, plus the All Events choice.
const categories = [
  ['nightlife', 'Nightlife'], ['concert', 'Music & Concerts'], ['festival', 'Festivals & Culture'],
  ['dining', 'Food & Drink'], ['sports', 'Sports & Fitness'], ['workshop', 'Classes & Workshops'],
  ['fundraiser', 'Fundraisers & Nonprofits'], ['family', 'Family'], ['business', 'Business & Networking'], ['other', 'Other'],
].map(([value, label]) => ({ value, label }))

test('buyer discovers a governed collection and filters Guam inventory', async ({ page }) => {
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/marketplace_collections', route => json(route, { collections: [{ id: 1, title: 'Family Weekend', slug: 'family-weekend', description: 'Kid-friendly Guam picks', events: [event] }] }))
  await page.route('**/api/v1/events**', route => json(route, { events: [event], meta: { current_page: 1, total_pages: 1, total_count: 1 } }))

  await page.goto('/discover')
  await expect(page.getByRole('heading', { name: 'Family Weekend' })).toBeVisible()
  const eventCard = page.getByRole('link', { name: /Family Night Market/ })
  await expect(eventCard).toBeVisible()
  // Visibility can precede the public route fade finishing. Audit the rendered
  // colors after every ancestor is opaque; keep the contrast rule enabled.
  await expect.poll(() => eventCard.evaluate(element => {
    for (let node = element; node; node = node.parentElement) {
      if (Number(getComputedStyle(node).opacity) !== 1) return false
    }
    return true
  })).toBe(true)
  const accessibility = await new AxeBuilder({ page }).analyze()
  expect(accessibility.violations.filter(item => ['serious', 'critical'].includes(item.impact))).toEqual([])

  await page.goto('/events')
  await page.getByLabel('Price').selectOption('under_25')
  await page.getByLabel('Village').selectOption('Hagåtña')
  await expect(page).toHaveURL(/price=under_25/)
  await expect(page).toHaveURL(/village=Hag/)
})

test('free event discovery has accessible labels and readable selected controls', async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 900 })
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { environment: 'test', launch_capabilities: {} }))
  await page.route('**/api/v1/event_categories', route => json(route, { categories: [] }))
  await page.route('**/api/v1/events**', route => json(route, { events: [{ ...event, ticket_types: [{ ...event.ticket_types[0], price_cents: 0, current_price_cents: 0 }] }], meta: { current_page: 1, total_pages: 1, total_count: 1 } }))
  await page.goto('/events')
  await expect(page.getByLabel('Search events and venues', { exact: true })).toBeVisible()
  await expect(page.getByRole('link', { name: /Family Night Market/ })).toBeVisible()
  await page.evaluate(() => document.fonts.ready)
  await page.getByRole('link', { name: /Family Night Market/ }).scrollIntoViewIfNeeded()
  const accessibility = await new AxeBuilder({ page }).analyze()
  expect(accessibility.violations.filter(item => ['serious', 'critical'].includes(item.impact))).toEqual([])
})

for (const width of [320, 390, 768, 1440]) {
  test(`discovery filters remain readable and retain selection after reload at ${width}px`, async ({ page }) => {
    const height = width < 640 ? 844 : 900
    await page.setViewportSize({ width, height })
    await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
    await page.route('**/api/v1/config', route => json(route, { environment: 'test', launch_capabilities: {} }))
    await page.route('**/api/v1/event_categories', route => json(route, { categories }))
    const requestedFilters = []
    await page.route('**/api/v1/events**', route => {
      const params = Object.fromEntries(new URL(route.request().url()).searchParams)
      requestedFilters.push(params)
      return json(route, { events: [event], meta: { current_page: 1, total_pages: 1, total_count: 1 } })
    })
    await page.goto('/events')
    await expect(page.getByRole('link', { name: /Family Night Market/ })).toBeVisible()
    await page.evaluate(() => document.fonts.ready)
    if (width < 640) {
      await expect(page.getByLabel('Category', { exact: true })).toBeHidden()
      const collapsedTop = await page.getByRole('link', { name: /Family Night Market/ }).evaluate(card => card.getBoundingClientRect().top + window.scrollY)
      expect(collapsedTop).toBeLessThan(height - 44)
      await page.getByRole('button', { name: 'Filters', exact: true }).click()
      await expect(page.getByLabel('Category', { exact: true })).toBeVisible()
      await expect(page.getByLabel('Category', { exact: true }).locator('option')).toHaveCount(11)
      await expect(page.getByRole('button', { name: 'All Events', exact: true })).toHaveCount(0)
      const date = await page.getByLabel('When', { exact: true }).boundingBox()
      const price = await page.getByLabel('Price', { exact: true }).boundingBox()
      if (width < 400) {
        expect(price.y).toBeGreaterThanOrEqual(date.y + date.height)
        expect(price.x).toBe(date.x)
      } else {
        expect(date.y).toBe(price.y)
        expect(date.x + date.width).toBeLessThanOrEqual(price.x)
      }
    } else {
      await expect(page.getByLabel('Category', { exact: true })).toBeHidden()
      await expect(page.getByRole('button', { name: 'All Events', exact: true })).toHaveAttribute('aria-pressed', 'true')
      for (const { label } of categories) await expect(page.getByRole('button', { name: label, exact: true })).toBeVisible()
    }
    const checkFilterText = async () => {
      for (const label of [...(width < 640 ? ['Category'] : []), 'When', 'Price', 'Village']) {
        await expect(page.locator('label').filter({ hasText: new RegExp(`^${label}$`) })).toBeVisible()
        const fit = await page.getByLabel(label, { exact: true }).evaluate(select => {
          const box = select.getBoundingClientRect()
          const style = getComputedStyle(select)
          const canvas = document.createElement('canvas')
          const context = canvas.getContext('2d')
          context.font = `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`
          return { height: box.height, width: box.width, required: context.measureText(select.selectedOptions[0].textContent).width
            + parseFloat(style.paddingLeft) + parseFloat(style.paddingRight) + 20 }
        })
        expect(fit.height).toBeGreaterThanOrEqual(44)
        expect(fit.width).toBeGreaterThanOrEqual(fit.required)
      }
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
    }
    await checkFilterText()
    if (width < 640) await page.getByLabel('Category', { exact: true }).selectOption('fundraiser')
    else await page.getByRole('button', { name: 'Fundraisers & Nonprofits', exact: true }).click()
    await page.getByLabel('When', { exact: true }).selectOption('weekend')
    await page.getByLabel('Price', { exact: true }).selectOption('under_25')
    await page.getByLabel('Village', { exact: true }).selectOption('Tamuning-Tumon-Harmon')
    await expect.poll(() => requestedFilters.at(-1)).toMatchObject({ category: 'fundraiser', window: 'weekend', price: 'under_25', village: 'Tamuning-Tumon-Harmon' })
    await expect(page).toHaveURL(/category=fundraiser/)
    await expect(page).toHaveURL(/date=weekend/)
    await expect(page).toHaveURL(/price=under_25/)
    await expect(page).toHaveURL(/village=Tamuning-Tumon-Harmon/)
    await checkFilterText()
    await page.reload()
    if (width < 640) {
      await page.getByRole('button', { name: 'Filters (4)', exact: true }).click()
      await expect(page.getByLabel('Category', { exact: true })).toHaveValue('fundraiser')
    }
    else await expect(page.getByRole('button', { name: 'Fundraisers & Nonprofits', exact: true })).toHaveAttribute('aria-pressed', 'true')
    await expect(page.getByLabel('When', { exact: true })).toHaveValue('weekend')
    await expect(page.getByLabel('Price', { exact: true })).toHaveValue('under_25')
    await expect(page.getByLabel('Village', { exact: true })).toHaveValue('Tamuning-Tumon-Harmon')
    await expect(page.getByRole('link', { name: /Family Night Market/ })).toBeVisible()
    await checkFilterText()
    if (width < 640) {
      await page.setViewportSize({ width: 768, height: 900 })
      await expect(page.getByRole('button', { name: 'Fundraisers & Nonprofits', exact: true })).toHaveAttribute('aria-pressed', 'true')
      await page.getByRole('button', { name: 'Family', exact: true }).click()
      await page.setViewportSize({ width, height })
      await expect(page.getByLabel('Category', { exact: true })).toHaveValue('family')
      await expect(page).toHaveURL(/category=family/)
      await expect.poll(() => requestedFilters.at(-1)).toMatchObject({ category: 'family', window: 'weekend', price: 'under_25', village: 'Tamuning-Tumon-Harmon' })
    }
  })
}

test('a late previous filter response cannot replace the currently selected results', async ({ page }) => {
  let previousRoute
  let currentServed = false
  const duplicateCurrentRoutes = []
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { environment: 'test', launch_capabilities: {} }))
  await page.route('**/api/v1/events**', route => {
    if (!new URL(route.request().url()).searchParams.has('price')) previousRoute = route
    else if (!currentServed) {
      currentServed = true
      return json(route, { events: [{ ...event, title: 'Current free result' }], meta: { current_page: 1, total_pages: 1, total_count: 1 } })
    } else duplicateCurrentRoutes.push(route)
  })
  try {
    await page.goto('/events')
    await expect.poll(() => Boolean(previousRoute)).toBe(true)
    await page.getByLabel('Price', { exact: true }).selectOption('free')
    await expect(page.getByRole('link', { name: /Current free result/ })).toBeVisible()
    const previousResponse = page.waitForResponse(response => response.url().includes('/api/v1/events') && !new URL(response.url()).searchParams.has('price'))
    await json(previousRoute, { events: [{ ...event, title: 'Stale previous result' }], meta: { current_page: 1, total_pages: 1, total_count: 1 } })
    await (await previousResponse).finished()
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
    await expect(page.getByRole('link', { name: /Current free result/ })).toBeVisible()
    await expect(page.getByRole('link', { name: /Stale previous result/ })).toHaveCount(0)
    await expect(page.getByLabel('Price', { exact: true })).toHaveValue('free')
  } finally {
    for (const route of duplicateCurrentRoutes) await route.abort()
  }
})

test('an unavailable event listing offers retry and preserves the chosen filters', async ({ page }) => {
  let unavailable = true
  const requests = []
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { environment: 'test', launch_capabilities: {} }))
  await page.route('**/api/v1/events**', route => {
    requests.push(Object.fromEntries(new URL(route.request().url()).searchParams))
    return unavailable ? json(route, { error: 'Synthetic outage' }, 503)
      : json(route, { events: [event], meta: { current_page: 1, total_pages: 1, total_count: 1 } })
  })
  await page.goto('/events?price=under_25&village=Hag%C3%A5t%C3%B1a')
  await expect(page.getByRole('alert')).toContainText("Couldn't load events")
  await expect(page.getByRole('heading', { name: 'No matching events' })).toHaveCount(0)
  unavailable = false
  await page.getByRole('button', { name: 'Try again', exact: true }).focus()
  await page.keyboard.press('Enter')
  await expect(page.getByRole('link', { name: /Family Night Market/ })).toBeVisible()
  await expect(page.getByRole('alert')).toHaveCount(0)
  expect(requests.at(-1)).toMatchObject({ price: 'under_25', village: 'Hagåtña' })
  await expect(page.getByLabel('Price', { exact: true })).toHaveValue('under_25')
  await expect(page.getByLabel('Village', { exact: true })).toHaveValue('Hagåtña')
})

test('empty discovery results can clear filters on a narrow phone', async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 900 })
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { environment: 'test', launch_capabilities: {} }))
  await page.route('**/api/v1/event_categories', route => json(route, { categories }))
  await page.route('**/api/v1/events**', route => {
    const filtered = new URL(route.request().url()).searchParams.has('q')
    return json(route, { events: filtered ? [] : [event], meta: { current_page: 1, total_pages: 1, total_count: filtered ? 0 : 1 } })
  })
  await page.goto('/events?search=unmatched')
  await expect(page.getByRole('heading', { name: 'No matching events' })).toBeVisible()
  await page.evaluate(() => document.fonts.ready)
  const accessibility = await new AxeBuilder({ page }).analyze()
  expect(accessibility.violations.filter(item => ['serious', 'critical'].includes(item.impact))).toEqual([])
  await page.getByRole('button', { name: 'Clear filters', exact: true }).click()
  await expect(page.getByRole('link', { name: /Family Night Market/ })).toBeVisible()
  await expect(page).toHaveURL(/\/events$/)
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(320)
})

test('partner link records anonymous attribution and opens the intended event', async ({ page }) => {
  let anonymousId
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/distribution_links/GUAM123**', route => {
    anonymousId = new URL(route.request().url()).searchParams.get('anonymous_id')
    return json(route, { event_slug: event.slug, attribution: { distribution_code: 'GUAM123', source: 'hotel', medium: 'partner', campaign: 'front-desk' } })
  })
  await page.route('**/api/v1/events/family-night-market**', route => json(route, { ...event, description: 'Food and fun', status: 'published', venue_address: 'Hagåtña', attendee_count: 0, attendees_preview: [], organizer: { id: 5, business_name: 'Island Events', slug: 'island-events', verified: true, followed: false } }))
  await page.route('**/api/v1/marketplace_funnel_events', route => json(route, {}, 201))

  await page.goto('/go/GUAM123')
  await expect(page).toHaveURL(/events\/family-night-market/)
  await expect(page.getByRole('heading', { name: 'Family Night Market' })).toBeVisible()
  expect(anonymousId).toMatch(/^[a-f0-9-]{36}$/)
  const stored = await page.evaluate(() => JSON.parse(localStorage.getItem('hafapass_attribution')))
  expect(stored).toMatchObject({ distribution_code: 'GUAM123', source: 'hotel', campaign: 'front-desk' })
})

for (const viewport of [{ width: 390, height: 844 }, { width: 1440, height: 900 }]) {
  test(`public event actions remain reachable before and after setting a reminder at ${viewport.width}px`, async ({ page }) => {
    await page.setViewportSize(viewport)
    await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
    await page.route('**/api/v1/config', route => json(route, { environment: 'test', launch_capabilities: {} }))
    await page.route('**/api/v1/events/family-night-market**', route => json(route, { ...event,
      title: 'Music & Food <show> 🎟️', description: 'A synthetic community event.', status: 'published',
      venue_address: 'Hagåtña', attendee_count: 0, attendees_preview: [], favorited: false, reminder: null,
      organizer: { id: 5, business_name: 'Island Events', slug: 'island-events', verified: true, followed: false },
    }))
    await page.route('**/api/v1/marketplace_funnel_events', route => json(route, {}, 201))
    const reminderRequests = []
    await page.route('**/api/v1/me/event_reminders**', route => {
      reminderRequests.push({ method: route.request().method(), body: route.request().postDataJSON() })
      return json(route, {}, route.request().method() === 'POST' ? 201 : 200)
    })
    await page.goto('/events/family-night-market')
    await expect(page.getByRole('heading', { name: 'Music & Food <show> 🎟️' })).toBeVisible()
    await page.evaluate(() => document.fonts.ready)

    const checkGeometry = async label => {
      await expect(page.getByRole('link', { name: 'Add to Calendar' })).toBeVisible()
      for (const name of ['Share', 'Save', label]) await expect(page.getByRole('button', { name, exact: true })).toBeVisible()
      const bounds = await page.getByRole('button', { name: label, exact: true }).locator('..').evaluate(row =>
        Array.from(row.children, control => {
          const box = control.getBoundingClientRect()
          return { left: box.left, right: box.right, top: Math.round(box.top) }
        }))
      expect(bounds).toHaveLength(4)
      for (const box of bounds) {
        expect(box.left).toBeGreaterThanOrEqual(0)
        expect(box.right).toBeLessThanOrEqual(viewport.width)
      }
      const rows = new Set(bounds.map(box => box.top))
      expect(rows.size).toBe(viewport.width === 390 ? 2 : 1)
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(viewport.width)
    }
    await checkGeometry('Remind me')
    const remind = page.getByRole('button', { name: 'Remind me', exact: true })
    await remind.focus()
    await page.keyboard.press('Enter')
    await expect(page.getByRole('button', { name: 'Reminder set', exact: true })).toHaveAttribute('aria-pressed', 'true')
    expect(reminderRequests).toEqual([{ method: 'POST', body: { event_id: event.id } }])
    await checkGeometry('Reminder set')
    await page.getByRole('button', { name: 'Reminder set', exact: true }).click()
    await expect(page.getByRole('button', { name: 'Remind me', exact: true })).toHaveAttribute('aria-pressed', 'false')
    expect(reminderRequests.at(-1).method).toBe('DELETE')
    await checkGeometry('Remind me')
  })
}

test('reduced-motion event navigation retains B inventory through a late A response and checkout', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' })
  const a = { ...event, id: 41, slug: 'event-a', title: 'Event A', description: 'Synthetic context A', status: 'published',
    attendees_preview: [], attendee_count: 0, ticket_types: [{ id: 111, name: 'A entry', price_cents: 0, current_price_cents: 0, quantity_remaining: 10, on_sale: true }] }
  const b = { ...a, id: 42, slug: 'event-b', title: 'Event B', description: 'Synthetic context B',
    ticket_types: [{ id: 222, name: 'B entry', price_cents: 0, current_price_cents: 0, quantity_remaining: 10, on_sale: true }] }
  let oldRoute
  let submitted
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { payment_mode: 'simulate', buyer_terms_version: 'test-v1', service_fee_percent: '3.0', service_fee_flat_cents: 0 }))
  await page.route('**/api/v1/marketplace_funnel_events', route => json(route, {}, 201))
  await page.route('**/api/v1/events/event-a', route => { oldRoute = route })
  await page.route('**/api/v1/events/event-b', route => json(route, b))
  await page.route('**/api/v1/orders', route => {
    submitted = route.request().postDataJSON()
    return json(route, { error: 'Regression transport stopped before allocation', checkout_recovery_required: true }, 503)
  })
  await page.goto('/events/event-a')
  await expect.poll(() => Boolean(oldRoute)).toBe(true)
  await page.evaluate(() => {
    history.pushState({}, '', '/events/event-b')
    window.dispatchEvent(new PopStateEvent('popstate'))
  })
  await expect(page.getByRole('heading', { name: 'Event B', exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Increase quantity' }).click()
  await page.getByRole('button', { name: 'Increase quantity' }).click()
  await json(oldRoute, a)
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  await expect(page.getByRole('heading', { name: 'Event B', exact: true })).toBeVisible()
  await page.getByRole('button', { name: /Buy Tickets/ }).click()
  await expect(page).toHaveURL(/\/checkout\/event-b$/)
  await page.getByLabel('Full Name').fill('Synthetic Route Buyer')
  await page.getByLabel('Email Address').fill('buyer@example.invalid')
  await page.locator('#termsAccepted').check()
  await page.getByRole('button', { name: /Place Order/ }).click()
  await expect.poll(() => submitted?.event_id).toBe(42)
  expect(submitted.line_items).toEqual([{ ticket_type_id: 222, quantity: 2 }])
})
