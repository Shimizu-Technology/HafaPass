import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import PilotCloseoutDialog from './PilotCloseoutDialog'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))

const event = { id: 42, title: 'Guam Community Night', status: 'completed', pilot_closeout: {} }
const localMetrics = {
  completed_order_count: 3, checkout_conversion_bps: 6000, checkout_abandonment_bps: 4000,
  no_show_rate_bps: 500, refund_average_seconds: 30, payout_variance_cents: 0,
  partner_attributed_order_count: 1, support_note_count: 2,
}
const pending = {
  id: 91, live_pilot_run_id: 81, actor_user_id: 7, expansion_decision: 'hold',
  signed_at: '2026-07-21T13:00:00Z', evidence_reference: 'restricted-closeout/gate-j',
  evidence_digest: 'a'.repeat(64), metric_report: localMetrics,
  application_revision: 'b'.repeat(40), local_state_digest: 'c'.repeat(64),
  outcome_metrics: {
    support_contacts_count: 2, entry_latency_p50_ms: 120, entry_latency_p95_ms: 250,
    organizer_feedback_rating: 5, buyer_feedback_response_count: 3, buyer_feedback_rating: 4,
  },
  evidence_references: Object.fromEntries(evidenceFieldsForTest().map((key, index) => [key, `restricted/evidence-${index}`])),
  reconciliation_results: Object.fromEntries(reconciliationFieldsForTest().map(key => [key, true])),
  cleanup_results: Object.fromEntries(cleanupFieldsForTest().map(key => [key, true])),
  expansion_scope: {
    event_limit: 0, max_inventory_per_event: 0, expires_at: null, new_regions: false,
    rationale: 'Hold while measured outcomes are reviewed.', recommended_product_investments: [],
  },
  retrospective_actions: [{
    title: 'Publish retrospective', priority: 'p2', status: 'completed',
    due_at: '2026-07-28T13:00:00Z', blocks_expansion: false,
    owner_reference: 'restricted/owners/success', evidence_reference: 'restricted/actions/publish',
  }],
}

function evidenceFieldsForTest() { return ['financial', 'provider', 'admission', 'support', 'cleanup', 'metrics', 'feedback', 'retrospective'] }
function reconciliationFieldsForTest() { return ['sales', 'discounts', 'taxes', 'fees', 'refunds', 'disputes', 'add_ons', 'door_sales', 'settlement', 'payout', 'scans', 'support_cases', 'message_exceptions', 'admission_exceptions', 'reconciliation_exceptions'] }
function cleanupFieldsForTest() { return ['temporary_staff_revoked', 'scanner_devices_revoked', 'device_local_data_purged', 'retention_policy_followed'] }

describe('PilotCloseoutDialog', () => {
  beforeEach(() => { apiClient.get.mockReset(); apiClient.post.mockReset() })

  it('fails closed until a completed Gate I run exists', async () => {
    apiClient.get.mockResolvedValue({ data: { event, pilot_closeout: { eligible: false, approved: false } } })
    render(<PilotCloseoutDialog event={event} />)

    fireEvent.click(screen.getByRole('button', { name: 'Prepare Gate J closeout' }))

    expect(await screen.findByText(/Complete and reconcile a real Gate I run/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Sign and submit/ })).not.toBeInTheDocument()
  })

  it('submits typed outcomes, full attestations, and a state-bound hold decision', async () => {
    apiClient.get.mockResolvedValue({ data: {
      event, pilot_closeout: { eligible: true, approved: false, local_metrics: localMetrics },
    } })
    apiClient.post.mockResolvedValue({ data: { id: 91, decision: 'submission' } })
    render(<PilotCloseoutDialog event={{ ...event, pilot_closeout: { eligible: true } }} />)

    fireEvent.click(screen.getByRole('button', { name: 'Prepare Gate J closeout' }))
    await screen.findByText('System-calculated closeout')
    fireEvent.change(screen.getByLabelText('Bundle reference'), { target: { value: 'restricted-closeout/gate-j' } })
    fireEvent.change(screen.getByLabelText('Bundle SHA-256'), { target: { value: 'a'.repeat(64) } })
    ;[
      'Financial reconciliation reference', 'Provider, settlement, payout, and bank reference',
      'Admission and device closeout reference', 'Support case closeout reference',
      'Staff/device cleanup reference', 'Metric exports reference',
      'Organizer and buyer feedback reference', 'Retrospective record reference',
    ].forEach((label, index) => fireEvent.change(screen.getByLabelText(label), {
      target: { value: `restricted-closeout/evidence-${index}` },
    }))
    fireEvent.change(screen.getByLabelText('Entry latency p95 (ms)'), { target: { value: '275' } })
    ;[
      'Sales reconciled', 'Discounts reconciled', 'Taxes reconciled', 'Fees reconciled',
      'Refunds reconciled', 'Disputes reconciled', 'Add-ons reconciled',
      'Cash/card door sales reconciled', 'Settlement reconciled', 'Payout and bank receipt reconciled',
      'Scans and no-shows reconciled', 'Support cases reconciled', 'Message exceptions reconciled',
      'Admission exceptions reconciled', 'Reconciliation exceptions reconciled',
      'Temporary staff access revoked or expired', 'Scanner devices revoked',
      'Device-local manifests, tokens, queues, and scan state purged under policy',
      'Server evidence retained under the approved policy or legal hold',
    ].forEach(label => fireEvent.click(screen.getByLabelText(label)))
    fireEvent.change(screen.getByLabelText('Action'), { target: { value: 'Publish the retrospective' } })
    fireEvent.change(screen.getByLabelText('Owner reference'), { target: { value: 'restricted-owners/engineering' } })
    fireEvent.change(screen.getByLabelText('Action evidence reference'), { target: { value: 'restricted-closeout/action-1' } })
    fireEvent.change(screen.getByLabelText('Rationale'), { target: { value: 'Hold while outcomes are reviewed.' } })
    fireEvent.click(screen.getByRole('button', { name: /Sign and submit Gate J closeout/ }))

    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/events/42/pilot_closeout_reviews',
      expect.objectContaining({
        expansion_decision: 'hold', outcome_metrics: expect.objectContaining({ entry_latency_p95_ms: 275 }),
        expansion_scope: expect.objectContaining({ event_limit: 0, new_regions: false }),
      })))
  })

  it('lets a second administrator approve the exact pending closeout', async () => {
    apiClient.get.mockResolvedValue({ data: {
      event, pilot_closeout: { eligible: true, approved: false, pending_submission: pending },
    } })
    apiClient.post.mockResolvedValue({ data: { id: 92, decision: 'approval' } })
    render(<PilotCloseoutDialog event={{ ...event, pilot_closeout: { pending_submission: { id: 91 } } }} />)

    fireEvent.click(screen.getByRole('button', { name: 'Review Gate J closeout' }))
    expect(await screen.findByText('Hold while measured outcomes are reviewed.')).toBeInTheDocument()
    expect(screen.getByText('restricted/evidence-0')).toBeInTheDocument()
    expect(screen.getAllByText(/Confirmed/)).toHaveLength(19)
    fireEvent.click(screen.getByRole('button', { name: 'Approve exact Gate J decision' }))

    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/pilot_closeout_reviews/91/approve'))
  })
})
