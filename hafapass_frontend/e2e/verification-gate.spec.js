import { test, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

const json = (route, body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
const event = { id: 601, organization_id: 1, slug: 'private-island-show', title: 'Private Island Show',
  description: 'Community music in Tumon.', status: 'published', starts_at: '2099-10-20T08:00:00Z',
  ends_at: '2099-10-20T12:00:00Z', timezone: 'Pacific/Guam', venue_name: 'Tumon Pavilion',
  category: 'other', fee_policy: 'organizer_absorbs', buyer_fee_percent: 0, purchasable: false,
  ticket_types: [{ id: 10, name: 'Admission', price_cents: 0, current_price_cents: 0,
    quantity_remaining: 50, on_sale: false }], private_preview: true }
const organizerEvent = { ...event, private_preview: undefined, publicly_visible: false, organizer_verification_status: 'unverified',
  publish_checklist: [], sales_status: { on_sale: false, reason: 'organizer_not_verified',
    message: 'Private preview only: request organizer verification to go public and start selling.' },
  permissions: { view_events: true, manage_events: true, edit_event_content: true, scan: true } }
const profile = { id: 1, business_name: 'Island Events', business_description: 'Community shows',
  verification_status: 'unverified', policy_accepted: true, organization: { id: 1, role: 'owner' },
  setup_progress: { events_count: 1, published_events_count: 1 } }
const initialProfile = { ...profile }

async function setup(page) {
  Object.assign(profile, initialProfile)
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { launch_capabilities: {}, payment_mode: 'simulate' }))
  await page.route('**/api/v1/event_categories', route => json(route, { categories: [] }))
  await page.route('**/api/v1/events/private-island-show/private_preview', route => {
    expect(route.request().headers()['x-preview-token']).toBe('synthetic-secret')
    return json(route, event)
  })
  await page.route('**/api/v1/events/private-island-show', route => json(route, { error: 'Event not found' }, 404))
  await page.route(/\/api\/v1\/events(?:\?.*)?$/, route => json(route, { events: [], meta: { current_page: 1, total_pages: 1, total_count: 0 } }))
  await page.route('**/api/v1/organizer/organizations', route => json(route, [{ id: 1, name: 'Island Events', role: 'owner', permissions: { manage_organization: true, manage_events: true } }]))
  await page.route('**/api/v1/organizer_profile', route => json(route, profile))
  await page.route('**/api/v1/organizer/events/summary', route => json(route, { upcoming_events_count: 1, tickets_sold: 0, next_event: { id: 601, title: event.title } }))
  await page.route(/\/api\/v1\/organizer\/events(?:\?.*)?$/, route => json(route, { events: [organizerEvent], meta: { current_page: 1, total_pages: 1, total_count: 1 } }))
  await page.route('**/api/v1/organizer/events/601', route => json(route, organizerEvent))
  await page.route('**/api/v1/organizer/events/601/preview_link', route => json(route, { url: 'http://127.0.0.1:4173/events/private-island-show/preview#t=synthetic-secret' }))
  await page.route('**/api/v1/organizer/events/601/stats', route => json(route, { total_tickets_sold: 0, total_revenue_cents: 0, tickets_checked_in: 0 }))
}

async function accessible(page) {
  const results = await new AxeBuilder({ page }).analyze()
  expect(results.violations.filter(item => ['serious', 'critical'].includes(item.impact))).toEqual([])
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual((await page.viewportSize()).width)
}

async function tabTo(page, locator) {
  for (let index = 0; index < 100; index += 1) {
    if (await locator.evaluate(element => element === document.activeElement)) return
    await page.keyboard.press('Tab')
  }
  throw new Error('Keyboard focus did not reach the form control')
}

for (const width of [375, 1280]) {
  test(`draft keeps its saved preview link at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    await setup(page)
    await page.route('**/api/v1/organizer/events/601', route => json(route, {
      ...organizerEvent, status: 'draft', publicly_visible: false,
    }))
    await page.goto('/dashboard/events/601/edit')
    await expect(page.getByRole('link', { name: 'Preview saved event' })).toHaveAttribute('href', '/events/private-island-show?preview=true')
    await expect(page.getByText(/Public link \(works after verification\)/)).toHaveCount(0)
    await accessible(page)
  })

  test(`dashboard event chips match visibility reason at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    await setup(page)
    let state = organizerEvent
    await page.route(/\/api\/v1\/organizer\/events(?:\?.*)?$/, route => json(route, {
      events: [state], meta: { current_page: 1, total_pages: 1, total_count: 1 },
    }))
    for (const [reason, label] of [
      [{ sales_status: { on_sale: false, reason: 'organizer_not_verified' }, publicly_visible: false }, 'Waiting for verification'],
      [{ sales_status: { on_sale: false, reason: 'organizer_verification_requested' }, publicly_visible: false }, 'Waiting for verification'],
      [{ organizer_verification_status: 'suspended', sales_status: { on_sale: false, reason: 'organizer_paused' }, publicly_visible: false }, 'Suspended'],
      [{ organizer_verification_status: 'verified', publicly_visible: false, policy_hold_scope: 'hidden' }, 'On hold'],
    ]) {
      state = { ...organizerEvent, ...reason }
      await page.goto('/dashboard')
      const card = page.locator('a[href="/dashboard/events/601"]').filter({ hasText: 'Private Island Show' })
      await expect(card).toContainText(label)
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
    }
    state = { ...organizerEvent, title: 'A long community event title for every village on Guam' }
    await page.goto('/dashboard')
    const title = page.getByRole('heading', { name: state.title })
    const card = page.locator('a[href="/dashboard/events/601"]').filter({ has: title })
    const chip = card.getByText('Waiting for verification')
    const action = card.getByText('Open event')
    const titleBox = await title.boundingBox()
    const chipBox = await chip.boundingBox()
    expect(titleBox.height).toBeGreaterThan(20)
    if (width === 375) expect(chipBox.y).toBeGreaterThanOrEqual(titleBox.y + titleBox.height)
    expect((await action.boundingBox()).height).toBeGreaterThanOrEqual(44)
    profile.verification_status = 'suspended'
    await page.goto('/dashboard')
    const verificationStep = page.getByRole('listitem').filter({ hasText: 'HåfaPass verifies your organization' })
    await expect(verificationStep).toContainText('Sales paused by HåfaPass')
    await expect(verificationStep).not.toContainText('Next')
  })

  test(`private preview and verification request at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    await setup(page)
    await page.goto('/dashboard')
    await expect(page.getByRole('heading', { name: 'Get verified to start selling tickets' })).toBeVisible()
    await page.getByRole('region', { name: 'Get ready to sell tickets' }).getByRole('button', { name: 'Request verification' }).click()
    await page.getByRole('textbox', { name: /Contact phone/ }).fill('123')
    await page.getByRole('textbox', { name: /Website or social media link/ }).fill('not a link')
    await page.getByRole('button', { name: 'Send request' }).click()
    await expect(page.locator('#verification_phone-error')).toContainText('Enter a valid phone number')
    await expect(page.getByRole('textbox', { name: /Contact phone/ })).toBeFocused()
    await expect(page.getByText(/Check 2 highlighted verification fields/)).toBeVisible()
    await expect(page.getByRole('textbox', { name: /Contact phone/ })).toHaveValue('123')
    await page.getByRole('textbox', { name: /Contact phone/ }).fill('+1-671-555-1234')
    await page.getByRole('textbox', { name: /Website or social media link/ }).fill('instagram.com/islandevents')
    await page.getByRole('textbox', { name: /Contact phone/ }).focus()
    await expect(page.getByRole('textbox', { name: /Website or social media link/ })).toHaveValue('https://instagram.com/islandevents')
    await page.route('**/api/v1/organizer_profile/submit_verification', route => {
      Object.assign(profile, route.request().postDataJSON(), { verification_status: 'pending', verification_requested_at: '2026-10-23T00:00:00Z' })
      return json(route, profile)
    })
    await page.getByRole('button', { name: 'Send request' }).click()
    await expect(page.getByRole('heading', { name: "We're reviewing your account" })).toBeVisible()
    await expect(page.getByText(/Submitted Oct 23, 2026/)).toBeVisible()
    await accessible(page)
    await page.screenshot({ path: `/tmp/hafapass-verification-dashboard-${width}.png`, fullPage: true })

    await page.goto('/dashboard/events/601')
    await expect(page.getByText('Waiting for verification').first()).toBeVisible()
    await expect(page.getByRole('link', { name: 'Preview event' })).toHaveAttribute('href', /\/preview#t=/)
    await expect(page.getByRole('link', { name: 'View public page' })).toHaveCount(0)
    await page.getByRole('button', { name: 'Get a new preview link' }).click()
    await expect(page.getByRole('group', { name: 'Confirm new preview link' })).toContainText('Anyone using the old link will lose access')
    await page.getByRole('button', { name: 'Cancel' }).click()
    await accessible(page)
    await page.screenshot({ path: `/tmp/hafapass-verification-overview-${width}.png`, fullPage: true })

    await page.goto('/dashboard/events/601/edit')
    await expect(page.getByText(/Public link \(works after verification\)/).first()).toBeVisible()
    await expect(page.getByRole('link', { name: 'Preview saved event' })).toHaveCount(0)
    await accessible(page)
    await page.screenshot({ path: `/tmp/hafapass-verification-edit-${width}.png`, fullPage: true })

    await page.goto('/events/private-island-show?preview_token=synthetic-secret')
    await expect(page).toHaveURL(/\/events\/private-island-show\/preview#t=synthetic-secret$/)
    await expect(page.getByRole('heading', { name: 'Private Island Show' })).toBeVisible()
    await expect(page.getByText(/Private preview — this event isn't public, and tickets aren't available here/)).toBeVisible()
    await expect(page.getByText(/Tickets aren't available in this private preview/)).toHaveCount(1)
    await expect(page.getByRole('button', { name: /Get tickets/i })).toBeDisabled()
    await expect(page.locator('meta[name="robots"]')).toHaveAttribute('content', /noindex, nofollow/)
    await expect(page.locator('meta[property="og:title"][content="Private Island Show"]')).toHaveCount(0)
    await accessible(page)
    await page.screenshot({ path: `/tmp/hafapass-verification-preview-${width}.png`, fullPage: true })

    await page.goto('/events/private-island-show')
    await expect(page.getByRole('heading', { name: 'We couldn’t find that event' })).toBeVisible()
    await page.goto('/events')
    await expect(page.getByText('Private Island Show')).toHaveCount(0)

    await page.route('**/api/v1/admin/dashboard', route => json(route, {
      total_events: { published: 1 }, total_users: {}, total_revenue_cents: 0, total_tickets_sold: 0,
      recent_events: [], recent_orders: [], financials: {}, operational_signals: {},
      organizers_awaiting_verification: profile.verification_status === 'pending' ? [{
        profile_id: 1, business_name: 'Island Events', verification_status: 'pending',
        business_description: 'Community shows', verification_request_note: 'Please call after lunch.',
        verification_phone: profile.verification_phone, verification_link: profile.verification_link,
        published_awaiting_events_count: 1, requested_at: profile.verification_requested_at,
      }, { profile_id: 2, business_name: 'No request yet', verification_status: 'unverified' }] : [], verified_organizers: [],
    }))
    await page.route('**/api/v1/admin/organizer_profiles/1', route => {
      expect(route.request().postDataJSON().verification_status).toBe('verified')
      profile.verification_status = 'verified'
      return json(route, profile)
    })
    await page.goto('/admin')
    await expect(page.getByRole('heading', { name: 'Requested (newest first) (1)' })).toBeVisible()
    await expect(page.getByText('Not requested yet (1)')).toBeVisible()
    await expect(page.getByText('Business description')).toBeVisible()
    await expect(page.getByText('Note: Please call after lunch.')).toBeVisible()
    await accessible(page)
    await page.screenshot({ path: `/tmp/hafapass-verification-admin-${width}.png`, fullPage: true })
    await page.getByRole('button', { name: 'Verify Island Events' }).click()
    await page.getByRole('dialog', { name: 'Verify Island Events?' }).getByRole('button', { name: 'Verify' }).click()
    await expect(page.getByText('Island Events is verified. Their published events are public.')).toBeVisible()
    const liveEvent = { ...event, private_preview: false, purchasable: true,
      ticket_types: event.ticket_types.map(type => ({ ...type, on_sale: true })) }
    await page.route('**/api/v1/events/private-island-show', route => json(route, liveEvent))
    await page.route('**/api/v1/events/private-island-show/private_preview', route => json(route, { redirect_to: event.slug }))
    await page.goto('/events/private-island-show/preview#t=synthetic-secret')
    await expect(page).toHaveURL(/\/events\/private-island-show$/)
    await expect(page.getByRole('heading', { name: 'Private Island Show' })).toBeVisible()
    await expect(page.getByText(/Private preview — this event isn't public, and tickets aren't available here/)).toHaveCount(0)
    await expect(page.getByRole('button', { name: 'Increase quantity for Admission' })).toBeEnabled()
  })

  test(`rejected request can be fixed using only the keyboard at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    await setup(page)
    Object.assign(profile, { verification_status: 'rejected', verification_notes: 'Please add a public social page.',
      verification_phone: '', verification_link: '' })
    await page.route('**/api/v1/organizer_profile/submit_verification', route => {
      Object.assign(profile, route.request().postDataJSON(), { verification_status: 'pending', verification_requested_at: '2026-10-23T00:00:00Z' })
      return json(route, profile)
    })
    await page.goto('/dashboard')
    await expect(page.getByText('Please add a public social page.').first()).toBeVisible()
    const resubmit = page.getByRole('button', { name: 'Resubmit' })
    await tabTo(page, resubmit)
    await page.keyboard.press('Enter')
    const phone = page.getByRole('textbox', { name: /Contact phone/ })
    await tabTo(page, phone)
    await page.keyboard.type('+1-671-555-1234')
    const link = page.getByRole('textbox', { name: /Website or social media link/ })
    await tabTo(page, link)
    await page.keyboard.type('https://instagram.com/islandevents')
    await tabTo(page, page.getByRole('button', { name: 'Send request' }))
    await page.keyboard.press('Enter')
    await expect(page.getByRole('heading', { name: "We're reviewing your account" })).toBeVisible()
    await accessible(page)
  })
}
