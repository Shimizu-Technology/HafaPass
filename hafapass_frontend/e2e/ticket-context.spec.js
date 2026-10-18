import { expect, test } from '@playwright/test'

const ticket = id => ({ id, status: 'issued', admission_allowed: true, scan_credential: `synthetic-scan-${id}`,
  wallet_availability: { apple: false, google: true },
  event: { title: `Ticket event ${id}`, status: 'published', starts_at: '2026-11-20T07:00:00Z', timezone: 'Pacific/Guam', venue_name: 'QA Venue' },
  ticket_type: { name: 'Admission' } })
const json = (route, data) => route.fulfill({ contentType: 'application/json', body: JSON.stringify(data) })
const popToTicketB = page => page.evaluate(() => {
  window.history.pushState({}, '', '/tickets/display-b?order=2')
  window.dispatchEvent(new PopStateEvent('popstate'))
})
const nextFrame = page => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    window.sessionStorage.setItem('hafapass:order-access:1', 'synthetic-guest-one')
    window.sessionStorage.setItem('hafapass:order-access:2', 'synthetic-guest-two')
  })
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { environment: 'test', launch_capabilities: {} }))
})

test('browser pop navigation retains the newer ticket and QR when the old response arrives last', async ({ page }) => {
  let oldRoute
  await page.route('**/api/v1/tickets/display-a', route => { oldRoute = route })
  await page.route('**/api/v1/tickets/display-b', route => json(route, ticket(2)))
  await page.goto('/tickets/display-a?order=1')
  await expect.poll(() => Boolean(oldRoute)).toBe(true)
  await popToTicketB(page)
  await expect(page.getByRole('heading', { name: 'Ticket event 2' })).toBeVisible()
  const qr = page.getByRole('img', { name: 'Ticket entry QR code' })
  const newerQr = await qr.innerHTML()
  await json(oldRoute, ticket(1))
  await nextFrame(page)
  await expect(page.getByText('Ticket HP-T2', { exact: true })).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Ticket event 2' })).toBeVisible()
  expect(await qr.innerHTML()).toBe(newerQr)
})

test('suppresses the old Google Wallet redirect after route change and opens the current wallet', async ({ page, baseURL }) => {
  let oldWallet
  await page.route('**/api/v1/tickets/display-a', route => json(route, ticket(1)))
  await page.route('**/api/v1/tickets/display-b', route => json(route, ticket(2)))
  await page.route('**/api/v1/tickets/display-a/wallet/google?*', route => { oldWallet = route })
  await page.route('**/api/v1/tickets/display-b/wallet/google?*', route => json(route, { url: `${baseURL}/wallet-result?ticket=2` }))
  await page.route('**/wallet-result?*', route => route.fulfill({ contentType: 'text/html', body: '<p>Current wallet opened</p>' }))
  await page.goto('/tickets/display-a?order=1')
  await page.getByRole('button', { name: 'Google Wallet' }).click()
  await expect.poll(() => Boolean(oldWallet)).toBe(true)
  expect(oldWallet.request().headers()['x-guest-order-token']).toBe('synthetic-guest-one')
  await popToTicketB(page)
  await expect(page.getByRole('heading', { name: 'Ticket event 2' })).toBeVisible()
  await json(oldWallet, { url: `${baseURL}/wallet-result?ticket=1` })
  await nextFrame(page)
  expect(page.url()).toBe(`${baseURL}/tickets/display-b?order=2`)
  await page.getByRole('button', { name: 'Google Wallet' }).click()
  await expect(page).toHaveURL(`${baseURL}/wallet-result?ticket=2`)
  await expect(page.getByText('Current wallet opened')).toBeVisible()
})
