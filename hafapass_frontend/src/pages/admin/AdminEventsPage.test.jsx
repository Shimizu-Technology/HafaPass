import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { MemoryRouter } from 'react-router-dom'
import apiClient from '../../api/client'
import AdminEventsPage from './AdminEventsPage'

vi.mock('../../api/client', () => ({
  default: { get: vi.fn(), patch: vi.fn() },
}))

vi.mock('./AdminLayout', () => ({
  default: ({ children }) => <div>{children}</div>,
}))

vi.mock('../../components/PilotReadinessReviewDialog', () => ({ default: () => null }))
vi.mock('../../components/PilotValidationReviewDialog', () => ({ default: () => null }))
vi.mock('../../components/EventDayRehearsalReviewDialog', () => ({ default: () => null }))
vi.mock('../../components/LiveMoneyProofReviewDialog', () => ({ default: () => null }))
vi.mock('../../components/LivePilotOperationsDialog', () => ({ default: () => null }))

const proofEvent = {
  id: 42,
  slug: 'live-proof',
  title: '[LIVE MONEY TEST] Proof',
  organizer_name: 'HafaPass Finance',
  status: 'draft',
  category: 'other',
  tickets_sold: 0,
  revenue_cents: 0,
  is_featured: false,
  live_money_proof_candidate: false,
}

describe('AdminEventsPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.get.mockResolvedValue({ data: { events: [proofEvent], meta: { page: 1, total_pages: 1 } } })
  })

  it('shows the server rejection when the proof-candidate flag cannot change', async () => {
    apiClient.patch.mockRejectedValue({ response: { data: { errors: ['Candidate cannot change after orders exist.'] } } })
    render(<MemoryRouter><AdminEventsPage /></MemoryRouter>)

    fireEvent.click(await screen.findByRole('button', { name: 'Mark as hidden proof candidate' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('Candidate cannot change after orders exist.')
    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/events/42', {
      live_money_proof_candidate: true,
    }))
  })
})
