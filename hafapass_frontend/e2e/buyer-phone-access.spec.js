import { expect, test } from '@playwright/test'

const json = (route, body) => route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) })

test.beforeEach(async ({ page }) => {
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { environment: 'test', launch_capabilities: {} }))
  await page.route('**/api/v1/me/tickets?*', route => json(route, { tickets: [], meta: {} }))
  await page.route('**/api/v1/me/orders/recover_guest', route => json(route, { recovered_orders_count: 0 }))
})

for (const width of [390, 1440]) {
  test(`phone installation guidance is keyboard accessible without losing the buyer page at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 844 })
    await page.goto('/my-tickets')
    await expect(page.getByRole('heading', { name: 'My tickets', exact: true })).toBeVisible()
    const help = page.getByText('Add HåfaPass to your phone', { exact: true })
    await help.focus()
    await page.keyboard.press('Enter')
    await expect(page.getByText(/On iPhone or iPad/)).toBeVisible()
    await expect(page.getByText(/does not save every ticket/)).toBeVisible()
    await expect(page.getByRole('link', { name: /Account settings/ })).toBeVisible()
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
    await page.keyboard.press('Enter')
    await expect(page.getByText(/On iPhone or iPad/)).toBeHidden()
    await expect(help).toBeFocused()
  })
}

test('the buyer controls an installation offer received before navigating to tickets', async ({ page }) => {
  await page.route('**/api/v1/orders/99', route => json(route, {
    id: 99, reference: 'HP-99', status: 'completed', total_cents: 0, subtotal_cents: 0, service_fee_cents: 0,
    order_items: [], tickets: [], event: { id: 1, title: 'Synthetic installation rehearsal', status: 'published', timezone: 'Pacific/Guam' },
  }))
  await page.goto('/orders/99/confirmation')
  await expect(page.getByRole('link', { name: 'My tickets', exact: true })).toBeVisible()
  await page.evaluate(() => {
    window.installPromptCalls = 0
    const offer = new Event('beforeinstallprompt', { cancelable: true })
    offer.prompt = async () => { window.installPromptCalls += 1 }
    offer.userChoice = Promise.resolve({ outcome: 'dismissed' })
    window.dispatchEvent(offer)
  })
  await page.getByRole('link', { name: 'My tickets', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'My tickets', exact: true })).toBeVisible()
  await page.getByText('Add HåfaPass to your phone', { exact: true }).click()
  const install = page.getByRole('button', { name: 'Install HåfaPass', exact: true })
  await expect(install).toBeVisible()
  expect(await page.evaluate(() => window.installPromptCalls)).toBe(0)
  await install.click()
  expect(await page.evaluate(() => window.installPromptCalls)).toBe(1)
  await expect(install).toHaveCount(0)
  await expect(page.getByText(/On iPhone or iPad/)).toBeVisible()
})
