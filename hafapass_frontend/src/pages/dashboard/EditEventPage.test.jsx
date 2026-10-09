import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import apiClient from '../../api/client'
import EditEventPage from './EditEventPage'

vi.mock('../../api/client', () => ({ default: { get: vi.fn(), put: vi.fn() } }))
vi.mock('../../components/CoverImageUpload', () => ({ default: ({ onUploaded }) => <button type="button" onClick={() => onUploaded('https://images.invalid/verified.png')}>Choose verified cover</button> }))
vi.mock('../../components/TicketTypeCRUD', () => ({ default: () => null }))
vi.mock('../../hooks/useEventCategories', () => ({ default: () => [{ value: 'other', label: 'Other' }] }))
vi.mock('../../hooks/useLaunchCapabilities', () => ({ default: () => ({}) }))

const event = { id: 37, title: 'Published Workshop', venue_name: 'Venue', status: 'published', timezone: 'Pacific/Guam', category: 'other', age_restriction: 'all_ages', starts_at: '2026-10-16T09:00:42.123Z', ends_at: '2026-10-16T12:00:42.123Z', doors_open_at: '2026-10-16T08:30:42.123Z', ticket_types: [] }
function mount() { return render(<MemoryRouter initialEntries={['/dashboard/events/37/edit']}><Routes><Route path="/dashboard/events/:id/edit" element={<EditEventPage />} /></Routes></MemoryRouter>) }

describe('published event content and schedule edits', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.get.mockResolvedValue({ data: event })
    apiClient.put.mockResolvedValue({ data: event })
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
