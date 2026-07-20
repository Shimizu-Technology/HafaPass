import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import AdminOrdersPage from './AdminOrdersPage'

vi.mock('../../api/client', () => ({
  default: { get: vi.fn() },
}))

vi.mock('./AdminLayout', () => ({
  default: ({ children }) => <div>{children}</div>,
}))

describe('AdminOrdersPage', () => {
  beforeEach(() => {
    apiClient.get.mockResolvedValue({
      data: {
        meta: { page: 1, total_pages: 1 },
        orders: [{
          id: 42,
          buyer_name: 'Ledger Buyer',
          buyer_email: 'buyer@example.com',
          event_title: 'Guam Night Market',
          status: 'partially_refunded',
          created_at: '2026-07-20T00:00:00Z',
          subtotal_cents: 5000,
          discount_cents: 500,
          fee_cents: 200,
          refund_cents: 1000,
          net_cents: 3700,
          organizer_proceeds_cents: 3500,
          order_items: [{
            id: 1,
            name: 'General Admission',
            tier_name: 'Early Bird',
            quantity: 2,
            unit_price_cents: 2500,
            subtotal_cents: 5000,
            fee_cents: 200,
            discount_cents: 500,
          }],
          payments: [{ id: 1, provider_payment_id: 'pi_test', status: 'partially_refunded', amount_cents: 4700 }],
          refunds: [{ id: 1, provider_refund_id: 're_test', status: 'succeeded', amount_cents: 1000 }],
          reconciliation_exceptions: [{ id: 1, code: 'payment_amount_mismatch', status: 'open' }],
          tickets: [],
        }],
      },
    })
  })

  it('shows the operational ledger when an order is expanded', async () => {
    render(<AdminOrdersPage />)
    await screen.findByText('Ledger Buyer')

    fireEvent.click(screen.getByText('Ledger Buyer'))

    expect(screen.getByText('Financial ledger')).toBeInTheDocument()
    expect(screen.getByText('Immutable order items')).toBeInTheDocument()
    expect(screen.getByText(/General Admission/)).toBeInTheDocument()
    expect(screen.getByText(/pi_test/)).toBeInTheDocument()
    expect(screen.getByText(/payment amount mismatch/)).toBeInTheDocument()
    await waitFor(() => expect(apiClient.get).toHaveBeenCalledWith('/admin/orders', { params: { page: 1, per_page: 20 } }))
  })
})
