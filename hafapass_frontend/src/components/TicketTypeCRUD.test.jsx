import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import apiClient from '../api/client'
import TicketTypeCRUD from './TicketTypeCRUD'
import EditEventPage from '../pages/dashboard/EditEventPage'

vi.mock('../api/client', async importOriginal => ({
  ...await importOriginal(),
  default: { get: vi.fn(), post: vi.fn(), put: vi.fn() },
}))
vi.mock('./PricingTiersCRUD', () => ({ default: () => null }))
vi.mock('./CoverImageUpload', () => ({ default: () => null }))
vi.mock('../hooks/useEventCategories', () => ({ default: () => [] }))
vi.mock('../hooks/useLaunchCapabilities', () => ({ default: () => ({}), useLaunchCapabilityState: () => ({ capabilities: ({}), status: 'ready', retry: () => {} }) }))

describe('organizer ticket setup', () => {
  beforeEach(() => { vi.clearAllMocks(); apiClient.post.mockResolvedValue({ data: {} }); apiClient.put.mockResolvedValue({ data: {} }) })

  it('refuses a missing positive quantity before contacting the API and focuses the field', async () => {
    render(<MemoryRouter><TicketTypeCRUD eventId={42} onRefresh={vi.fn()} /></MemoryRouter>)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Add ticket type' }))
    await user.type(screen.getByRole('textbox', { name: 'Name', exact: true }), 'General Admission')
    await user.click(screen.getByRole('button', { name: 'Add ticket type' }))
    expect(screen.getByRole('alert')).toHaveTextContent('Enter a positive whole number of tickets available.')
    expect(screen.getByRole('spinbutton', { name: 'Tickets available', exact: true })).toHaveFocus()
    expect(apiClient.post).not.toHaveBeenCalled()
  })

  it('defaults to remaining event capacity and submits a free ticket with truthful blank optional limits', async () => {
    apiClient.get.mockResolvedValue({ data: {
      permissions: { edit_event_content: true, manage_events: true, manage_inventory: true },
      id: 42, slug: 'community-night', status: 'draft', title: 'Community Night', timezone: 'Pacific/Guam', max_capacity: 30,
      ticket_types: [{ id: 7, name: 'Existing tickets', price_cents: 0, quantity_available: 12, quantity_sold: 2 }],
    } })
    render(<MemoryRouter initialEntries={['/dashboard/events/42/edit']}><Routes><Route path="/dashboard/events/:id/edit" element={<EditEventPage />} /></Routes></MemoryRouter>)
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Add ticket type' }))
    expect(screen.getByRole('spinbutton', { name: 'Tickets available', exact: true })).toHaveValue(18)
    expect(screen.getByRole('spinbutton', { name: 'Price ($)', exact: true })).toHaveValue(0)
    expect(screen.getByText('More ticket options').closest('details')).not.toHaveAttribute('open')
    await user.type(screen.getByRole('textbox', { name: 'Name', exact: true }), 'General Admission')
    await user.click(screen.getByRole('button', { name: 'Add ticket type' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/42/ticket_types', {
      name: 'General Admission', description: null, price_cents: 0, quantity_available: 18,
      door_allocation: null, max_per_order: null, max_per_buyer: null, attendee_info_mode: 'none', sales_start_at: null, sales_end_at: null,
      door_check_mode: 'instant', door_alert_label: null, door_instructions: null, scanner_show_buyer: false,
    }, expect.objectContaining({ signal: expect.any(AbortSignal) })))
  })

  it('retains the configured quantity and optional limits when editing an existing type', async () => {
    render(<MemoryRouter><TicketTypeCRUD eventId={42} remainingCapacity={5} onRefresh={vi.fn()} ticketTypes={[{
      id: 7, name: 'Early admission', description: 'Existing terms', price_cents: 3995, quantity_available: 25,
      quantity_sold: 10, door_allocation: 0, max_per_order: 3, max_per_buyer: 6, attendee_info_mode: 'name_only',
      sales_start_at: '2026-10-20T08:00:00Z', sales_end_at: '2026-10-21T08:00:00Z',
    }]} /></MemoryRouter>)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Edit Early admission' }))
    expect(screen.getByRole('spinbutton', { name: 'Tickets available', exact: true })).toHaveValue(25)
    await user.click(screen.getByText('More ticket options'))
    expect(screen.getByText('More ticket options').closest('details')).toHaveAttribute('open')
    expect(screen.getByLabelText('Tickets per order')).toHaveValue(3)
    expect(screen.getByLabelText('Tickets per buyer')).toHaveAccessibleDescription(/Leave blank for unlimited/)
    const attendeeInfo = screen.getByLabelText('Attendee info at checkout')
    expect(attendeeInfo).toHaveValue('name_only')
    expect(screen.getByRole('option', { name: 'None — buyer name only' })).toBeInTheDocument()
    await user.selectOptions(attendeeInfo, "Ask for each attendee's name and email")
    await user.click(screen.getByRole('button', { name: 'Update' }))
    await waitFor(() => expect(apiClient.put).toHaveBeenCalledWith('/organizer/events/42/ticket_types/7', {
      name: 'Early admission', description: 'Existing terms', price_cents: 3995, quantity_available: 25,
      door_allocation: 0, max_per_order: 3, max_per_buyer: 6, attendee_info_mode: 'name_and_email',
      sales_start_at: '2026-10-20T08:00:00Z', sales_end_at: '2026-10-21T08:00:00Z',
      door_check_mode: 'instant', door_alert_label: null, door_instructions: null, scanner_show_buyer: false,
    }, expect.objectContaining({ signal: expect.any(AbortSignal) })))
  })

  it('previews the edited ticket in real time with only scanner questions for this ticket type', async () => {
    const scanner_questions = [
      { id: 1, position: 0, prompt: 'Shirt size', kind: 'selection', options: ['M', 'L'], show_on_scanner: true },
      { id: 2, position: 3, prompt: 'Graduation Year', kind: 'number', scope: 'ticket', ticket_type_ids: [7], show_on_scanner: true },
      { id: 3, position: 0, prompt: 'Other ticket only', ticket_type_ids: [8], show_on_scanner: true },
      { id: 4, position: 1, prompt: 'Private note', ticket_type_ids: [7], show_on_scanner: false },
    ]
    apiClient.get.mockResolvedValue({ data: {
      permissions: { edit_event_content: true, manage_events: true, manage_inventory: true },
      id: 42, slug: 'community-night', status: 'draft', title: 'Community Night', timezone: 'Pacific/Guam', max_capacity: 30,
      ticket_types: [{ id: 7, name: 'Free Alumni', price_cents: 0, quantity_available: 12, quantity_sold: 2 }],
      scanner_questions,
    } })
    render(<MemoryRouter initialEntries={['/dashboard/events/42/edit']}><Routes><Route path="/dashboard/events/:id/edit" element={<EditEventPage />} /></Routes></MemoryRouter>)
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Edit Free Alumni' }))
    const preview = screen.getByRole('region', { name: 'Live Door Scanner Preview' })
    expect(preview).toHaveTextContent('Admitted')
    expect(preview).toHaveTextContent('Free Alumni')
    expect(preview).toHaveTextContent('Maria Cruz')
    expect(within(preview).getAllByRole('term').map(element => element.textContent.trim())).toEqual(['Graduation Year:', 'Shirt size:'])
    expect(preview).toHaveTextContent('1998')
    expect(preview).not.toHaveTextContent(/Other ticket only|Private note|Bought by/)

    await user.click(screen.getByRole('radio', { name: /Hold & Verify at Door/ }))
    expect(preview).toHaveTextContent('VERIFY AT DOOR')
    expect(within(preview).queryByRole('heading', { name: 'VERIFY AT DOOR' })).not.toBeInTheDocument()
    await user.type(screen.getByLabelText('Alert Banner'), 'FREE ALUMNI — CHECK ID')
    await user.type(screen.getByLabelText('Staff Instructions'), 'Ask for the graduation year.')
    await user.click(screen.getByRole('checkbox', { name: 'Show buyer name if someone else bought the ticket' }))
    await user.type(screen.getByRole('textbox', { name: 'Name', exact: true }), ' 2027')
    expect(preview).toHaveTextContent('FREE ALUMNI — CHECK ID')
    expect(preview).toHaveTextContent('Free Alumni 2027')
    expect(preview).toHaveTextContent('For: Maria Cruz')
    expect(preview).toHaveTextContent('Bought by Pat Cruz')
    expect(preview).toHaveTextContent('Ask for the graduation year.')
    expect(preview).toHaveTextContent('Confirm & Admit')
    await user.click(screen.getByRole('button', { name: 'Update' }))
    expect(apiClient.put).toHaveBeenCalledWith('/organizer/events/42/ticket_types/7', expect.objectContaining({
      door_check_mode: 'verify', door_alert_label: 'FREE ALUMNI — CHECK ID',
      door_instructions: 'Ask for the graduation year.', scanner_show_buyer: true,
    }), expect.anything())
  })

  it('lets organizers build a multi-night pass using series quick-select and excludes seated/pass/self events', async () => {
    apiClient.get.mockImplementation(url => {
      if (url === '/organizer/events') {
        return Promise.resolve({
          data: {
            events: [
              { id: 42, title: 'Current Pass Event', status: 'published', starts_at: '2026-11-20T08:00:00Z', assigned_seating: false, ticket_types: [] },
              { id: 101, title: 'Night 1', status: 'published', starts_at: '2026-11-21T08:00:00Z', assigned_seating: false, ticket_types: [] },
              { id: 102, title: 'Night 2', status: 'published', starts_at: '2026-11-22T08:00:00Z', assigned_seating: false, ticket_types: [] },
              { id: 103, title: 'Seated Gala', status: 'published', starts_at: '2026-11-23T08:00:00Z', assigned_seating: true, ticket_types: [] },
              { id: 104, title: 'Another Pass Event', status: 'published', starts_at: '2026-11-24T08:00:00Z', assigned_seating: false, ticket_types: [{ id: 9, is_pass: true }] },
            ],
          },
        })
      }
      if (url === '/organizer/event_series') {
        return Promise.resolve({
          data: {
            event_series: [
              { id: 5, name: 'FD Tourney 2026', events: [{ id: 101 }, { id: 102 }, { id: 42 }] },
            ],
          },
        })
      }
      return Promise.resolve({ data: {} })
    })

    render(<MemoryRouter><TicketTypeCRUD eventId={42} onRefresh={vi.fn()} /></MemoryRouter>)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Add ticket type' }))
    await user.type(screen.getByRole('textbox', { name: 'Name', exact: true }), 'Season Pass')
    await user.clear(screen.getByRole('spinbutton', { name: 'Price ($)', exact: true }))
    await user.type(screen.getByRole('spinbutton', { name: 'Price ($)', exact: true }), '50')
    await user.type(screen.getByRole('spinbutton', { name: 'Tickets available', exact: true }), '100')

    await user.click(screen.getByRole('checkbox', { name: /This ticket is a multi-night pass/i }))
    expect(await screen.findByText('Night 1')).toBeInTheDocument()
    expect(screen.getByText('Night 2')).toBeInTheDocument()
    expect(screen.queryByText('Current Pass Event')).not.toBeInTheDocument()
    expect(screen.queryByText('Seated Gala')).not.toBeInTheDocument()
    expect(screen.queryByText('Another Pass Event')).not.toBeInTheDocument()

    await user.selectOptions(screen.getByLabelText(/Add all nights from series/i), '5')
    await user.click(screen.getByRole('button', { name: 'Add series nights' }))
    expect(screen.getByText('Included nights (2 selected)')).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Add ticket type' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith(
      '/organizer/events/42/ticket_types',
      expect.objectContaining({
        name: 'Season Pass',
        price_cents: 5000,
        quantity_available: 100,
        included_event_ids: [101, 102],
      }),
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    ))
  })

  it('disables multi-night pass on seated events and prevents converting sold non-pass tickets', async () => {
    const { rerender } = render(<MemoryRouter><TicketTypeCRUD eventId={42} assignedSeating onRefresh={vi.fn()} /></MemoryRouter>)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Add ticket type' }))
    expect(screen.getByRole('checkbox', { name: /This ticket is a multi-night pass/i })).toBeDisabled()
    expect(screen.getByText('Multi-night passes are available for general admission events only.')).toBeInTheDocument()

    rerender(<MemoryRouter><TicketTypeCRUD eventId={42} onRefresh={vi.fn()} ticketTypes={[{
      id: 7, name: 'Sold GA', price_cents: 1000, quantity_available: 50, quantity_sold: 3, is_pass: false,
    }]} /></MemoryRouter>)
    await user.click(screen.getByRole('button', { name: 'Edit Sold GA' }))
    expect(screen.getByRole('checkbox', { name: /This ticket is a multi-night pass/i })).toBeDisabled()
    expect(screen.getByText(/cannot be converted into a multi-night pass/i)).toBeInTheDocument()
  })

  it('locks existing nights on sold passes, allows adding new nights, and syncs pass holders with 422 error display', async () => {
    apiClient.get.mockImplementation(url => {
      if (url === '/organizer/events') {
        return Promise.resolve({
          data: {
            events: [
              { id: 101, title: 'Night 1', status: 'published', starts_at: '2026-11-21T08:00:00Z', assigned_seating: false, ticket_types: [] },
              { id: 102, title: 'Night 2', status: 'published', starts_at: '2026-11-22T08:00:00Z', assigned_seating: false, ticket_types: [] },
            ],
          },
        })
      }
      return Promise.resolve({ data: { event_series: [] } })
    })

    const onRefresh = vi.fn().mockResolvedValue(undefined)
    render(<MemoryRouter><TicketTypeCRUD eventId={42} onRefresh={onRefresh} ticketTypes={[{
      id: 8,
      name: 'Tournament Pass',
      price_cents: 5000,
      quantity_available: 50,
      quantity_sold: 4,
      is_pass: true,
      included_event_ids: [101],
      included_events: [{ id: 101, title: 'Night 1', starts_at: '2026-11-21T08:00:00Z', timezone: 'Pacific/Guam', status: 'published' }],
    }]} /></MemoryRouter>)

    const user = userEvent.setup()
    expect(screen.getByText('Multi-Night Pass · 1 night')).toBeInTheDocument()

    // Edit sold pass: Night 1 is locked, Night 2 can be added
    await user.click(screen.getByRole('button', { name: 'Edit Tournament Pass' }))
    const night1Checkbox = await screen.findByRole('checkbox', { name: /Night 1/i })
    const night2Checkbox = screen.getByRole('checkbox', { name: /Night 2/i })
    expect(night1Checkbox).toBeChecked()
    expect(night1Checkbox).toBeDisabled()
    expect(night2Checkbox).not.toBeDisabled()
    await user.click(night2Checkbox)
    await user.click(screen.getByRole('button', { name: 'Update' }))
    await waitFor(() => expect(apiClient.put).toHaveBeenCalledWith(
      '/organizer/events/42/ticket_types/8',
      expect.objectContaining({ included_event_ids: [101, 102] }),
      expect.any(Object),
    ))

    // Sync Pass Holders: first test 422 capacity error, then success
    apiClient.post.mockRejectedValueOnce({
      response: { status: 422, data: { error: 'Insufficient capacity on Night 2: needs 4 additional pass tickets, only 1 remaining' } },
    })
    await user.click(screen.getByRole('button', { name: 'Sync Pass Holders' }))
    await user.click(screen.getByRole('button', { name: 'Confirm Sync' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Insufficient capacity on Night 2: needs 4 additional pass tickets, only 1 remaining')

    apiClient.post.mockResolvedValueOnce({ data: { parent_ticket_count: 4, issued_ticket_count: 4 } })
    await user.click(screen.getByRole('button', { name: 'Sync Pass Holders' }))
    await user.click(screen.getByRole('button', { name: 'Confirm Sync' }))
    expect(await screen.findByRole('status')).toHaveTextContent('Synced 4 pass holders: issued 4 new night tickets.')
    expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/42/ticket_types/8/sync_pass_holders', {}, expect.any(Object))
  })

  it('shows a helper note when organizer events are truncated beyond the first 100', async () => {
    apiClient.get.mockImplementation(url => {
      if (url === '/organizer/events') {
        return Promise.resolve({
          headers: { 'x-total-count': '145' },
          data: {
            events: [
              { id: 101, title: 'Night 1', status: 'published', starts_at: '2026-11-21T08:00:00Z', assigned_seating: false, ticket_types: [] },
            ],
            meta: { total_count: 145 },
          },
        })
      }
      return Promise.resolve({ data: { event_series: [] } })
    })

    render(<MemoryRouter><TicketTypeCRUD eventId={42} onRefresh={vi.fn()} /></MemoryRouter>)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Add ticket type' }))
    await user.click(screen.getByRole('checkbox', { name: /This ticket is a multi-night pass/i }))
    expect(await screen.findByText('Night 1')).toBeInTheDocument()
    expect(screen.getByText(/Showing first 100 events — use a series or search if your event isn't listed/i)).toBeInTheDocument()
  })

  it('preserves saved sales_start_at and sales_end_at precision when editing unrelated fields', async () => {
    const onRefresh = vi.fn().mockResolvedValue(undefined)
    render(<MemoryRouter><TicketTypeCRUD eventId={42} eventTimezone="Pacific/Guam" onRefresh={onRefresh} ticketTypes={[{
      id: 9,
      name: 'Early Admission',
      price_cents: 2500,
      quantity_available: 50,
      quantity_sold: 0,
      sales_start_at: '2027-05-01T00:00:01Z',
      sales_end_at: '2027-05-20T00:00:01Z',
    }]} /></MemoryRouter>)

    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Edit Early Admission' }))
    const nameInput = screen.getByLabelText(/^Name/i)
    await user.clear(nameInput)
    await user.type(nameInput, 'Renamed Admission')
    await user.click(screen.getByRole('button', { name: 'Update' }))

    await waitFor(() => expect(apiClient.put).toHaveBeenCalledWith(
      '/organizer/events/42/ticket_types/9',
      expect.objectContaining({
        name: 'Renamed Admission',
        sales_start_at: '2027-05-01T00:00:01Z',
        sales_end_at: '2027-05-20T00:00:01Z',
      }),
      expect.any(Object),
    ))
  })

  it('validates effective sales timestamps at second precision when only one endpoint changes', async () => {
    const onRefresh = vi.fn().mockResolvedValue(undefined)
    render(<MemoryRouter><TicketTypeCRUD eventId={42} eventTimezone="Pacific/Guam" onRefresh={onRefresh} ticketTypes={[{
      id: 10,
      name: 'Short Window',
      price_cents: 2500,
      quantity_available: 50,
      quantity_sold: 0,
      // 10:00:01 to 10:01:59 Guam time (UTC+10)
      sales_start_at: '2027-05-01T00:00:01Z',
      sales_end_at: '2027-05-01T00:01:59Z',
    }]} /></MemoryRouter>)

    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Edit Short Window' }))
    await user.click(screen.getByText('More ticket options'))
    const startInput = screen.getByLabelText('Sales start')
    // Changing start to 10:01 is still before preserved end 10:01:59.
    await user.clear(startInput)
    await user.type(startInput, '2027-05-01T10:01')
    await user.click(screen.getByRole('button', { name: 'Update' }))

    await waitFor(() => expect(apiClient.put).toHaveBeenCalledWith(
      '/organizer/events/42/ticket_types/10',
      expect.objectContaining({
        sales_start_at: '2027-05-01T10:01',
        sales_end_at: '2027-05-01T00:01:59Z',
      }),
      expect.any(Object),
    ))
  })
})
