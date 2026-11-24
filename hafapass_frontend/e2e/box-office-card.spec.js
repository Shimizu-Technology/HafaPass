import { mkdir } from 'node:fs/promises'
import { env } from 'node:process'
import { expect, test } from '@playwright/test'

const base = '**/api/v1/organizer/events/607'
const ticket = { id: 8, name: 'Admission', quantity_available: 50, quantity_sold: 0, price_cents: 1200, service_fee_cents: 123 }
const event = {
  id: 607, organization_id: 1, title: 'Coral Lantern Weekend (demo)', status: 'published',
  starts_at: '2099-11-13T06:00:00Z', timezone: 'Pacific/Guam', venue_name: 'Coral Lantern Pavilion (demo)',
  ticket_types: [ticket], permissions: { box_office: true }, online_door_card_enabled: true,
}
const checkoutUrl = 'https://checkout.stripe.com/c/pay/fictional-checkout-do-not-pay'
const demoTier = `Weekend pass · 架空🌺 ${'W'.repeat(160)}`

async function prepare(page, { enabled = true, loseResponse = false } = {}) {
  let id = 89
  let sale
  const attempts = []
  const emailed = []
  const settled = new Map()
  let providerPaid = false
  await page.route('**/api/v1/health', route => route.fulfill({ json: { status: 'ok' } }))
  await page.route('**/api/v1/config', route => route.fulfill({ json: { launch_capabilities: {} } }))
  await page.route('**/api/v1/organizer/organizations', route => route.fulfill({ json: [{ id: 1, name: 'Coral Lantern Studio (demo)' }] }))
  await page.route('**/api/v1/organizer/card_present_account', route => route.fulfill({ json: { payment_ready: false } }))
  await page.route(base, route => route.fulfill({ json: { ...event, online_door_card_enabled: enabled } }))
  await page.route(`${base}/box_office/summary`, route => {
    const orders = [...settled.values()]
    return route.fulfill({ json: {
      total_orders: orders.length,
      total_tickets: orders.reduce((sum, order) => sum + order.tickets.length, 0),
      total_revenue_cents: orders.reduce((sum, order) => sum + order.total_cents, 0),
      by_payment_method: Object.fromEntries(orders.map(order => [order.payment_method, order.total_cents])),
    } })
  })
  await page.route(`${base}/box_office_card_sales`, route => {
    if (route.request().method() === 'GET') {
      const orders = [...settled.values(), ...(sale?.pending ? [sale] : [])]
      return route.fulfill({ json: { orders: orders.map(order => ({
        ...order, buyer_name: `架空🌺 ${'W'.repeat(96)}`,
      })) } })
    }
    const body = route.request().postDataJSON()
    const key = route.request().headers()['idempotency-key']
    if (!attempts.some(attempt => attempt.key === key)) {
      sale = {
        id: ++id, reference: `DEMO-STRIPE-${id}`, status: 'waiting', pending: true, total_cents: 1323,
        payment_method: body.payment_method, checkout_url: checkoutUrl, tickets: [],
        expires_at: '2099-11-13T06:35:00Z', can_email_link: body.payment_method === 'door_card_link' && Boolean(body.buyer_email),
      }
    }
    attempts.push({ body, key })
    if (loseResponse && attempts.length === 1) return route.abort('failed')
    return route.fulfill({ json: sale })
  })
  await page.route(`${base}/box_office_card_sales/*`, route => {
    const url = new URL(route.request().url())
    const orderId = Number(url.pathname.split('/').at(-1))
    if (route.request().method() === 'GET' && settled.has(orderId)) return route.fulfill({ json: settled.get(orderId) })
    if (route.request().method() === 'DELETE') {
      sale = { ...sale, status: 'cancelled', pending: false, checkout_url: null }
    }
    const checked = url.searchParams.get('check_provider') === '1'
    if (checked && providerPaid) return route.fulfill({ json: {
      ...sale, status: 'confirming', pending: false, checkout_url: null, payment_checked: true,
    } })
    return route.fulfill({ json: { ...sale, payment_checked: checked } })
  })
  await page.route(`${base}/box_office_card_sales/*/email`, route => {
    emailed.push(sale.id)
    const orderId = Number(new URL(route.request().url()).pathname.split('/').at(-2))
    const status = settled.has(orderId) ? { ticket_email_status: 'queued' } : { link_email_status: 'queued' }
    sale = { ...sale, ...status }
    return route.fulfill({ json: status, status: 202 })
  })
  await page.goto('/dashboard/events/607/box-office')
  await expect(page.getByRole('heading', { name: 'Box office' })).toBeVisible()
  return {
    attempts,
    emailed,
    setProviderPaid(value) { providerPaid = value },
    update(changes) {
      sale = { ...sale, ...changes }
      if (sale.status === 'paid') settled.set(sale.id, sale)
    },
  }
}

async function openCheckout(page, mode, email = false, beforePrepare = null) {
  await page.getByRole('button', { name: 'Add Admission' }).click()
  if (email) await page.getByRole('textbox', { name: 'Buyer email' }).fill('player@example.test')
  const method = page.getByRole('button', { name: mode })
  await method.click()
  await expect(method).toHaveAttribute('aria-pressed', 'true')
  await expect(page.getByRole('button', { name: 'Cash', exact: true })).toHaveAttribute('aria-pressed', 'false')
  const fee = page.getByText('Buyer pays $13.23 including $1.23 service fee.')
  await expect(fee).toBeVisible()
  if (beforePrepare) await beforePrepare(fee)
  await page.getByRole('button', { name: 'Prepare Stripe checkout' }).click()
}

for (const width of [390, 1280]) {
  test(`online door card reuses checkout and exposes only confirmed admissions at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    const fixture = await prepare(page, { loseResponse: true })
    const evidence = env.HAFAPASS_W4B_QA_DIR
    if (evidence) await mkdir(evidence, { recursive: true })
    const capture = async state => {
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
      if (evidence) {
        await page.locator('#door-checkout-status').evaluate(heading => heading.scrollIntoView({ block: 'start' }))
        await page.screenshot({ path: `${evidence}/${state}-${width}.png` })
      }
    }

    await openCheckout(page, 'Pay on buyer’s phone', true, async fee => {
      await expect(page.getByText(/Clover reader payments are unavailable/)).toBeVisible()
      if (evidence) {
        await fee.evaluate(element => element.scrollIntoView({ block: 'center' }))
        await page.screenshot({ path: `${evidence}/fee-quote-${width}.png`, animations: 'disabled' })
      }
    })
    await expect(page.getByText('Do not charge the card again')).toBeVisible()
    await page.reload()
    await page.getByRole('button', { name: /Retry saved sale/ }).click()
    const waiting = page.getByRole('heading', { name: 'Waiting for payment…' })
    await expect(waiting).toBeVisible()
    expect(fixture.attempts).toHaveLength(2)
    expect(fixture.attempts[0]).toEqual(fixture.attempts[1])
    expect(fixture.attempts[0].body).toEqual({ payment_method: 'door_card_link', buyer_email: 'player@example.test',
      expected_total_cents: 1323, line_items: [{ ticket_type_id: 8, quantity: 1 }] })
    await page.reload()
    await expect(waiting).toBeVisible()
    await expect(page.getByRole('img', { name: 'Stripe payment QR' })).toBeVisible()
    await expect(page.getByText('Ticket 1 of 1')).toHaveCount(0)
    const email = page.getByRole('button', { name: 'Email payment link' })
    expect((await email.boundingBox()).height).toBeGreaterThanOrEqual(48)
    await email.click()
    await expect(page.getByText('Payment link email requested.')).toBeVisible()
    expect(fixture.emailed).toHaveLength(1)
    await capture('waiting-phone')

    fixture.update({ status: 'failed' })
    await page.getByRole('button', { name: 'Check payment status' }).click()
    await expect(page.getByRole('heading', { name: 'Failed' })).toBeVisible()
    await capture('failed')
    fixture.update({ status: 'paid', pending: false, checkout_url: null, can_email_tickets: true, tickets: [
      { id: 90, scan_credential: 'fictional-entrance-credential', event: event.title, tier: demoTier },
    ] })
    await expect(page.getByRole('heading', { name: 'Paid — tickets ready' })).toBeVisible({ timeout: 8000 })
    await expect(page.getByText(demoTier)).toBeVisible()
    await capture('paid')

    await expect(page.getByText('Phone checkout').locator('..')).toContainText('$13.23')
    await page.getByRole('button', { name: 'Start next sale' }).click()
    await openCheckout(page, 'Enter card on this device')
    await expect(waiting).toBeVisible()
    await expect(page.getByRole('link', { name: 'Open Stripe checkout' })).toHaveAttribute('href', checkoutUrl)
    await expect(page.getByRole('img', { name: 'Stripe payment QR' })).toHaveCount(0)
    await capture('waiting-keyed')

    fixture.update({ status: 'expired', pending: false, checkout_url: null })
    await page.getByRole('button', { name: 'Check payment status' }).click()
    await expect(page.getByRole('heading', { name: 'Expired' })).toBeVisible()
    await expect(page.getByRole('link', { name: 'Open Stripe checkout' })).toHaveCount(0)
    await capture('expired')

    fixture.setProviderPaid(true)
    await page.getByRole('button', { name: 'Check payment status' }).click()
    const confirming = page.getByRole('heading', { name: 'Paid — waiting for confirmation' })
    await expect(confirming).toBeVisible()
    await expect(page.getByRole('button', { name: 'Start next sale' })).toHaveCount(0)
    await expect(page.getByText('Ticket 1 of 1')).toHaveCount(0)
    await capture('confirming')
    await page.waitForResponse(response => response.url().endsWith('/box_office_card_sales/91'))
    await expect(confirming).toBeVisible()
    fixture.setProviderPaid(false)
    fixture.update({ status: 'refunded' })
    await expect(page.getByRole('heading', { name: 'Refunded' })).toBeVisible()
    await page.getByRole('button', { name: 'Start next sale' }).click()
    await openCheckout(page, 'Pay on buyer’s phone')
    await expect(waiting).toBeVisible()
    await page.evaluate(() => sessionStorage.clear())
    await page.reload()
    await page.getByRole('button', { name: 'Open card checkouts' }).click()
    await expect(page.getByRole('button', { name: 'Show tickets' })).toBeVisible()
    const showQr = page.getByRole('button', { name: 'Show payment QR' })
    await expect(showQr).toBeVisible()
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
    if (evidence) {
      await page.locator('#open-door-checkouts').evaluate(element => element.scrollIntoView({ block: 'center' }))
      await page.screenshot({ path: `${evidence}/open-checkouts-${width}.png` })
    }
    await showQr.click()
    await expect(page.getByRole('img', { name: 'Stripe payment QR' })).toBeVisible()
    await page.getByRole('button', { name: 'Cancel sale' }).click()
    await expect(page.getByRole('heading', { name: 'Cancelled' })).toBeVisible()
    await capture('cancelled')
    await page.getByRole('button', { name: 'Back to box office' }).click()
    await page.getByRole('button', { name: 'Open card checkouts' }).click()
    await page.getByRole('button', { name: 'Show tickets' }).click()
    await expect(page.getByRole('heading', { name: 'Paid — tickets ready' })).toBeVisible()
    await page.getByRole('button', { name: 'Email tickets' }).click()
    await expect(page.getByText('Ticket email requested.')).toBeVisible()
  })
}

test('default-off event leaves cash and reader controls available under their existing gates', async ({ page }) => {
  await prepare(page, { enabled: false })
  await expect(page.getByRole('button', { name: 'Cash', exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Card at Door' })).toBeDisabled()
  await expect(page.getByRole('button', { name: 'Pay on buyer’s phone' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Enter card on this device' })).toHaveCount(0)
})
