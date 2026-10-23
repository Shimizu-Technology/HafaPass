import { expect, test } from '@playwright/test'

const json = (route, body) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) })
const event = { id: 601, organization_id: 1, title: 'Review regression event', status: 'draft', timezone: null,
  permissions: { manage_marketing: true, manage_attendees: true }, ticket_types: [{ id: 8, name: 'Admission' }] }
const guest = { id: 5, guest_name: 'Review guest', guest_email: 'guest@example.invalid', quantity: 1,
  ticket_type: { id: 8, name: 'Admission' }, redeemed: false }

async function prepare(page, width) {
  await page.setViewportSize({ width, height: 900 })
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { launch_capabilities: {} }))
  await page.route('**/api/v1/organizer/organizations', route => json(route, [{ id: 1, name: 'Review organizer' }]))
  await page.route('**/api/v1/organizer/events/601', route => json(route, event))
}

for (const width of [390, 1440]) {
  test(`promo expiry uses Guam for a null zone and oversized discounts can recover at ${width}px`, async ({ page }) => {
    await prepare(page, width)
    let saved = [], writes = 0
    await page.route('**/api/v1/organizer/events/601/promo_codes**', route => {
      if (['POST', 'PATCH'].includes(route.request().method())) {
        writes += 1
        saved = [{ id: 55, active: true, current_uses: 0, ...saved[0], ...route.request().postDataJSON() }]
      }
      return json(route, route.request().method() === 'GET' ? saved : saved[0])
    })
    await page.goto('/dashboard/events/601/promo-codes')
    await page.getByRole('button', { name: 'New code' }).click()
    await page.getByLabel('Code', { exact: true }).fill('FIVE')
    await page.getByLabel('Discount type').selectOption('fixed')
    await page.getByLabel('Discount ($)').fill('21474836.48')
    await page.getByLabel(/Expires \(Guam time\)/).fill('2099-11-20T19:00')
    await page.getByRole('button', { name: 'Create code', exact: true }).click()
    await expect(page.getByRole('alert')).toContainText('Enter a valid discount and expiration time.')
    expect(writes).toBe(0)
    await expect(page.getByLabel('Discount ($)')).toHaveValue('21474836.48')
    await page.getByLabel('Discount ($)').fill('5.00')
    await page.getByRole('button', { name: 'Create code', exact: true }).click()
    await expect(page.getByText('Promo code created.', { exact: true })).toBeVisible()
    expect(saved[0]).toMatchObject({ discount_value: 500, expires_at: '2099-11-20T09:00:00.000Z' })
    await expect(page.getByText(/\$5.00 off/)).toContainText('7:00 PM Guam time')
    await page.getByRole('button', { name: 'Edit promo code FIVE' }).click()
    await expect(page.getByLabel(/Expires \(Guam time\)/)).toHaveValue('2099-11-20T19:00')
    await page.getByLabel('Discount ($)').fill('7.25')
    await page.getByLabel(/Expires \(Guam time\)/).fill('2099-11-20T20:00')
    await page.getByRole('button', { name: 'Save changes' }).click()
    await expect(page.getByText('Promo code updated.', { exact: true })).toBeVisible()
    expect(saved[0]).toMatchObject({ discount_value: 725, expires_at: '2099-11-20T10:00:00.000Z' })
    await page.reload()
    await expect(page.getByText(/\$7.25 off/)).toContainText('8:00 PM Guam time')
  })

  test(`guest completion counts and interrupted creation use ticket wording at ${width}px`, async ({ page }) => {
    await prepare(page, width)
    await page.route('**/api/v1/organizer/events/601/guest_list', route => json(route, { guest_list: [guest, { ...guest, id: 6, guest_name: 'Completed guest', redeemed: true, order_id: 99 }] }))
    await page.route('**/api/v1/organizer/events/601/guest_list/5/redeem', route => route.abort('failed'))
    await page.goto('/dashboard/events/601/guest-list')
    await expect(page.getByText('1 pending, 1 tickets created')).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Tickets created', exact: true })).toBeVisible()
    await page.getByRole('button', { name: 'Create tickets', exact: true }).click()
    await page.getByRole('dialog').getByRole('button', { name: 'Create tickets', exact: true }).click()
    await expect(page.getByRole('region', { name: 'Unconfirmed operation' })).toContainText('An earlier create guest tickets request is not confirmed.')
    await expect(page.getByRole('button', { name: 'Create tickets', exact: true })).toBeDisabled()
    await page.reload()
    await expect(page.getByRole('region', { name: 'Unconfirmed operation' })).toContainText('create guest tickets request')
    await expect(page.getByRole('button', { name: 'Create tickets', exact: true })).toBeDisabled()
    expect(await page.evaluate(() => Object.values(sessionStorage).some(value => value.includes('redeem_guest')))).toBe(true)
  })
}
