import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import SeatSelector from './SeatSelector'

vi.mock('../api/client', () => ({
  default: { get: vi.fn(), post: vi.fn() },
}))

const map = {
  suspended: false,
  hold_duration_seconds: 600,
  sections: [{
    id: 1,
    name: 'Main floor',
    rows: [{
      id: 2,
      label: 'A',
      seats: [
        { id: 10, label: '1', display_label: 'Main floor · Row A · Seat 1', price_cents: 2500,
          ticket_type_id: 7, ticket_type_name: 'Reserved', status: 'available', accessibility_kind: 'standard',
          requires_accessibility_attestation: false, obstructed_view: false },
        { id: 11, label: 'W1', display_label: 'Main floor · Row A · Seat W1', price_cents: 2500,
          ticket_type_id: 7, ticket_type_name: 'Reserved', status: 'available', accessibility_kind: 'wheelchair',
          requires_accessibility_attestation: true, obstructed_view: false },
      ],
    }],
  }],
}

describe('SeatSelector', () => {
  beforeEach(() => {
    apiClient.get.mockResolvedValue({ data: map })
    apiClient.post.mockResolvedValue({ data: { token: 'seat-token', expires_at: '2026-07-21T03:00:00Z' } })
  })

  it('reserves keyboard-selectable seats and returns grouped ticket lines', async () => {
    const onReserved = vi.fn()
    render(<SeatSelector event={{ slug: 'guam-show' }} onReserved={onReserved} />)

    const seat = await screen.findByRole('button', { name: /Main floor, row A, seat 1/ })
    fireEvent.click(seat)
    expect(seat).toHaveAttribute('aria-pressed', 'true')
    fireEvent.click(screen.getByRole('button', { name: 'Reserve selected seats' }))

    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/events/guam-show/seat_holds', {
      event_seat_ids: [10], accessibility_attested: false, source: 'online',
    }))
    expect(onReserved).toHaveBeenCalledWith(expect.objectContaining({
      lineItems: [{ ticket_type_id: 7, quantity: 1 }], seatHoldToken: 'seat-token',
    }))
  })

  it('requires an attestation without requesting disability documentation', async () => {
    render(<SeatSelector event={{ slug: 'guam-show' }} onReserved={vi.fn()} />)
    fireEvent.click(await screen.findByRole('button', { name: /seat W1/ }))

    const reserve = screen.getByRole('button', { name: 'Reserve selected seats' })
    expect(reserve).toBeDisabled()
    fireEvent.click(screen.getByLabelText(/I attest that an accessible seating location is needed/))
    expect(reserve).toBeEnabled()
    expect(screen.queryByText(/medical proof is required/i)).toBeInTheDocument()
  })
})
