import { expect, test } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

const json = (route, body, status = 200) => route.fulfill({
  status, contentType: 'application/json', body: JSON.stringify(body),
})

test('admin sees fail-closed provider state and submits a complete policy evidence snapshot', async ({ page }) => {
  const policyControls = ['counsel_approved', 'accounting_approved', 'privacy_approved', 'effective_dates_approved', 'reacceptance_rules_approved', 'retention_deletion_and_legal_hold_approved']
  let submitted
  const capabilities = [
    {
      capability: 'stripe_live', label: 'Stripe live payments', configured: false, approved: false,
      enabled: false, status: 'not_configured', required_controls: ['territory_and_entity_approved'],
      pending_submission: null, latest_approval: null,
    },
    {
      capability: 'policy_register', label: 'Production policy register', configured: true, approved: false,
      enabled: false, status: 'disabled_pending_approval', required_controls: policyControls,
      pending_submission: null, latest_approval: null,
    },
  ]

  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/admin/platform_capabilities', route => json(route, { capabilities }))
  await page.route('**/api/v1/admin/platform_capabilities/policy_register/reviews', async route => {
    submitted = route.request().postDataJSON()
    return json(route, { id: 91, decision: 'submission' }, 201)
  })

  await page.goto('/admin/provider-readiness')

  await expect(page.getByRole('heading', { name: 'Provider and policy readiness' })).toBeVisible()
  const stripe = page.getByRole('region', { name: 'Stripe live payments' })
  await expect(stripe.getByText('Not Configured')).toBeVisible()
  await expect(stripe.getByRole('button', { name: 'Submit immutable evidence' })).toBeDisabled()

  const policy = page.getByRole('region', { name: 'Production policy register' })
  await expect(policy.getByText('Disabled Pending Approval')).toBeVisible()
  await policy.getByLabel('Evidence reference').fill('controlled/legal/policy-register-17')
  await policy.getByLabel('SHA-256 evidence digest').fill('a'.repeat(64))
  for (const checkbox of await policy.getByRole('checkbox').all()) await checkbox.check()
  const submissionResponse = page.waitForResponse(response =>
    response.url().includes('/api/v1/admin/platform_capabilities/policy_register/reviews') &&
      response.request().method() === 'POST')
  await policy.getByRole('button', { name: 'Submit immutable evidence' }).click()
  await submissionResponse

  expect(submitted).toMatchObject({
    evidence_reference: 'controlled/legal/policy-register-17',
    evidence_digest: 'a'.repeat(64),
    controls: Object.fromEntries(policyControls.map(control => [control, true])),
  })

  const results = await new AxeBuilder({ page }).analyze()
  expect(results.violations.filter(violation => ['serious', 'critical'].includes(violation.impact))).toEqual([])
})
