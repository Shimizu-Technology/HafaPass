import { env } from 'node:process'
import { readFileSync } from 'node:fs'
import { expect, test } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

// CodeRabbit review of bca5f904 (4707205487, 4707205465): the admin outcome
// dialog records a reversal on an event with a never-fulfilled capture with
// the bank's exact return, from what the listing says it needs. The listing
// is the real admin API's response for fictional data
// (e2e/fixtures/a2-review/admin-payouts-reversal.json): a paid manual payout
// on a classified event (return required, stored transfer ID kept), a
// placeholder one there (the real transfer ID required), an ordinary paid
// payout elsewhere (the generic reversal) and an accepted transfer finance
// has not yet recorded (no outcome offered, never a send instruction). The
// PATCH is captured and answered here; nothing is sent anywhere. Set
// PAYOUT_QA_SCREENSHOTS=<dir> to save review screenshots.
const listing = JSON.parse(readFileSync(new URL('./fixtures/a2-review/admin-payouts-reversal.json', import.meta.url)))
const shots = env.PAYOUT_QA_SCREENSHOTS
const json = (route, data) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(data) })
const snap = (page, name) => shots ? page.screenshot({ path: `${shots}/${name}.png`, fullPage: true, scale: 'css' }) : null
const byTransfer = id => listing.payouts.find(payout => payout.provider_payout_id === id)
const classifiedPaid = byTransfer('FICTBANK-TRX-0042')
const ordinaryPaid = byTransfer('FICTBANK-TRX-0077')
const accepted = byTransfer('FICTBANK-ACC-0101')
const placeholder = listing.payouts.find(payout => payout.status === 'processing')

async function base(page, patches) {
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await page.route('**/api/v1/**', route => json(route, {}))
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { launch_capabilities: {}, payment_mode: 'simulate',
    service_fee_percent: '5.0', service_fee_flat_cents: 100, organizer_payout_terms: null }))
  await page.route('**/api/v1/admin/payouts**', route => {
    if (route.request().method() === 'PATCH') {
      patches.push({ url: route.request().url(), body: route.request().postDataJSON() })
      return json(route, { id: 1, status: 'reversed' })
    }
    return json(route, listing)
  })
}
async function noOverflow(page, width) {
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
}
const row = (page, transfer) => page.locator('tbody tr').filter({ hasText: transfer })

for (const width of [390, 1280]) {
  test.describe(`at ${width}px`, () => {
    let patches
    test.beforeEach(async ({ page }) => {
      patches = []
      await page.setViewportSize({ width, height: 900 })
      await base(page, patches)
    })

    test('records a classified reversal with the bank return, by keyboard, after the form shows each missing field', async ({ page }) => {
      await page.goto('/admin/payouts')
      const target = row(page, 'FICTBANK-TRX-0042')
      await expect(target).toHaveCount(1)
      // Keyboard only: focus the row's button and open the dialog.
      await target.getByRole('button', { name: `Record outcome for payout #${classifiedPaid.id}` }).focus()
      await page.keyboard.press('Enter')
      const dialog = page.getByRole('dialog', { name: `Record outcome for payout #${classifiedPaid.id}` })
      await expect(dialog).toBeVisible()
      await expect(dialog.getByRole('radio', { name: /Reversed/ })).toBeChecked()
      const evidence = dialog.getByRole('group', { name: 'Bank return evidence (required)' })
      await expect(evidence).toContainText('exact return of the $42.00 that left')
      await expect(dialog.getByLabel(/Transfer ID/)).toBeDisabled()
      await expect(dialog.getByLabel(/Transfer ID/)).toHaveValue('FICTBANK-TRX-0042')

      await dialog.getByLabel('Confirmation reference').fill('Fictional bank statement 2026-11-26 line 9')
      await dialog.getByLabel('How you confirmed it').fill('The bank statement shows the full return of this transfer')
      await dialog.getByRole('button', { name: 'Record as reversed' }).click()
      await expect(evidence.getByText('Enter the return reference the bank gave for this transfer.')).toBeVisible()
      await expect(evidence.getByText('Enter the amount the bank returned, in dollars and cents.')).toBeVisible()
      await expect(evidence.getByLabel('Bank return reference')).toHaveAttribute('aria-invalid', 'true')
      const result = await new AxeBuilder({ page }).include('[role="dialog"]').analyze()
      expect(result.violations.filter(item => ['serious', 'critical'].includes(item.impact))).toEqual([])
      await noOverflow(page, width)
      await snap(page, `a2-reversal-errors-${width}`)

      await evidence.getByLabel('Bank return reference').focus()
      await page.keyboard.type('RET-FICT-0042')
      await page.keyboard.press('Tab')
      await expect(evidence.getByLabel('Amount the bank returned (USD)')).toBeFocused()
      await page.keyboard.type('41.99')
      await page.keyboard.press('Enter')
      await expect(evidence.getByText(/must have returned the full \$42\.00 that left/)).toBeVisible()
      expect(patches).toEqual([])

      await evidence.getByLabel('Amount the bank returned (USD)').fill('42.00')
      await snap(page, `a2-reversal-filled-${width}`)
      await page.keyboard.press('Enter')
      await expect(page.getByRole('status').filter({ hasText: `Payout #${classifiedPaid.id} recorded as reversed.` })).toBeVisible()
      expect(patches).toHaveLength(1)
      expect(patches[0].url).toMatch(new RegExp(`/api/v1/admin/payouts/${classifiedPaid.id}$`))
      expect(patches[0].body).toMatchObject({ status: 'reversed', evidence: {
        reference: 'Fictional bank statement 2026-11-26 line 9', return_reference: 'RET-FICT-0042', returned_amount_cents: 4200,
      } })
      expect(patches[0].body).not.toHaveProperty('provider_payout_id')
      expect(Date.parse(patches[0].body.evidence.returned_at)).toBeGreaterThanOrEqual(Date.parse(classifiedPaid.reversal.earliest_returned_at) - 60_000)
    })

    test('asks for the real transfer ID on a placeholder; keeps the ordinary reversal; never offers the impossible', async ({ page }) => {
      await page.goto('/admin/payouts')
      await row(page, placeholder.provider_payout_id).getByRole('button', { name: /Record outcome/ }).click()
      let dialog = page.getByRole('dialog')
      await dialog.getByRole('radio', { name: /Reversed/ }).check()
      await expect(dialog.getByLabel(/Transfer ID \(required\)/)).toBeEnabled()
      await expect(dialog.getByText('Enter the ID of the transfer that left, as the bank shows it, not the request placeholder.')).toBeVisible()
      // Switching back to Failed removes the return fields again.
      await dialog.getByRole('radio', { name: /Failed/ }).check()
      await expect(dialog.getByRole('group', { name: 'Bank return evidence (required)' })).toHaveCount(0)
      await dialog.getByRole('button', { name: 'Cancel' }).click()

      await row(page, 'FICTBANK-TRX-0077').getByRole('button', { name: /Record outcome/ }).click()
      dialog = page.getByRole('dialog')
      await expect(dialog.getByRole('radio', { name: /Reversed/ })).toBeChecked()
      await expect(dialog.getByRole('group', { name: 'Bank return evidence (required)' })).toHaveCount(0)
      await dialog.getByLabel('Confirmation reference').fill('Fictional statement line 2')
      await dialog.getByLabel('How you confirmed it').fill('Bank returned it')
      await dialog.getByRole('button', { name: 'Record as reversed' }).click()
      await expect(page.getByRole('status').filter({ hasText: `Payout #${ordinaryPaid.id} recorded as reversed.` })).toBeVisible()
      expect(patches[0].body.evidence).not.toHaveProperty('return_reference')

      const acceptedRow = row(page, 'FICTBANK-ACC-0101')
      // Its stored message already says not to send it (no second note).
      await expect(acceptedRow.getByText(/it has been sent\. Do not send it again\./)).toBeVisible()
      await expect(acceptedRow.getByText(/Send the transfer/)).toHaveCount(0)
      await expect(acceptedRow.getByText(accepted.reversal.unavailable_reason)).toBeVisible()
      await expect(acceptedRow.getByRole('button', { name: /Record outcome/ })).toHaveCount(0)
      await expect(acceptedRow.getByText('No outcome here')).toBeVisible()
      await expect(page.getByText(/Approval is current/)).toHaveCount(0)
      await noOverflow(page, width)
      await snap(page, `a2-reversal-list-${width}`)
    })
  })
}
