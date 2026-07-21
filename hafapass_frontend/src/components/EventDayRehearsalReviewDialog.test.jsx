import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import EventDayRehearsalReviewDialog from './EventDayRehearsalReviewDialog'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))

const event = { id: 42, title: 'Guam Community Night', event_day_rehearsal: { approval_recorded: false } }
const pending = {
  id: 81, actor_user_id: 7, pilot_validation_review_id: 51, evidence_reference: 'private-rehearsal/42',
  evidence_digest: 'c'.repeat(64), application_revision: 'candidate-sha', effective_at: new Date().toISOString(),
  expires_at: new Date(Date.now() + 86_400_000).toISOString(), manifest_results: { ticket_count: 500 },
  device_results: [{}, {}, {}], reconciliation_results: { pending_queue_count: 0 },
  controls: Object.fromEntries([
    'stable_signing_key_confirmed', 'emergency_list_handling_confirmed', 'spare_devices_and_batteries_confirmed',
    'venue_network_fallback_confirmed', 'cash_control_approved', 'card_present_policy_approved',
    'alerts_acknowledged', 'rehearsal_log_complete', 'all_findings_resolved', 'no_open_p0_or_p1',
    'explicit_go_decision',
  ].map(key => [key, true])),
}

describe('EventDayRehearsalReviewDialog', () => {
  beforeEach(() => { apiClient.get.mockReset(); apiClient.post.mockReset() })

  it('explains the Gate F prerequisite and disables submission', async () => {
    apiClient.get.mockResolvedValue({ data: { event, event_day_rehearsal: { prerequisite_ready: false, approved: false } } })
    render(<EventDayRehearsalReviewDialog event={event} />)

    fireEvent.click(screen.getByRole('button', { name: 'Prepare Gate G rehearsal' }))

    expect(await screen.findByText(/Gate F must have a current approval/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Submit Gate G rehearsal' })).toBeDisabled()
  })

  it('lets an independent admin approve the exact pending rehearsal', async () => {
    apiClient.get.mockResolvedValue({ data: {
      event, event_day_rehearsal: { prerequisite_ready: true, approved: false, pending_submission: pending },
    } })
    apiClient.post.mockResolvedValue({ data: { id: 82, decision: 'approval' } })
    render(<EventDayRehearsalReviewDialog event={{ ...event, event_day_rehearsal: { pending_submission: { id: 81 } } }} />)

    fireEvent.click(screen.getByRole('button', { name: 'Review rehearsal evidence' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Approve exact rehearsal' }))

    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/event_day_rehearsal_reviews/81/approve'))
  })
})
