import { expect, test } from '@playwright/test'

const json = (route, body) => route.fulfill({
  status: 200, contentType: 'application/json', body: JSON.stringify(body),
})

for (const width of [375, 1280]) {
  test(`admin audit privacy wording, details and search work at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    let searched = false
    await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
    await page.route('**/api/v1/admin/audit_logs*', route => {
      const query = new URL(route.request().url()).searchParams
      searched ||= query.get('q') === 'ticket_type.updated'
      return json(route, {
        audit_logs: [{
          id: 31, action: 'ticket_type.updated', occurred_at: '2026-10-24T01:00:00Z',
          source: 'user', outcome: 'succeeded', actor_user_id: 77, actor: null,
          target: { type: 'TicketType', id: 42 }, organization: { id: 7, name: 'Island Community Events' },
          before_data: { price_cents: 2000 }, after_data: { price_cents: 2500 },
          metadata: { search_used: true }, request_id: 'qa-audit-request',
        }], meta: { page: 1, total_pages: 1, total_count: 1 }, areas: ['ticket_type'],
      })
    })
    await page.goto('/admin/audit-log')
    await expect(page.getByText('Deleted user #77', { exact: true })).toBeVisible()
    await expect(page.getByText('Personal details may be redacted for privacy or retention.', { exact: false })).toBeVisible()
    await expect(page.getByText('Entries cannot be edited or deleted.', { exact: false })).toHaveCount(0)
    await page.getByRole('button', { name: 'Details for entry 31' }).click()
    await expect(page.getByText('price_cents', { exact: true })).toBeVisible()
    await expect(page.getByText('2000', { exact: true })).toBeVisible()
    await expect(page.locator('dd').filter({ hasText: '2500' })).toBeVisible()
    await expect(page.getByText(/request qa-audit-request/)).toBeVisible()
    if (width < 768) await page.getByRole('button', { name: 'Filters', exact: true }).click()
    if (!await page.getByRole('searchbox', { name: 'Search the audit log' }).isVisible()) await page.getByRole('button', { name: /^Filters(?: \(\d+\))?$/ }).click()
    await page.getByRole('searchbox', { name: 'Search the audit log' }).fill('ticket_type.updated')
    await page.getByRole('button', { name: 'Search', exact: true }).click()
    await expect.poll(() => searched).toBe(true)
    await expect(page).toHaveURL(/q=ticket_type.updated/)
    await page.getByRole('button', { name: 'Details for entry 31' }).click()
    await page.reload()
    if (width < 768) await page.getByRole('button', { name: /^Filters(?: \(\d+\))?$/ }).click()
    await expect(page.getByRole('searchbox', { name: 'Search the audit log' })).toHaveValue('ticket_type.updated')
    await page.getByRole('button', { name: 'Details for entry 31' }).click()
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
    await page.screenshot({ path: `test-results/audit-integrity-${width}.png`, fullPage: true })
  })
}
