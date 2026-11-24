import { mkdir, writeFile } from 'node:fs/promises'
import { env } from 'node:process'
import { expect, test } from '@playwright/test'

const base = '**/api/v1/organizer/events/601'
const ticketType = { id: 7, name: 'Admission', quantity_available: 60, quantity_sold: 0, price_cents: 1200 }
const order = { id: 90, reference: 'DEMO-W4A', status: 'completed', total_cents: 1200 }
const event = {
  id: 601, organization_id: 1, title: 'Coral Lantern Weekend (demo)', timezone: 'Pacific/Guam',
  venue_name: 'Coral Lantern Pavilion (demo)', venue_address: '10 Lantern Trail',
  starts_at: '2099-11-12T06:00:00Z', status: 'published', permissions: { box_office: true }, ticket_types: [ticketType],
}
const admit = (index, options) => ({
  id: 700 + index, scan_credential: `fictional-ticket-credential-${index}`, event, tier: 'Admission', ...options,
})
const longName = `架空選手 🌺 ${'W'.repeat(130)}`
const widePass = [0, 1, 2].map(index => admit(index, {
  attendee_name: longName, pass_night: true, tier: 'Weekend pass',
  event: { ...event, title: `Fictional Night ${index + 1}`, starts_at: `2099-11-${12 + index}T06:00:00Z` },
}))
const bulk = Array.from({ length: 20 }, (_, index) => admit(index))

async function prepare(page, admissions) {
  let email
  const receipt = () => ({
    ...order, event_title: event.title, admissions, email_available: true, email, email_status: email && 'queued',
  })
  await page.route('**/api/v1/health', route => route.fulfill({ json: { status: 'ok' } }))
  await page.route('**/api/v1/config', route => route.fulfill({ json: { launch_capabilities: {} } }))
  await page.route('**/api/v1/organizer/organizations', route => route.fulfill({ json: [{ id: 1, name: 'Coral Lantern Studio (demo)' }] }))
  await page.route('**/api/v1/organizer/card_present_account', route => route.fulfill({ json: { payment_ready: false } }))
  await page.route(base, route => route.fulfill({ json: event }))
  await page.route(`${base}/box_office/summary`, route => route.fulfill({ json: {
    total_orders: 0, total_tickets: 0, total_revenue_cents: 0, by_payment_method: {},
  } }))
  await page.route(`${base}/box_office`, route => route.fulfill({ status: 201, json: { ...order, receipt: receipt() } }))
  await page.route(`${base}/box_office/orders/90`, route => route.fulfill({ json: receipt() }))
  await page.route(`${base}/box_office/orders/90/email`, route => {
    email = route.request().postDataJSON().email
    return route.fulfill({ status: 202, json: { email, email_status: 'queued' } })
  })
  await page.addInitScript(() => {
    window.print = () => { document.body.dataset.printRequested = 'true' }
  })
}

for (const [width, admissions] of [[390, widePass], [1280, bulk]]) {
  test(`box office shows, prints and emails a reloaded sale at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    await prepare(page, admissions)
    await page.goto('/dashboard/events/601/box-office')
    await page.getByRole('button', { name: 'Add Admission' }).click()
    await page.getByRole('button', { name: /Process sale/ }).click()
    const showQr = page.getByRole('button', { name: 'Show QR' })
    await expect(showQr).toBeVisible()
    await page.reload()
    await expect(showQr).toBeVisible()
    expect((await showQr.boundingBox()).height).toBeGreaterThanOrEqual(48)
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)

    const evidence = env.HAFAPASS_W4A_QA_DIR
    if (evidence) {
      await mkdir(evidence, { recursive: true })
      await page.screenshot({ path: `${evidence}/finish-${width}.png` })
    }
    await showQr.click()
    const dialog = page.getByRole('dialog', { name: 'Show QR' })
    await expect(dialog.getByText(`Ticket 1 of ${admissions.length}`)).toBeVisible()
    if (width === 390) {
      await expect(dialog.getByText(longName)).toBeVisible()
      expect(await dialog.evaluate(element => element.scrollWidth)).toBeLessThanOrEqual(width)
    }
    if (evidence) await page.screenshot({ path: `${evidence}/qr-${width}.png` })
    await dialog.getByRole('button', { name: 'Next ticket' }).click()
    await expect(dialog.getByText(`Ticket 2 of ${admissions.length}`)).toBeVisible()
    if (width === 390) await expect(dialog.getByText('Fictional Night 2')).toBeVisible()
    await dialog.getByRole('button', { name: 'Close' }).click()
    await expect(showQr).toBeFocused()

    await page.getByRole('button', { name: 'Print tickets' }).click()
    await expect(page.locator('body')).toHaveAttribute('data-print-requested', 'true')
    await page.emulateMedia({ media: 'print' })
    const printed = page.locator('.box-office-print-ticket')
    await expect(printed).toHaveCount(admissions.length)
    await expect(printed.first()).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Box office', exact: true })).toBeHidden()
    const pdf = await page.pdf({ format: 'Letter' })
    expect(pdf.toString('latin1')).toMatch(new RegExp(`/Count ${admissions.length}\\b`))
    if (evidence) await writeFile(`${evidence}/print-${width}.pdf`, pdf)

    await page.emulateMedia({ media: 'screen' })
    await page.getByRole('button', { name: 'Email tickets' }).click()
    await page.getByRole('textbox', { name: 'Confirm buyer email' }).fill('player@example.test')
    await page.getByRole('button', { name: 'Send tickets' }).click()
    await expect(page.getByText('Ticket email queued for player@example.test.')).toBeVisible()
    await page.reload()
    await expect(page.getByText('Ticket email queued for player@example.test.')).toBeVisible()
  })
}

for (const width of [390, 1280]) {
  test(`a failed next sale never brings back the previous buyer's receipt at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    await prepare(page, bulk.slice(0, 2))
    await page.goto('/dashboard/events/601/box-office')
    await page.getByRole('button', { name: 'Add Admission' }).click()
    await page.getByRole('button', { name: /Process sale/ }).click()
    await expect(page.getByText('Sale complete!')).toBeVisible()

    await page.route(`${base}/box_office`, route => route.fulfill({ status: 422, json: { error: 'Only 0 Admission left.' } }))
    await page.getByRole('button', { name: 'Add Admission' }).click()
    await page.getByRole('button', { name: /Process sale/ }).click()
    const alert = page.getByRole('alert').filter({ hasText: 'Only 0 Admission left.' })
    await expect(alert).toBeVisible()
    await expect(alert).toBeFocused()
    await expect(page.getByText('Sale complete!')).toHaveCount(0)
    await expect(page.getByText('DEMO-W4A')).toHaveCount(0)
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
    const evidence = env.HAFAPASS_W4A_QA_DIR
    if (evidence) {
      await mkdir(evidence, { recursive: true })
      await page.screenshot({ path: `${evidence}/failed-next-sale-${width}.png` })
    }
  })
}

test('a weak-signal count refresh after a sale keeps the receipt and QR on screen', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await prepare(page, bulk.slice(0, 2))
  await page.goto('/dashboard/events/601/box-office')
  await page.getByRole('button', { name: 'Add Admission' }).click()
  await page.route(base, route => route.abort('failed'))
  await page.getByRole('button', { name: /Process sale/ }).click()
  await expect(page.getByText('Ticket counts may be out of date.')).toBeVisible()
  await expect(page.getByText('Sale complete!')).toBeVisible()
  await page.getByRole('button', { name: 'Show QR' }).click()
  const dialog = page.getByRole('dialog', { name: 'Show QR' })
  await expect(dialog.getByText('Ticket 1 of 2')).toBeVisible()
  await page.route(base, route => route.fulfill({ json: event }))
  await dialog.getByRole('button', { name: 'Close' }).click()
  await page.getByRole('button', { name: 'Retry', exact: true }).click()
  await expect(page.getByText('Ticket counts may be out of date.')).toHaveCount(0)
  await expect(page.getByText('Sale complete!')).toBeVisible()
})
