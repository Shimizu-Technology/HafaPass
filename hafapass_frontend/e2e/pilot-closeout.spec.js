import { expect, test } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

const json = (route, body, status = 200) => route.fulfill({
  status, contentType: 'application/json', body: JSON.stringify(body),
})

test('admin independently approves the exact Gate J closeout and Guam expansion decision', async ({ page }) => {
  let approvalRequested = false
  const event = {
    id: 42, title: 'Guam Community Night', slug: 'guam-community-night', status: 'completed',
    category: 'festival', is_featured: false, starts_at: '2026-09-21T08:00:00Z', tickets_sold: 48,
    revenue_cents: 144000, organizer_name: 'Island Community Group', live_money_proof_candidate: false,
    pilot_readiness: { approval_recorded: true }, pilot_validation: { approval_recorded: true },
    event_day_rehearsal: { approval_recorded: true }, live_money_proof: { approval_recorded: true },
    live_pilot: { approval_recorded: true, run_status: 'completed' },
    pilot_closeout: { eligible: true, pending_submission: { id: 101 }, completed_run_id: 91 },
  }
  const metrics = {
    completed_order_count: 40, checkout_conversion_bps: 6250, checkout_abandonment_bps: 3750,
    no_show_rate_bps: 625, refund_average_seconds: 420, payout_variance_cents: 0,
    partner_attributed_order_count: 8, support_note_count: 3, entry_latency_p95_ms: 380,
  }
  const submission = {
    id: 101, event_id: 42, live_pilot_run_id: 91, actor_user_id: 7, decision: 'submission',
    expansion_decision: 'limited_guam_expansion', signed_at: '2026-09-22T08:00:00Z',
    evidence_reference: 'restricted-closeout/gate-j/42', evidence_digest: 'a'.repeat(64),
    application_revision: 'b'.repeat(40), local_state_digest: 'c'.repeat(64),
    outcome_metrics: {
      support_contacts_count: 3, entry_latency_p50_ms: 180, entry_latency_p95_ms: 380,
      organizer_feedback_rating: 5, buyer_feedback_response_count: 12, buyer_feedback_rating: 4,
    },
    evidence_references: Object.fromEntries([
      'financial', 'provider', 'admission', 'support', 'cleanup', 'metrics', 'feedback', 'retrospective',
    ].map((key, index) => [key, `restricted-closeout/evidence-${index}`])),
    reconciliation_results: Object.fromEntries([
      'sales', 'discounts', 'taxes', 'fees', 'refunds', 'disputes', 'add_ons', 'door_sales', 'settlement',
      'payout', 'scans', 'support_cases', 'message_exceptions', 'admission_exceptions',
      'reconciliation_exceptions',
    ].map(key => [key, true])),
    cleanup_results: Object.fromEntries([
      'temporary_staff_revoked', 'scanner_devices_revoked', 'device_local_data_purged',
      'retention_policy_followed',
    ].map(key => [key, true])),
    expansion_scope: {
      event_limit: 3, max_inventory_per_event: 500, expires_at: '2026-11-20T08:00:00Z',
      new_regions: false, rationale: 'Demand and operating capacity support three more Guam events.',
      demand_evidence_reference: 'restricted-closeout/demand',
      capacity_evidence_reference: 'restricted-closeout/capacity', recommended_product_investments: [],
    },
    metric_report: metrics, retrospective_actions: [{
      title: 'Publish organizer-success response targets', owner_reference: 'restricted-owners/success',
      due_at: '2026-09-25T08:00:00Z', status: 'completed', priority: 'p1',
      evidence_reference: 'restricted-closeout/actions/response-targets', blocks_expansion: true,
    }],
  }
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/admin/events?*', route => json(route, {
    events: [event], meta: { page: 1, per_page: 20, total: 1, total_pages: 1 },
  }))
  await page.route('**/api/v1/admin/events/42/pilot_closeout', route => json(route, {
    event, pilot_closeout: { eligible: true, approved: false, pending_submission: submission, local_metrics: metrics },
  }))
  await page.route('**/api/v1/admin/pilot_closeout_reviews/101/approve', route => {
    approvalRequested = true
    return json(route, { ...submission, id: 102, decision: 'approval', active: true }, 201)
  })

  await page.goto('/admin/events')
  await page.getByRole('button', { name: 'Review Gate J closeout' }).click()
  await expect(page.getByText('limited guam expansion', { exact: true })).toBeVisible()
  await expect(page.getByText('Publish organizer-success response targets')).toBeVisible()
  await expect(page.getByText('6250')).toBeVisible()
  await expect(page.getByText('Demand and operating capacity support three more Guam events.')).toBeVisible()
  await expect(page.getByText('restricted-closeout/demand')).toBeVisible()
  await expect(page.getByText('restricted-closeout/evidence-0')).toBeVisible()
  await expect(page.getByText('Not authorized')).toBeVisible()

  const accessibility = await new AxeBuilder({ page }).analyze()
  expect(accessibility.violations.filter(item => ['serious', 'critical'].includes(item.impact))).toEqual([])
  const response = page.waitForResponse(item => item.url().endsWith('/pilot_closeout_reviews/101/approve'))
  await page.getByRole('button', { name: 'Approve exact Gate J decision' }).click()
  await response

  expect(approvalRequested).toBe(true)
})
