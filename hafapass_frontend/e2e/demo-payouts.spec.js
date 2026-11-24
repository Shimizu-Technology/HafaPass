import { expect, test } from '@playwright/test'

// Preview-only click-through: organizer payout statements in every state and
// the admin Due list. Fictional data, in memory, no network.
const shots = process.env.PAYOUT_QA_SCREENSHOTS

for (const viewport of [{ width: 390, height: 844 }, { width: 1280, height: 900 }]) {
  test.describe(`demo payouts at ${viewport.width}px`, () => {
    test.use({ viewport })
    let problems
    test.beforeEach(async ({ page }) => {
      problems = []
      page.on('console', message => { if (['error', 'warning'].includes(message.type())) problems.push(message.text()) })
      page.on('pageerror', error => problems.push(error.message))
      page.on('request', request => { if (/onrender\.com|localhost:3000|127\.0\.0\.1:3000|stripe\.com|clerk\./i.test(request.url())) problems.push(request.url()) })
    })
    test.afterEach(() => expect(problems).toEqual([]))

    test('finances → each payout statement state', async ({ page }) => {
      await page.goto('/dashboard/finances')
      await expect(page.getByTestId('demo-preview-banner')).toBeVisible()
      const expected = [
        [9311, 'Waiting for payout'], [9312, 'Paid — reserve held until Mar 1, 2027'], [9313, 'Final'], [9314, 'Final'], [101, 'Sales open'],
      ]
      for (const [id, label] of expected) {
        await page.goto(`/dashboard/events/${id}/statement`)
        await expect(page.getByTestId('statement-status')).toHaveText(label)
        expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(viewport.width)
      }
      await page.goto('/dashboard/finances')
      await page.getByRole('link', { name: /View statement/ }).first().click()
      await expect(page.getByTestId('payout-receipt')).toBeVisible()
      await page.goto('/dashboard/events/9312/analytics')
      await page.getByTestId('payout-statement-link').click()
      await expect(page.getByTestId('statement-status')).toHaveText('Paid — reserve held until Mar 1, 2027')
      if (shots && viewport.width === 390) await page.screenshot({ path: `${shots}/demo-statement-390.png`, fullPage: true, scale: 'css' })
    })

    test('admin Due: hold reserve, finalize, request payout', async ({ page }) => {
      await page.goto('/admin/payouts?view=due')
      const row = page.getByTestId('due-row-9311')
      await expect(row).toContainText('Hold the reserve')
      await row.getByRole('button', { name: /Hold .* reserve/ }).click()
      await page.getByRole('dialog').getByRole('button', { name: 'Hold reserve' }).click()
      await expect(page.getByText(/held for Isla Demo Grappling Open/)).toBeVisible()
      await row.getByRole('button', { name: 'Finalize statement' }).click()
      await row.getByRole('button', { name: /Request payout/ }).click()
      await expect(row).toContainText('Record the bank transfer')
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(viewport.width)
      if (shots && viewport.width === 1280) await page.screenshot({ path: `${shots}/demo-admin-due-1280.png`, fullPage: true, scale: 'css' })
    })
  })
}
