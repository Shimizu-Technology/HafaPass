import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import LiveMoneyProofReviewDialog from './LiveMoneyProofReviewDialog'
import apiClient from '../api/client'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))

const event = { id: 42, slug: 'live-proof', title: '[LIVE MONEY TEST] Proof', live_money_proof_candidate: true,
  live_money_proof: { approval_recorded: false } }

describe('LiveMoneyProofReviewDialog', () => {
  beforeEach(() => vi.clearAllMocks())

  it('explains that an ordinary event cannot bypass Gate H', async () => {
    apiClient.get.mockResolvedValue({ data: { event: { ...event, live_money_proof_candidate: false },
      authorization: null, live_money_proof: { approved: false } } })
    render(<LiveMoneyProofReviewDialog event={{ ...event, live_money_proof_candidate: false }} />)

    fireEvent.click(screen.getByRole('button', { name: 'Prepare Gate H live-money proof' }))

    expect(await screen.findByText(/Normal events cannot be used to bypass Gate H/)).toBeInTheDocument()
  })

  it('lets a different administrator approve a one-time authorization', async () => {
    const details = { event, authorization: { id: 71, requested_by_user_id: 9, approved_at: null,
      order_id: null, max_amount_cents: 500, expires_at: new Date(Date.now() + 3600000).toISOString() },
    live_money_proof: { approved: false } }
    apiClient.get.mockResolvedValue({ data: details })
    apiClient.post.mockResolvedValue({ data: { ...details.authorization, approved_at: new Date().toISOString() } })
    render(<LiveMoneyProofReviewDialog event={event} />)

    fireEvent.click(screen.getByRole('button', { name: 'Prepare Gate H live-money proof' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Approve one-time proof' }))

    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/live_money_proof_authorizations/71/approve'))
  })

  it('shows the private proof checkout only after approval', async () => {
    apiClient.get.mockResolvedValue({ data: { event, authorization: { id: 72, requested_by_user_id: 9,
      approved_at: new Date().toISOString(), order_id: null, max_amount_cents: 500,
      expires_at: new Date(Date.now() + 3600000).toISOString() }, live_money_proof: { approved: false } } })
    render(<LiveMoneyProofReviewDialog event={event} />)

    fireEvent.click(screen.getByRole('button', { name: 'Prepare Gate H live-money proof' }))

    const link = await screen.findByRole('link', { name: 'Open private proof checkout' })
    expect(link).toHaveAttribute('href', '/events/live-proof?live_money_proof=true')
  })
})
