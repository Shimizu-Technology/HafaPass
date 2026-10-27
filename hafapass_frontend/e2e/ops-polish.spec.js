import { expect, test } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import crypto from 'node:crypto'
import process from 'node:process'

const before = process.env.OPS_POLISH_PHASE === 'before'
const capture = process.env.OPS_POLISH_CAPTURE === '1'
const json = (route, body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
const deliveries = [
  { id: 42, template: 'order_confirmation', recipient: 'synthetic-long-recipient-for-phone-layout@example.invalid', status: 'failed', attempts: 2, provider_id: null, last_error: 'Synthetic provider unavailable; retry after checking delivery access.' },
  { id: 43, template: 'ticket_email', recipient: 'guest@example.invalid', status: 'delivered', attempts: 1, provider_id: 'synthetic-provider-id' },
]
async function prepare(page) {
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await page.route('**/api/v1/**', route => json(route, {}))
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { payment_mode: 'simulate', buyer_terms_version: 'qa-v1', launch_capabilities: {} }))
  await page.route('**/api/v1/me', route => json(route, { id: 7, role: 'admin' }))
}
async function shot(page, name, width) {
  if (!capture) return
  await page.evaluate(() => document.fonts.ready)
  await page.screenshot({ path: `../docs/qa/ops-polish/${before ? 'before' : 'after'}/${name}-${width}.png`, fullPage: true })
}
async function check(page) {
  if (before) return
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
  const result = await new AxeBuilder({ page }).analyze()
  expect(result.violations).toEqual([])
}
async function neutral(button) {
  if (before) return
  await expect(button).toBeDisabled()
  const styles = await button.evaluate(node => { const s = getComputedStyle(node); return { opacity: s.opacity, background: s.backgroundColor, color: s.color, transition: s.transitionProperty, transform: s.transform, minHeight: parseFloat(s.minHeight), height: node.getBoundingClientRect().height, paddingTop: parseFloat(s.paddingTop), paddingLeft: parseFloat(s.paddingLeft), radius: parseFloat(s.borderRadius) } })
  expect(styles).toMatchObject({ opacity: '1', background: 'rgb(226, 232, 240)', color: 'rgb(71, 85, 105)', transform: 'none' })
  expect(styles.transition).not.toContain('opacity')
  expect(styles.minHeight).toBeGreaterThanOrEqual(44)
  expect(styles.height).toBeGreaterThanOrEqual(44)
  expect(styles.paddingTop).toBeGreaterThan(0)
  expect(styles.paddingLeft).toBeGreaterThan(0)
  expect(styles.radius).toBeGreaterThan(0)
}

for (const [width, height] of [[375, 812], [1280, 800]]) {
  test(`support search, deliveries, retry and recovery at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height })
    await prepare(page)
    // Test-only module replacement: render the real console with synthetic API
    // data. Clerk authorization itself is covered by SupportRoute unit tests.
    await page.route('**/src/components/SupportRoute.jsx*', route => route.fulfill({ contentType: 'application/javascript', body: 'export default function FixtureGate({children}) { return children }' }))
    let rows = []
    let failSearch = false
    const resends = []
    await page.route('**/api/v1/support/message_deliveries', route => json(route, { deliveries: rows }))
    await page.route('**/api/v1/support/search?**', route => json(route, failSearch ? { error: 'Synthetic lookup unavailable' } : { orders: [], tickets: [], events: [] }, failSearch ? 503 : 200))
    await page.route('**/api/v1/support/message_deliveries/42/resend', route => { resends.push(route.request().method()); return json(route, {}) })
    await page.goto('/support')
    await expect(page.getByText('No recent message deliveries.')).toBeVisible()
    const search = page.getByRole('button', { name: 'Search', exact: true })
    await neutral(search)
    if (!before) await expect(page.getByRole('heading', { name: 'Order results' })).toHaveCount(0)
    await shot(page, 'support-empty', width)
    await check(page)
    await page.getByLabel('Order, ticket, attendee, or event lookup').fill('missing-order')
    await expect(search).toBeEnabled()
    await search.click()
    await expect(page.getByRole('heading', { name: 'Order results' })).toBeVisible()
    if (!before) await expect(page.getByText('No orders match this search.')).toBeVisible()
    await shot(page, 'support-no-results', width)
    await check(page)
    rows = deliveries
    await page.reload()
    const retries = page.getByRole('button', { name: 'Retry delivery', exact: true })
    await expect(retries).toHaveCount(before ? 2 : 1)
    await expect(retries.nth(0)).toBeEnabled()
    if (before) await expect(retries.nth(1)).toBeDisabled()
    else await expect(page.getByRole('row').filter({ hasText: 'guest@example.invalid' }).getByRole('button')).toHaveCount(0)
    await shot(page, 'support-deliveries', width)
    await check(page)
    if (!before) {
      await retries.nth(0).focus()
      await page.keyboard.press('Enter')
      await expect.poll(() => resends).toEqual(['POST'])
      await expect(page.getByText('The original message was queued for another delivery attempt.')).toBeVisible()
      failSearch = true
      await page.getByLabel('Order, ticket, attendee, or event lookup').fill('kept-query')
      await search.click()
      await expect(page.getByText('Synthetic lookup unavailable')).toBeVisible()
      await expect(page.getByLabel('Order, ticket, attendee, or event lookup')).toHaveValue('kept-query')
      await expect(page.getByRole('heading', { name: 'Order results' })).toHaveCount(0)
    }
  })

  test(`scanner guidance and true refusal at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height })
    await prepare(page)
    await page.route(/\/api\/v1\/organizer\/events(?:\?.*)?$/, route => json(route, { error: 'Organization membership required' }, 403))
    await page.goto('/dashboard/scanner')
    await expect(page.getByText(before ? 'Organization membership required' : 'Scanning is for an organizer’s team and door staff.')).toBeVisible()
    if (!before) { await expect(page.getByRole('alert')).toHaveCount(0); await expect(page.getByRole('link', { name: 'Open organizer workspace' })).toHaveAttribute('href', '/dashboard') }
    if (before) await expect(page.getByRole('button', { name: 'Start camera' })).toBeDisabled()
    else {
      await expect(page.getByText('Online', { exact: true })).toBeVisible()
      await expect(page.getByRole('main').getByRole('button')).toHaveCount(0)
      await expect(page.getByRole('textbox')).toHaveCount(0)
      await expect(page.getByLabel('Event to scan')).toHaveCount(0)
      await expect(page.getByRole('navigation', { name: 'Check-in tools' })).toHaveCount(0)
      await expect(page.getByText('Device not ready', { exact: true })).toHaveCount(0)
    }
    await shot(page, 'scanner-no-membership', width)
    await check(page)
    if (!before) {
      await page.route(/\/api\/v1\/organizer\/events(?:\?.*)?$/, route => json(route, { events: [] }))
      await page.reload()
      await expect(page.getByText('No events are assigned to this account.')).toBeVisible()
      await expect(page.getByRole('alert')).toHaveCount(0)
      await expect(page.getByRole('main').getByRole('button')).toHaveCount(0)
      await page.route(/\/api\/v1\/organizer\/events(?:\?.*)?$/, route => json(route, { error: 'Scanner access withdrawn' }, 403))
      await page.reload()
      await expect(page.getByRole('alert')).toContainText('Scanner access withdrawn')
      await expect(page.getByRole('alert')).toHaveClass(/bg-red-50/)
    }
  })

  test(`assigned scanner prepares, admits and explains offline state at ${width}px`, async ({ page, context }) => {
    await page.setViewportSize({ width, height })
    await prepare(page)
    // Same RSA-PSS signed-manifest and device contract as event-day.spec.js.
    const event = { id: 42, title: 'Synthetic community event', status: 'published', timezone: 'Pacific/Guam' }
    const payload = { schema_version: 1, event, version: 1, generated_at: new Date(Date.now() - 1000).toISOString(), expires_at: new Date(Date.now() + 600_000).toISOString(), tickets: [{ ticket_id: 7, code: 'HP-T7', credential_hash: crypto.createHash('sha256').update('synthetic-scan-secret').digest('hex'), attendee_name: 'Synthetic Guest', ticket_type: 'Admission', state: 'valid' }] }
    const canonical = value => Array.isArray(value) ? `[${value.map(canonical).join(',')}]` : value !== null && typeof value === 'object' ? `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}` : JSON.stringify(value)
    const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 })
    const der = publicKey.export({ type: 'spki', format: 'der' })
    const digest = crypto.createHash('sha256').update(canonical(payload)).digest('hex')
    const manifest = { payload, digest, signature: crypto.sign('sha256', digest, { key: privateKey, padding: crypto.constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }).toString('base64url'), algorithm: 'PS256', key_id: crypto.createHash('sha256').update(der).digest('hex'), public_key_spki: der.toString('base64') }
    const device = { id: 8, identifier: 'ops-qa', effective: true, last_sequence: 0, authorization_expires_at: payload.expires_at }
    await page.route(/\/api\/v1\/organizer\/events(?:\?.*)?$/, route => json(route, { events: [event] }))
    let preparationBlocked = !before
    await page.route('**/api/v1/organizer/events/42/scanner_devices', route => preparationBlocked
      ? json(route, { error: 'Synthetic setup unavailable' }, 503) : json(route, device, 201))
    await page.route('**/api/v1/organizer/events/42/scanner_devices/8/manifest', route => json(route, manifest))
    await page.route('**/api/v1/organizer/events/42/admissions', route => json(route, { counts: {}, permissions: {}, recent_actions: [] }))
    await page.goto('/dashboard/scanner?event=42')
    if (!before) {
      await expect(page.getByRole('alert')).toContainText('Synthetic setup unavailable')
      await expect(page.getByRole('button', { name: 'Start camera' })).toBeDisabled()
      await expect(page.getByLabel('Ticket QR code', { exact: true })).toBeVisible()
      await expect(page.getByRole('navigation', { name: 'Check-in tools' })).toBeVisible()
      await expect(page.getByText('Connect and choose an assigned event to prepare this device for scanning.')).toBeVisible()
      await expect(page.getByText(/If this phone is lost/)).not.toBeVisible()
      await expect(page.locator('body')).not.toContainText('Clerk')
      await shot(page, 'scanner-authorized-unprepared', width)
      await check(page)
      await page.getByText('Device details', { exact: true }).click()
      await expect(page.getByText(/If this phone is lost/)).toBeVisible()
      await page.getByText('Device details', { exact: true }).click()
      preparationBlocked = false
      await page.getByRole('button', { name: 'Verify scanner access' }).click()
    }
    await expect(page.getByRole('button', { name: 'Start camera' })).toBeEnabled()
    if (!before) await expect(page.getByRole('heading', { name: 'Device ready', exact: true })).toBeVisible()
    await shot(page, 'scanner-assigned', width)
    await shot(page, 'scanner-ready', width)
    await check(page)
    await context.setOffline(true)
    await expect(page.getByText('Offline mode', { exact: true })).toBeVisible()
    await page.getByLabel('Ticket QR code').fill('synthetic-scan-secret')
    await page.getByRole('button', { name: 'Check in ticket', exact: true }).click()
    await expect(page.getByText('Admitted offline', { exact: true })).toBeVisible()
    await expect(page.getByTestId('scanner-pending-count')).toHaveText('1')
  })
}

for (const [width, height] of [[375, 812], [1280, 800]]) {
  test(`shared disabled variants and checkout pay form at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height })
    // Isolated component fixture for Stripe-not-ready: no payment is created.
    await page.route('**/node_modules/.vite/deps/@stripe_react-stripe-js.js*', route => route.fulfill({ contentType: 'application/javascript', body: 'export const useStripe = () => null; export const useElements = () => null; export const PaymentElement = () => null; export const Elements = ({children}) => children;' }))
    await page.route('**/ops-payment-fixture', route => route.fulfill({ contentType: 'text/html', body: `<html lang="en"><head><title>Operational button QA</title></head><body><main id="root"></main><script type="module">
      import RefreshRuntime from '/@react-refresh';
      RefreshRuntime.injectIntoGlobalHook(window); window.$RefreshReg$ = () => {}; window.$RefreshSig$ = () => type => type; window.__vite_plugin_react_preamble_installed__ = true;
      </script><script type="module">
      import React from '/node_modules/.vite/deps/react.js';
      import ReactDOM from '/node_modules/.vite/deps/react-dom_client.js';
      import '${before ? '/src/ops-baseline.css' : '/src/index.css'}'; import '/src/i18n.js';
      import PaymentForm from '${before ? '/src/components/OpsBaselinePaymentForm.jsx' : '/src/components/PaymentForm.jsx'}';
      ReactDOM.createRoot(document.getElementById('root')).render(React.createElement('div', {style:{padding:24,maxWidth:560,margin:'auto'}},
        React.createElement('h1', null, 'Synthetic payment form'),
        React.createElement(PaymentForm, {totalCents:2500,submitting:false,setSubmitting:()=>{}}),
        ...['primary','teal','danger','secondary','ghost'].map(name=>React.createElement('button',{key:name,disabled:true,className:'btn-'+name+' disabled:opacity-50',style:{marginTop:12,display:'block'}},name+' submit'))));
    </script></body></html>` }))
    await page.goto('/ops-payment-fixture')
    const pay = page.getByRole('button', { name: /Pay.*25/ })
    await expect(pay).toBeDisabled()
    await shot(page, 'disabled-payment-and-forms', width)
    await neutral(pay)
    for (const variant of ['primary', 'teal', 'danger', 'secondary', 'ghost']) {
      const button = page.getByRole('button', { name: `${variant} submit`, exact: true })
      await neutral(button)
      await button.hover()
      await page.mouse.down()
      await neutral(button)
      await page.mouse.up()
    }
    await check(page)
    if (!before) {
      for (const [variant, background] of [['primary', 'rgb(201, 54, 46)'], ['teal', 'rgb(11, 101, 99)'], ['danger', 'rgb(185, 28, 28)']]) {
        const button = page.getByRole('button', { name: `${variant} submit`, exact: true })
        // Also catch a pruned enabled variant rule: a neutral disabled override
        // alone can mask a missing base/color class.
        await button.evaluate(node => { node.disabled = false })
        await page.mouse.move(0, 0)
        await expect(button).toHaveCSS('background-color', background)
        await expect(button).toHaveCSS('min-height', '44px')
      }
    }
  })
}

for (const [width, height] of [[375, 812], [1280, 800]]) {
  test(`shared admin table preserves readable labels and order navigation at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height })
    await prepare(page)
    await page.route('**/api/v1/admin/disputes?**', route => json(route, { disputes: [{ id: 1, status: 'open', reason: 'duplicate', amount_cents: 2500, currency: 'usd', opened_at: '2026-10-27T00:00:00Z', provider_dispute_id: 'synthetic-provider-reference'.repeat(5), order: { id: 42, buyer_name: 'Synthetic Guest', buyer_email: 'guest@example.invalid' }, event: { title: 'Synthetic community event with a long title'.repeat(3) }, organization: { name: 'Synthetic organization'.repeat(5) } }], status_counts: { open: 1 }, meta: { current_page: 1, total_pages: 1, total_count: 1 } }))
    await page.goto('/admin/disputes')
    await expect(page.getByRole('link', { name: 'Order #42' })).toBeVisible()
    await check(page)
    if (width >= 768) {
      const heading = page.getByRole('columnheader', { name: 'Opened', exact: true })
      expect(await heading.evaluate(node => getComputedStyle(node).textTransform)).toBe('none')
      expect(await heading.evaluate(node => getComputedStyle(node).fontSize)).toBe('14px')
    } else {
      expect(await page.getByRole('cell').first().evaluate(node => getComputedStyle(node, '::before').content)).toContain('Opened')
    }
    await shot(page, 'admin-shared-table', width)
    await page.getByRole('link', { name: 'Order #42' }).focus()
    await page.keyboard.press('Enter')
    await expect(page).toHaveURL(/\/admin\/orders\?search=%2342$/)
  })
}
