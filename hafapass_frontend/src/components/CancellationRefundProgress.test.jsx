import { beforeEach, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import apiClient from '../api/client'
import CancellationRefundProgress from './CancellationRefundProgress'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))

beforeEach(() => {
  vi.clearAllMocks()
  apiClient.get.mockResolvedValue({ data: { preview: { count: 2, total_cents: 431250, cash_count: 1 }, run: null } })
})

it('shows the exact fee-inclusive amount before cancellation and sends the reviewed snapshot', async () => {
  const user = userEvent.setup()
  apiClient.post.mockResolvedValue({ data: {} })
  render(<CancellationRefundProgress eventId={7} status="published" />)
  await user.click(screen.getByRole('button', { name: 'Review cancellation and refunds' }))
  await screen.findByText('2 orders · $4,312.50 including service fees.')
  await user.click(screen.getByRole('button', { name: 'Cancel event and refund all buyers' }))
  expect(await screen.findByText('Refund 2 orders, $4,312.50 including service fees.')).toBeInTheDocument()
  await user.type(screen.getByLabelText('Reason for cancellation'), 'Storm')
  await user.click(screen.getByRole('button', { name: 'Confirm cancellation and refunds' }))
  expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/7/cancel', {
    reason: 'Storm', refund_count: 2, refund_total_cents: 431250,
  })
})

it('shows progress and offers retry for failed refunds', async () => {
  const user = userEvent.setup()
  apiClient.get.mockResolvedValue({ data: { preview: { count: 1, total_cents: 5250, cash_count: 0 },
    run: { status: 'needs_attention', refunded: 0, pending: 0, failed: 1, needs_manual: 0, skipped: 0, items: [{ id: 1, order_id: 4, order_reference: 'HP-1', amount_cents: 5250, status: 'failed', error: 'Provider rejected' }] } } })
  apiClient.post.mockResolvedValue({ data: {} })
  render(<CancellationRefundProgress eventId={7} status="cancelled" />)
  await user.click(screen.getByRole('button', { name: 'View cancellation refunds' }))
  expect(await screen.findByText(/1 failed/)).toBeInTheDocument()
  await user.click(screen.getByRole('button', { name: 'Retry failed' }))
  expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/7/retry_cancellation_refunds', {})
})

it('explains cash-return permissions to an organizer manager', async () => {
  const user = userEvent.setup()
  apiClient.get.mockResolvedValue({ data: { preview: { count: 1, total_cents: 5250, cash_count: 1 },
    run: { status: 'needs_attention', refunded: 0, pending: 0, failed: 0, needs_manual: 1, skipped: 0,
      items: [{ id: 2, order_id: 5, order_reference: 'HP-CASH', amount_cents: 5250,
        status: 'needs_manual', error: null }] } } })
  render(<CancellationRefundProgress eventId={7} status="cancelled" />)

  await user.click(screen.getByRole('button', { name: 'View cancellation refunds' }))
  expect(await screen.findByText('Ask an owner or finance teammate to record the cash return.')).toBeInTheDocument()
  expect(screen.queryByRole('button', { name: 'Mark refunded in cash' })).not.toBeInTheDocument()
})

it('offers a retry when the first progress load fails', async () => {
  const user = userEvent.setup()
  apiClient.get.mockRejectedValueOnce(new Error('network down')).mockResolvedValueOnce({
    data: { preview: { count: 0, total_cents: 0, cash_count: 0 }, run: null },
  })
  render(<CancellationRefundProgress eventId={7} status="published" />)
  await user.click(screen.getByRole('button', { name: 'Review cancellation and refunds' }))
  expect(await screen.findByRole('alert')).toHaveTextContent('Refund progress could not be loaded')
  expect(screen.queryByText('Loading refund details…')).not.toBeInTheDocument()
  await user.click(screen.getByRole('button', { name: 'Retry loading refund details' }))
  expect(await screen.findByText('0 orders · $0.00 including service fees.')).toBeInTheDocument()
})

it('explains the refund-authority requirement to managers', async () => {
  const user = userEvent.setup()
  render(<CancellationRefundProgress eventId={7} status="published" canRefund={false} />)
  await user.click(screen.getByRole('button', { name: 'Review cancellation and refunds' }))
  expect(await screen.findByText(/Ask an owner to cancel/)).toBeInTheDocument()
  expect(screen.queryByRole('button', { name: 'Cancel event and refund all buyers' })).not.toBeInTheDocument()
})
