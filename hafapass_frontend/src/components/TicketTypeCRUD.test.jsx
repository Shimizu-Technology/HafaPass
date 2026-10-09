import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import apiClient from '../api/client'
import TicketTypeCRUD from './TicketTypeCRUD'
import EditEventPage from '../pages/dashboard/EditEventPage'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn(), put: vi.fn() } }))
vi.mock('./PricingTiersCRUD', () => ({ default: () => null }))
vi.mock('./CoverImageUpload', () => ({ default: () => null }))
vi.mock('../hooks/useEventCategories', () => ({ default: () => [] }))
vi.mock('../hooks/useLaunchCapabilities', () => ({ default: () => ({}) }))

describe('organizer ticket setup', () => {
  beforeEach(() => { vi.clearAllMocks(); apiClient.post.mockResolvedValue({ data: {} }); apiClient.put.mockResolvedValue({ data: {} }) })

  it('refuses a missing positive quantity before contacting the API and focuses the field', async () => {
    render(<TicketTypeCRUD eventId={42} onRefresh={vi.fn()} />)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Add Ticket Type' }))
    await user.type(screen.getByRole('textbox', { name: 'Name', exact: true }), 'General Admission')
    await user.click(screen.getByRole('button', { name: 'Add Ticket Type' }))
    expect(screen.getByRole('alert')).toHaveTextContent('Enter a positive whole number of tickets available.')
    expect(screen.getByRole('spinbutton', { name: 'Tickets available', exact: true })).toHaveFocus()
    expect(apiClient.post).not.toHaveBeenCalled()
  })

  it('defaults to remaining event capacity and submits a free ticket with truthful blank optional limits', async () => {
    apiClient.get.mockResolvedValue({ data: {
      id: 42, slug: 'community-night', status: 'draft', title: 'Community Night', timezone: 'Pacific/Guam', max_capacity: 30,
      ticket_types: [{ id: 7, name: 'Existing tickets', price_cents: 0, quantity_available: 12, quantity_sold: 2 }],
    } })
    render(<MemoryRouter initialEntries={['/dashboard/events/42/edit']}><Routes><Route path="/dashboard/events/:id/edit" element={<EditEventPage />} /></Routes></MemoryRouter>)
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Add Ticket Type' }))
    expect(screen.getByRole('spinbutton', { name: 'Tickets available', exact: true })).toHaveValue(18)
    expect(screen.getByRole('spinbutton', { name: 'Price ($)', exact: true })).toHaveValue(0)
    expect(screen.getByText('More ticket options').closest('details')).not.toHaveAttribute('open')
    await user.type(screen.getByRole('textbox', { name: 'Name', exact: true }), 'General Admission')
    await user.click(screen.getByRole('button', { name: 'Add Ticket Type' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/42/ticket_types', {
      name: 'General Admission', description: null, price_cents: 0, quantity_available: 18,
      door_allocation: null, max_per_order: null, max_per_buyer: null, sales_start_at: null, sales_end_at: null,
    }))
  })

  it('retains the configured quantity and optional limits when editing an existing type', async () => {
    render(<TicketTypeCRUD eventId={42} remainingCapacity={5} onRefresh={vi.fn()} ticketTypes={[{
      id: 7, name: 'Early admission', description: 'Existing terms', price_cents: 3995, quantity_available: 25,
      quantity_sold: 10, door_allocation: 0, max_per_order: 3, max_per_buyer: 6,
      sales_start_at: '2026-10-20T08:00:00Z', sales_end_at: '2026-10-21T08:00:00Z',
    }]} />)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Edit Early admission' }))
    expect(screen.getByRole('spinbutton', { name: 'Tickets available', exact: true })).toHaveValue(25)
    await user.click(screen.getByText('More ticket options'))
    expect(screen.getByText('More ticket options').closest('details')).toHaveAttribute('open')
    expect(screen.getByLabelText('Tickets per order')).toHaveValue(3)
    await user.click(screen.getByRole('button', { name: 'Update' }))
    await waitFor(() => expect(apiClient.put).toHaveBeenCalledWith('/organizer/events/42/ticket_types/7', {
      name: 'Early admission', description: 'Existing terms', price_cents: 3995, quantity_available: 25,
      door_allocation: 0, max_per_order: 3, max_per_buyer: 6,
      sales_start_at: '2026-10-20T18:00', sales_end_at: '2026-10-21T18:00',
    }))
  })
})
