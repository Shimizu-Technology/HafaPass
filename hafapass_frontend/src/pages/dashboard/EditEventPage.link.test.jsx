import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import apiClient from '../../api/client'
import EditEventPage from './EditEventPage'
import { PUBLIC_WEB_URL } from '../../utils/site'

vi.mock('../../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn(), put: vi.fn(), post: vi.fn() } }))
vi.mock('../../components/CoverImageUpload', () => ({ default: () => null }))
vi.mock('../../components/TicketTypeCRUD', () => ({ default: () => null }))
vi.mock('../../hooks/useEventCategories', () => ({ default: () => [{ value: 'other', label: 'Other' }] }))
vi.mock('../../hooks/useLaunchCapabilities', () => ({ default: () => ({}) }))

const published = {
  permissions: { edit_event_content: true, manage_events: true }, id: 37, title: 'Reef Night', slug: 'reef-night',
  slug_follows_title: false, ever_published: true, venue_name: 'Venue', status: 'published', timezone: 'Pacific/Guam',
  category: 'other', age_restriction: 'all_ages', starts_at: '2099-10-16T09:00:00Z', ticket_types: [],
}

function mount(event = published, availability = { available: true, message: null }) {
  apiClient.get.mockImplementation((url, config) => url.endsWith('/slug_availability')
    ? Promise.resolve({ data: { slug: config.params.slug, ...availability } })
    : Promise.resolve({ data: event }))
  return render(<MemoryRouter initialEntries={['/dashboard/events/37/edit']}><Routes>
    <Route path="/dashboard/events/:id/edit" element={<EditEventPage />} />
  </Routes></MemoryRouter>)
}

describe('event link editing', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.put.mockImplementation((url, payload) => Promise.resolve({ data: { ...published, ...payload } }))
  })

  it('previews the full public link as the organizer types and normalizes the name', async () => {
    const user = userEvent.setup()
    mount()
    const field = await screen.findByLabelText('Link name')
    expect(screen.getByText(`${PUBLIC_WEB_URL}/events/reef-night`)).toBeInTheDocument()
    expect(screen.getByText('Lowercase letters, numbers, and hyphens. Renaming the event keeps this link.')).toBeInTheDocument()

    await user.clear(field)
    await user.type(field, 'Reef Night 2099')

    expect(field).toHaveValue('reef-night-2099')
    expect(screen.getByText(`${PUBLIC_WEB_URL}/events/reef-night-2099`)).toBeInTheDocument()
    expect(await screen.findByText('This link is available.')).toBeInTheDocument()
    expect(apiClient.get).toHaveBeenCalledWith('/organizer/events/37/slug_availability',
      expect.objectContaining({ params: { slug: 'reef-night-2099' } }))
  })

  it('warns that old links keep working when a published event gets a new link, then saves it', async () => {
    const user = userEvent.setup()
    mount()
    const field = await screen.findByLabelText('Link name')
    expect(screen.queryByText(/already public/)).not.toBeInTheDocument()

    await user.clear(field)
    await user.type(field, 'reef-night-encore')

    expect(screen.getByText(/This event is already public\. After you save, the old link/)).toHaveTextContent(
      `${PUBLIC_WEB_URL}/events/reef-night`)
    await screen.findByText('This link is available.')
    await user.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Event updated successfully.')
    expect(apiClient.put.mock.calls[0][1]).toMatchObject({ slug: 'reef-night-encore' })
    expect(screen.queryByText(/already public/)).not.toBeInTheDocument()
  })

  it('shows format problems inline and blocks the save', async () => {
    const user = userEvent.setup()
    mount()
    const field = await screen.findByLabelText('Link name')
    await user.clear(field)
    await user.type(field, 'ab')

    expect(screen.getByText('Use 3 to 80 characters')).toBeInTheDocument()
    expect(field).toHaveAttribute('aria-invalid', 'true')
    await user.type(field, '-')
    expect(screen.getByText(/single hyphens between words/)).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Save Changes' }))
    expect(apiClient.put).not.toHaveBeenCalled()
    await waitFor(() => expect(field).toHaveFocus())
    expect(apiClient.get).not.toHaveBeenCalledWith('/organizer/events/37/slug_availability', expect.anything())
  })

  it('shows the API reason when a link is reserved or already used and blocks the save', async () => {
    const user = userEvent.setup()
    mount(published, { available: false, message: 'Event link is reserved. Choose a different link name' })
    const field = await screen.findByLabelText('Link name')
    await user.clear(field)
    await user.type(field, 'checkout')

    expect(await screen.findByText('Event link is reserved. Choose a different link name')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Save Changes' }))
    expect(apiClient.put).not.toHaveBeenCalled()
  })

  it('puts a link rejected on save next to the field', async () => {
    const user = userEvent.setup()
    mount()
    apiClient.put.mockRejectedValueOnce({ response: { status: 422, data: { errors: ['Event link is already used by another event'] } } })
    const field = await screen.findByLabelText('Link name')
    await user.clear(field)
    await user.type(field, 'taken-link')
    await user.click(screen.getByRole('button', { name: 'Save Changes' }))

    expect((await screen.findAllByText('Event link is already used by another event')).length).toBeGreaterThan(0)
    await waitFor(() => expect(field).toHaveFocus())
    expect(screen.queryByText('Failed to update event')).not.toBeInTheDocument()
  })

  it('explains that a draft link follows the title and does not send an untouched link', async () => {
    const user = userEvent.setup()
    mount({ ...published, status: 'draft', slug_follows_title: true, ever_published: false })
    await screen.findByLabelText('Link name')
    expect(screen.getByText(/Until you publish or change it, the link updates to match the title/)).toBeInTheDocument()

    await user.type(screen.getByLabelText(/Event Title/), ' Live')
    await user.click(screen.getByRole('button', { name: 'Save Changes' }))

    await screen.findByText('Event updated successfully.')
    expect(apiClient.put.mock.calls[0][1]).not.toHaveProperty('slug')
  })
})
