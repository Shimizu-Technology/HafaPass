import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import PilotValidationReviewDialog from './PilotValidationReviewDialog'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))

const event = { id: 42, title: 'Guam Community Night', pilot_validation: { approval_recorded: false } }

const pending = {
  id: 81,
  actor_user_id: 7,
  evidence_reference: 'private-qa/gate-f/42',
  evidence_digest: 'b'.repeat(64),
  application_revision: 'candidate-42',
  pilot_readiness_review_id: 51,
  device_matrix: {},
  load_results: { executed_concurrent_buyers: 60, request_count: 1000, p95_latency_ms: 650, observed_error_rate_percent: 0.2, oversell_count: 0 },
  controls: {},
  effective_at: new Date().toISOString(),
  expires_at: new Date(Date.now() + 86_400_000).toISOString(),
}

describe('PilotValidationReviewDialog', () => {
  beforeEach(() => {
    apiClient.get.mockReset()
    apiClient.post.mockReset().mockResolvedValue({ data: {} })
  })

  it('explains and enforces the Gate E prerequisite', async () => {
    apiClient.get.mockResolvedValue({ data: { event, pilot_validation: { prerequisite_ready: false, approved: false } } })

    render(<PilotValidationReviewDialog event={event} />)
    fireEvent.click(screen.getByRole('button', { name: 'Prepare Gate F evidence' }))

    expect(await screen.findByText(/Gate E must have a current approval/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Submit Gate F evidence' })).toBeDisabled()
  })

  it('records an independent approval for pending evidence', async () => {
    apiClient.get.mockResolvedValue({ data: {
      event,
      pilot_validation: { prerequisite_ready: true, approved: false, pending_submission: pending },
    } })

    render(<PilotValidationReviewDialog event={{ ...event, pilot_validation: { pending_submission: { id: 81 } } }} />)
    fireEvent.click(screen.getByRole('button', { name: 'Review QA evidence' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Approve exact candidate' }))

    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/pilot_validation_reviews/81/approve'))
  })
})
