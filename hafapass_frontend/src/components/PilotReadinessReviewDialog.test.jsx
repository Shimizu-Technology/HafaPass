import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import PilotReadinessReviewDialog from './PilotReadinessReviewDialog'

vi.mock('../api/client', () => ({
  default: { get: vi.fn(), post: vi.fn() },
}))

const event = { id: 42, title: 'Guam Community Night', pilot_readiness: { approved: false } }

const assignments = {
  primary_on_call: { name: 'Primary Owner', contact_reference: 'directory/primary' },
  backup_on_call: { name: 'Backup Owner', contact_reference: 'directory/backup' },
  event_commander: { name: 'Event Commander', contact_reference: 'directory/commander' },
  door_lead: { name: 'Door Lead', contact_reference: 'directory/door' },
  finance_contact: { name: 'Finance Lead', contact_reference: 'directory/finance' },
  venue_safety_contact: { name: 'Venue Safety', contact_reference: 'directory/safety' },
}

const assignmentLabels = {
  primary_on_call: 'Primary on-call',
  backup_on_call: 'Backup on-call',
  event_commander: 'Event commander',
  door_lead: 'Door lead',
  finance_contact: 'Finance contact',
  venue_safety_contact: 'Venue safety contact',
}

const controls = {
  low_risk_scope: true,
  organizer_identity_and_agreement: true,
  payout_method: true,
  event_content_and_prohibited_review: true,
  venue_schedule_capacity_inventory: true,
  pricing_fees_and_refund_policy: true,
  seating_physically_reconciled_or_not_applicable: true,
  support_channels_and_sla: true,
  cash_controls_and_staffing: true,
  scanners_spares_and_connectivity: true,
  emergency_door_list_restricted: true,
  no_open_p0_or_p1: true,
}

describe('PilotReadinessReviewDialog', () => {
  beforeEach(() => {
    apiClient.get.mockReset().mockResolvedValue({ data: { event, pilot_readiness: { approved: false } } })
    apiClient.post.mockReset().mockResolvedValue({ data: {} })
  })

  it('requires named owners and every Gate E control before submission', async () => {
    const user = userEvent.setup()
    render(<PilotReadinessReviewDialog event={event} onComplete={vi.fn()} />)

    await user.click(screen.getByRole('button', { name: 'Prepare pilot readiness' }))
    await screen.findByRole('button', { name: 'Submit readiness' })
    const submit = screen.getByRole('button', { name: 'Submit readiness' })
    expect(submit).toBeDisabled()

    fireEvent.change(screen.getByLabelText('Restricted evidence reference'), { target: { value: 'private/pilot/42' } })
    fireEvent.change(screen.getByLabelText(/^Evidence SHA-256/), { target: { value: 'a'.repeat(64) } })
    for (const [role, values] of Object.entries(assignments)) {
      const label = assignmentLabels[role]
      fireEvent.change(screen.getByLabelText(`${label} name`), { target: { value: values.name } })
      fireEvent.change(screen.getByLabelText(`${label} private contact reference`), { target: { value: values.contact_reference } })
    }
    for (const checkbox of screen.getAllByRole('checkbox')) await user.click(checkbox)

    expect(submit).toBeEnabled()
    await user.click(submit)

    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith(
      '/admin/events/42/pilot_readiness_reviews',
      expect.objectContaining({ evidence_digest: 'a'.repeat(64), controls, assignments }),
    ))
  })

  it('shows a pending immutable snapshot and uses POST for independent approval', async () => {
    const pending = {
      id: 91,
      actor_user_id: 7,
      evidence_reference: 'private/pilot/42',
      evidence_digest: 'b'.repeat(64),
      event_state_digest: 'c'.repeat(64),
      application_revision: 'pilot-candidate-a',
      assignments,
      controls,
      effective_at: '2026-07-21T00:00:00Z',
      expires_at: '2026-09-21T00:00:00Z',
    }
    apiClient.get.mockResolvedValue({
      data: { event, pilot_readiness: { approved: false, pending_submission: pending } },
    })
    const user = userEvent.setup()
    render(<PilotReadinessReviewDialog event={{ ...event, pilot_readiness: { pending_submission: pending } }} onComplete={vi.fn()} />)

    await user.click(screen.getByRole('button', { name: 'Review readiness' }))
    expect(await screen.findByText(/Admin #7 submitted this exact event snapshot/)).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Approve exact snapshot' }))

    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/pilot_readiness_reviews/91/approve'))
  })
})
