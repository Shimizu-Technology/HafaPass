import { expect, test } from '@playwright/test'

const json = (route, data, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(data) })
const hold = () => { let release; const promise = new Promise(resolve => { release = resolve }); return { promise, release } }

// Browser contracts use the existing Clerk-free CI build and synthetic API
// fixtures. Real Clerk acceptance is recorded separately in the QA ledger.
async function prepare(page) {
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { launch_capabilities: { advanced_sales_tools: true } }))
  await page.route('**/api/v1/organizer/organizations', route => json(route, [{ id: 1, name: 'Synthetic Organizer', role: 'owner' }]))
}

for (const width of [375, 1280]) {
  for (const outcome of ['success', 'failure']) {
    test(`invitation ${outcome} after organization switch ends loading at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 900 })
      await prepare(page)
      const pending = hold()
      let requested = false
      await page.route('**/api/v1/organization_invitations/accept', async route => {
        requested = true
        await pending.promise
        return outcome === 'success' ? json(route, { organization_id: 4, organization_name: 'Old team', role: 'scanner' })
          : json(route, { error: 'Expired invitation' }, 422)
      })
      await page.goto('/organization-invitations/accept?token=synthetic-slow-invitation')
      await expect(page.getByText('Accepting invitation…', { exact: true })).toBeVisible()
      await expect.poll(() => requested).toBe(true)
      await page.evaluate(() => localStorage.setItem('hafapass_organization_id', '9'))
      pending.release()
      await expect(page.getByRole('alert')).toContainText('You switched organizations')
      await expect(page.getByText('Accepting invitation…', { exact: true })).toHaveCount(0)
      expect(await page.evaluate(() => localStorage.getItem('hafapass_organization_id'))).toBe('9')
      await expect(page.getByRole('link', { name: 'Go to dashboard' })).toBeVisible()
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
    })
  }

  test(`authorized member reviews and recovers a failed campaign at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    await prepare(page)
    const event = { id: 601, organization_id: 1, title: 'Synthetic Community Event', status: 'draft',
      venue_name: 'Synthetic venue', starts_at: '2099-10-20T07:00:00Z', timezone: 'Pacific/Guam', ticket_types: [],
      permissions: { manage_marketing: true }, supported_locales: [], localized_content: {} }
    const campaign = { id: 77, name: 'Door reminder', subject: 'Doors open soon', body: 'Bring your ticket.',
      status: 'failed', segment: { type: 'checked_in' }, recipient_count: 0,
      last_error: 'Needs attention: the scheduler no longer has permission. Review and reschedule.' }
    let saved, sent = false
    await page.route('**/api/v1/organizer/events/601', route => json(route, event))
    await page.route('**/api/v1/organizer/events/601/promoters', route => json(route, { promoters: [] }))
    await page.route('**/api/v1/organizer/events/601/communication_campaigns', route => json(route, { communication_campaigns: [campaign] }))
    await page.route('**/api/v1/organizer/events/601/communication_campaigns/77', route => {
      saved = route.request().postDataJSON()
      Object.assign(campaign, saved, { status: 'draft', last_error: null })
      return json(route, campaign)
    })
    await page.route('**/api/v1/organizer/events/601/communication_campaigns/77/send_now', route => {
      sent = true
      campaign.status = 'sent'
      return json(route, campaign, 202)
    })
    await page.goto('/dashboard/events/601/sales-tools')
    const recovery = page.getByRole('button', { name: 'Review and reschedule' })
    await expect(recovery).toBeVisible()
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
    await recovery.click()
    await expect(page.getByLabel('Internal campaign name')).toBeFocused()
    await expect(page.getByLabel('Email subject')).toHaveValue('Doors open soon')
    await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toHaveValue('Bring your ticket.')
    await expect(page.getByLabel('Recipients')).toHaveValue('checked_in')
    await page.getByLabel('Email subject').fill('Reviewed door reminder')
    await page.getByRole('button', { name: 'Save campaign changes' }).click()
    await expect.poll(() => saved?.subject).toBe('Reviewed door reminder')
    expect(saved.scheduled_at).toBeNull()
    expect(sent).toBe(false)
    const send = page.getByRole('button', { name: 'Send now' })
    await expect(send).toBeEnabled()
    await send.click()
    await expect.poll(() => sent).toBe(true)
    await expect(send).toHaveCount(0)
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
  })
}
