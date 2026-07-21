import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import LivePilotOperationsDialog from './LivePilotOperationsDialog'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))

const event = {
  id: 42, title: 'Guam Community Night', status: 'published',
  starts_at: new Date(Date.now() + 86_400_000).toISOString(),
  ends_at: new Date(Date.now() + 90_000_000).toISOString(), live_pilot: {},
}
const pending = {
  id: 81, actor_user_id: 7, inventory_cap: 50, event_day_rehearsal_review_id: 51,
  live_money_proof_review_id: 61, evidence_reference: 'restricted-pilot/42',
  evidence_digest: 'a'.repeat(64), effective_at: new Date().toISOString(),
  expires_at: new Date(Date.now() + 86_400_000).toISOString(),
}

describe('LivePilotOperationsDialog', () => {
  beforeEach(() => { apiClient.get.mockReset(); apiClient.post.mockReset() })

  it('fails closed in the UI when Gate G or applicable Gate H is not current', async () => {
    apiClient.get.mockResolvedValue({ data: {
      event, live_pilot: { prerequisite_ready: false, approved: false, maximum_inventory_cap: 250 },
    } })
    render(<LivePilotOperationsDialog event={event} />)

    fireEvent.click(screen.getByRole('button', { name: 'Prepare Gate I bounded pilot' }))

    expect(await screen.findByText(/exact current Gate G rehearsal/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Submit Gate I plan' })).toBeDisabled()
  })

  it('lets a second administrator approve the exact pending plan', async () => {
    apiClient.get.mockResolvedValue({ data: {
      event, live_pilot: { prerequisite_ready: true, approved: false, pending_submission: pending },
    } })
    apiClient.post.mockResolvedValue({ data: { id: 82, decision: 'approval' } })
    render(<LivePilotOperationsDialog event={{ ...event, live_pilot: { pending_submission: { id: 81 } } }} />)

    fireEvent.click(screen.getByRole('button', { name: 'Review Gate I pilot plan' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Approve exact Gate I plan' }))

    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/live_pilot_reviews/81/approve'))
  })

  it('starts an approved bounded pilot', async () => {
    apiClient.get.mockResolvedValue({ data: {
      event, live_pilot: { prerequisite_ready: true, approved: true, latest_approval: { ...pending, id: 82 } },
    } })
    apiClient.post.mockResolvedValue({ data: { id: 91, status: 'active' } })
    render(<LivePilotOperationsDialog event={{ ...event, live_pilot: { approval_recorded: true } }} />)

    fireEvent.click(screen.getByRole('button', { name: 'Operate Gate I bounded pilot' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Start bounded pilot' }))

    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/live_pilot_reviews/82/start'))
  })

  it('records a complete monitoring checkpoint with numeric measurements', async () => {
    const run = {
      id: 91, status: 'active', inventory_cap: 50, committed_ticket_quantity: 3, incidents: [],
      latest_metric_snapshot: null,
    }
    apiClient.get.mockResolvedValue({ data: { event, live_pilot: { latest_run: run } } })
    apiClient.post.mockResolvedValue({ data: { id: 100 } })
    render(<LivePilotOperationsDialog event={{ ...event, live_pilot: { run_status: 'active' } }} />)

    fireEvent.click(screen.getByRole('button', { name: 'Gate I pilot · active' }))
    fireEvent.change(await screen.findByLabelText('Checkpoint evidence reference'), { target: { value: 'restricted-checkpoint/91' } })
    fireEvent.change(screen.getAllByLabelText('Evidence SHA-256')[0], { target: { value: 'b'.repeat(64) } })
    fireEvent.change(screen.getByLabelText('Provider status reference'), { target: { value: 'provider/status/91' } })
    fireEvent.change(screen.getByLabelText('Checkout p95 (ms)'), { target: { value: '450' } })
    fireEvent.click(screen.getByRole('button', { name: 'Record checkpoint' }))

    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/live_pilot_runs/91/checkpoint',
      expect.objectContaining({ external_metrics: expect.objectContaining({ checkout_p95_ms: 450 }) })))
  })
})
