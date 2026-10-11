import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import apiClient from '../../api/client'
import EditEventPage from './EditEventPage'

vi.mock('../../api/client', () => ({ default: { get: vi.fn(), put: vi.fn() } }))
vi.mock('../../components/CoverImageUpload', () => ({ default: ({ onUploaded }) => <button type="button" onClick={() => onUploaded('https://images.invalid/verified.png')}>Choose verified cover</button> }))
vi.mock('../../components/TicketTypeCRUD', () => ({ default: ({ ticketTypes }) => <ul>{ticketTypes.map(type => <li key={type.id}>{type.name}</li>)}</ul> }))
vi.mock('../../hooks/useEventCategories', () => ({ default: () => [{ value: 'other', label: 'Other' }] }))
vi.mock('../../hooks/useLaunchCapabilities', () => ({ default: () => ({}) }))

const event = { permissions: { edit_event_content: true, manage_events: true, manage_inventory: true, box_office: true, view_attendees: true, manage_staff: true, manage_attendees: true, view_finance: true }, id: 37, title: 'Published Workshop', venue_name: 'Venue', status: 'published', timezone: 'Pacific/Guam', category: 'other', age_restriction: 'all_ages', starts_at: '2026-10-16T09:00:42.123Z', ends_at: '2026-10-16T12:00:42.123Z', doors_open_at: '2026-10-16T08:30:42.123Z', ticket_types: [] }
function mount() { return render(<MemoryRouter initialEntries={['/dashboard/events/37/edit']}><Routes><Route path="/dashboard/events/:id/edit" element={<EditEventPage />} /></Routes></MemoryRouter>) }

describe('published event content and schedule edits', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.get.mockResolvedValue({ data: event })
    apiClient.put.mockResolvedValue({ data: event })
  })

  it('shows assigned scanner recovery on direct editor access without editing controls', async () => {
    apiClient.get.mockResolvedValue({ data: { ...event, permissions: { scan: true, edit_event_content: false } } })
    mount()
    expect(await screen.findByRole('link', { name: 'Scan tickets for this event' })).toHaveAttribute('href', '/dashboard/scanner?event=37')
    expect(screen.queryByRole('button', { name: 'Save Changes' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Cancel Event/ })).not.toBeInTheDocument()
    expect(apiClient.put).not.toHaveBeenCalled()
  })

  it('limits presentation editors to content fields and sends no discarded operation edits', async () => {
    apiClient.get.mockResolvedValue({ data: { ...event, permissions: { edit_event_content: true } } })
    apiClient.put.mockResolvedValue({ data: { ...event, permissions: { edit_event_content: true } } })
    const user = userEvent.setup()
    mount()
    await user.click(await screen.findByRole('button', { name: 'Choose verified cover' }))
    expect(screen.queryByLabelText(/Start Date & Time/)).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Clone' })).not.toBeInTheDocument()
    expect(screen.queryByText('Existing admission')).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Event updated successfully.')
    expect(Object.keys(apiClient.put.mock.calls[0][1]).sort()).toEqual(['category', 'cover_image_url', 'description', 'short_description', 'title'])
  })

  it('saves a cover without changing precise schedule times or requiring a reason', async () => {
    const user = userEvent.setup()
    mount()
    await user.click(await screen.findByRole('button', { name: 'Choose verified cover' }))
    await user.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Event updated successfully.')
    const payload = apiClient.put.mock.calls[0][1]
    expect(payload.cover_image_url).toBe('https://images.invalid/verified.png')
    for (const field of ['starts_at', 'ends_at', 'doors_open_at', 'change_reason']) expect(payload).not.toHaveProperty(field)
  })

  it('keeps the existing ticket collection visible after a partial event update response', async () => {
    apiClient.get.mockResolvedValue({ data: { ...event, ticket_types: [{ id: 1, name: 'Existing admission' }] } })
    apiClient.put.mockResolvedValue({ data: { id: event.id, title: event.title, status: 'published' } })
    const user = userEvent.setup()
    mount()
    await screen.findByText('Existing admission')
    await user.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Event updated successfully.')
    expect(screen.getByText('Existing admission')).toBeInTheDocument()
  })

  it('requires a reason for a genuine schedule change', async () => {
    const user = userEvent.setup()
    mount()
    const start = await screen.findByLabelText(/Start Date & Time/)
    await user.clear(start)
    await user.type(start, '2026-10-16T20:00')
    await user.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Explain the schedule change for ticket holders')
    expect(apiClient.put).not.toHaveBeenCalled()
    await user.type(screen.getByLabelText(/Reason for schedule change/), 'Synthetic schedule correction')
    await user.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Event updated successfully.')
    const payload = apiClient.put.mock.calls[0][1]
    expect(payload).toMatchObject({ starts_at: '2026-10-16T20:00', change_reason: 'Synthetic schedule correction' })
    expect(payload).not.toHaveProperty('ends_at')
    expect(payload).not.toHaveProperty('doors_open_at')
  })

  it('explicitly clears an optional time with a schedule-change reason', async () => {
    const user = userEvent.setup()
    mount()
    await user.clear(await screen.findByLabelText('Doors Open At'))
    await user.type(screen.getByLabelText(/Reason for schedule change/), 'Doors open with the event')
    await user.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Event updated successfully.')
    expect(apiClient.put.mock.calls[0][1]).toMatchObject({ doors_open_at: null, change_reason: 'Doors open with the event' })
    expect(apiClient.put.mock.calls[0][1]).not.toHaveProperty('starts_at')
  })
})
