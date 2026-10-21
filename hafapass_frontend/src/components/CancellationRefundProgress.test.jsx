import { beforeEach, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import apiClient from '../api/client'
import CancellationRefundProgress from './CancellationRefundProgress'
import { toEventLocalInput } from '../utils/eventTime'

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
  expect(screen.getByText('1 cash order will need a manual return and record.')).toBeInTheDocument()
  await user.click(screen.getByRole('button', { name: 'Cancel event and refund all buyers' }))
  expect(await screen.findByText('Refund 2 orders, $4,312.50 including service fees.')).toBeInTheDocument()
  await user.type(screen.getByLabelText('Reason for cancellation'), 'Storm')
  await user.click(screen.getByRole('button', { name: 'Confirm cancellation and refunds' }))
  expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/7/cancel', {
    reason: 'Storm', refund_count: 2, refund_total_cents: 431250,
  })
})

it('refreshes the reviewed totals after a stale confirmation conflict', async () => {
  const user = userEvent.setup()
  apiClient.post.mockRejectedValueOnce({ response: { status: 409, data: {
    error: 'Refund total changed.', preview: { count: 3, total_cents: 501000, cash_count: 1 },
  } } }).mockResolvedValueOnce({ data: {} })
  render(<CancellationRefundProgress eventId={7} status="published" />)
  await user.click(screen.getByRole('button', { name: 'Review cancellation and refunds' }))
  await screen.findByText('2 orders · $4,312.50 including service fees.')
  await user.click(screen.getByRole('button', { name: 'Cancel event and refund all buyers' }))
  await user.type(screen.getByLabelText('Reason for cancellation'), 'Storm')
  await user.click(screen.getByRole('button', { name: 'Confirm cancellation and refunds' }))
  expect(await screen.findByRole('alert')).toHaveTextContent('Refund total changed.')
  expect(screen.getByText('Refund 3 orders, $5,010.00 including service fees.')).toBeInTheDocument()
  await user.click(screen.getByRole('button', { name: 'Confirm cancellation and refunds' }))
  expect(apiClient.post).toHaveBeenLastCalledWith('/organizer/events/7/cancel', {
    reason: 'Storm', refund_count: 3, refund_total_cents: 501000,
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

it('offers an admin a way to start refunds on a legacy cancelled event', async () => {
  const user = userEvent.setup()
  apiClient.get.mockResolvedValue({ data: { preview: { count: 1, total_cents: 4250, cash_count: 0 }, run: null } })
  apiClient.post.mockResolvedValue({ data: {} })
  render(<CancellationRefundProgress eventId={7} status="cancelled" admin />)
  await user.click(screen.getByRole('button', { name: 'View cancellation refunds' }))
  expect(await screen.findByText('1 order · $42.50 still to resolve.')).toBeInTheDocument()
  await user.click(screen.getByRole('button', { name: 'Start refunds for this cancelled event' }))
  expect(screen.getByText(/Review 1 order and \$42\.50 still to resolve/)).toBeInTheDocument()
  await user.click(screen.getByRole('button', { name: 'Confirm and start refunds' }))
  expect(apiClient.post).toHaveBeenCalledWith('/admin/events/7/start_cancellation_refunds', {
    refund_count: 1, refund_total_cents: 4250,
  })
})

it('labels a refreshed cash amount as the amount remaining to return', async () => {
  const user = userEvent.setup()
  apiClient.get.mockResolvedValue({ data: { preview: { count: 1, total_cents: 4250, cash_count: 1 },
    run: { status: 'needs_attention', refunded: 0, pending: 0, failed: 0, needs_manual: 1, skipped: 0,
      items: [{ id: 2, order_id: 5, order_reference: 'HP-CASH', amount_cents: 4250,
        status: 'needs_manual', error: null }] } } })
  render(<CancellationRefundProgress eventId={7} status="cancelled" canMarkCash />)
  await user.click(screen.getByRole('button', { name: 'View cancellation refunds' }))
  expect(await screen.findByText(/\$42\.50 remaining to return/)).toBeInTheDocument()
})

it('shows only nonzero human-readable counts and the amount refunded to card', async () => {
  const user = userEvent.setup()
  apiClient.get.mockResolvedValue({ data: { preview: { count: 0, total_cents: 0, cash_count: 0 },
    run: { status: 'completed', total_orders: 2, refunded: 1, pending: 0, failed: 0, needs_manual: 1, skipped: 0,
      items: [{ id: 1, order_id: 4, order_reference: 'HP-CARD', amount_cents: 3775, status: 'refunded', payment_method: 'stripe' },
        { id: 2, order_id: 5, order_reference: 'HP-CASH', amount_cents: 4250, status: 'needs_manual', payment_method: 'door_cash' }] } } })
  render(<CancellationRefundProgress eventId={7} status="cancelled" canMarkCash />)
  await user.click(screen.getByRole('button', { name: 'View cancellation refunds' }))
  expect(await screen.findByText('1 refunded · 1 Needs cash return')).toBeInTheDocument()
  expect(screen.getByText('$37.75 refunded to card')).toBeInTheDocument()
  expect(screen.getByRole('button', { name: 'Mark refunded in cash' })).toHaveClass('btn-secondary')
})

it('loads the next page of order details without loading every refund row', async () => {
  const user = userEvent.setup()
  apiClient.get.mockImplementation((_path, config) => Promise.resolve({ data: {
    preview: { count: 51, total_cents: 5100, cash_count: 0 },
    run: { status: 'completed', total_orders: 51, item_page: config.params.page, item_total_pages: 2,
      refunded: 51, pending: 0, failed: 0, needs_manual: 0, skipped: 0,
      items: [{ id: config.params.page, order_id: config.params.page, order_reference: `HP-${config.params.page}`,
        amount_cents: 100, status: 'refunded', payment_method: 'stripe' }] },
  } }))
  render(<CancellationRefundProgress eventId={7} status="cancelled" />)
  await user.click(screen.getByRole('button', { name: 'View cancellation refunds' }))
  expect(await screen.findByText('HP-1')).toBeInTheDocument()
  await user.click(screen.getByRole('button', { name: 'Next orders' }))
  expect(await screen.findByText('HP-2')).toBeInTheDocument()
  expect(apiClient.get).toHaveBeenCalledWith('/organizer/events/7/cancellation_refunds', { params: { page: 2 } })
})

it('defaults the cash time in the event zone, validates sale bounds, and shows server errors inline', async () => {
  const user = userEvent.setup()
  const sale = new Date(Date.now() - 60 * 60 * 1000)
  const item = { id: 2, order_id: 5, order_reference: 'HP-CASH', amount_cents: 4250,
    status: 'needs_manual', payment_method: 'door_cash', order_created_at: sale.toISOString() }
  apiClient.get.mockResolvedValue({ data: { preview: { count: 1, total_cents: 4250, cash_count: 1 },
    run: { status: 'needs_attention', total_orders: 1, refunded: 0, pending: 0, failed: 0, needs_manual: 1, skipped: 0, items: [item] } } })
  apiClient.post.mockRejectedValue({ response: { status: 422, data: { error: 'Cash return amount changed' } } })
  render(<CancellationRefundProgress eventId={7} status="cancelled" canMarkCash eventTimeZone="Pacific/Guam" />)
  await user.click(screen.getByRole('button', { name: 'View cancellation refunds' }))
  await user.click(await screen.findByRole('button', { name: 'Mark refunded in cash' }))
  const dialog = within(screen.getByRole('dialog'))
  const field = dialog.getByLabelText('Returned at (Pacific/Guam)')
  expect(field).toBeRequired()
  expect(field).toHaveValue(toEventLocalInput(new Date(), 'Pacific/Guam'))
  await user.type(dialog.getByLabelText('Cash return reference'), 'receipt-42')
  fireEvent.change(field, { target: { value: toEventLocalInput(new Date(sale.getTime() - 60 * 60 * 1000), 'Pacific/Guam') } })
  await user.click(dialog.getByRole('button', { name: 'Mark refunded in cash' }))
  expect(dialog.getByRole('alert')).toHaveTextContent(/Use a time after the sale/)
  expect(apiClient.post).not.toHaveBeenCalled()
  fireEvent.change(field, { target: { value: toEventLocalInput(new Date(Date.now() + 60 * 60 * 1000), 'Pacific/Guam') } })
  await user.click(dialog.getByRole('button', { name: 'Mark refunded in cash' }))
  expect(dialog.getByRole('alert')).toHaveTextContent(/not in the future/)
  fireEvent.change(field, { target: { value: toEventLocalInput(new Date(), 'Pacific/Guam') } })
  await user.click(dialog.getByRole('button', { name: 'Mark refunded in cash' }))
  expect(await dialog.findByRole('alert')).toHaveTextContent('Cash return amount changed')
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
