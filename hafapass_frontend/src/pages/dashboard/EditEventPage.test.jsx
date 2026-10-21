import { beforeEach, describe, expect, it, vi } from 'vitest'
import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import apiClient from '../../api/client'
import EditEventPage from './EditEventPage'

vi.mock('../../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn(), put: vi.fn(), post: vi.fn() } }))
vi.mock('../../hooks/usePlatformFeeTerms', () => ({ default: () => ({ status: 'ready', retry: () => {}, terms: { percent: 5, flatCents: 100, bearer: 'platform', payoutScheduleText: 'within 3 business days after your event' } }) }))
vi.mock('../../components/CoverImageUpload', () => ({ default: ({ onUploaded }) => <button type="button" onClick={() => onUploaded('https://images.invalid/verified.png')}>Choose verified cover</button> }))
vi.mock('../../components/TicketTypeCRUD', () => ({ default: ({ ticketTypes }) => <ul>{ticketTypes.map(type => <li key={type.id}>{type.name}</li>)}</ul> }))
vi.mock('../../hooks/useEventCategories', () => ({ default: () => [{ value: 'other', label: 'Other' }] }))
const launch = vi.hoisted(() => ({ value: {} }))
vi.mock('../../hooks/useLaunchCapabilities', () => ({ default: () => launch.value }))

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

  it('lets an event manager choose who pays the fee next to ticket pricing, saved separately', async () => {
    const user = userEvent.setup()
    mount()
    const panel = (await screen.findByRole('heading', { name: 'Who pays the service fee' })).closest('section')
    expect(panel.nextElementSibling).toHaveAttribute('id', 'ticket-types')
    expect(within(panel).getByRole('radio', { name: /Buyer pays the fee/ })).toBeChecked()
    apiClient.put.mockResolvedValueOnce({ data: { ...event, fee_policy: 'organizer_absorbs', buyer_fee_percent: 0 } })
    await user.click(within(panel).getByRole('radio', { name: /I cover the fee/ }))
    await user.click(within(panel).getByRole('button', { name: 'Save fee choice' }))
    expect(apiClient.put).toHaveBeenCalledWith('/organizer/events/37', { fee_policy: 'organizer_absorbs', buyer_fee_percent: 0 }, expect.any(Object))
    expect(await within(panel).findByText('Fee choice saved. It applies to new orders.')).toBeInTheDocument()
    expect(within(panel).getByRole('radio', { name: /I cover the fee/ })).toBeChecked()
  })

  it('shows the fee choice read-only to content editors who cannot manage the event', async () => {
    apiClient.get.mockResolvedValue({ data: { ...event, permissions: { ...event.permissions, manage_events: false } } })
    mount()
    const panel = (await screen.findByRole('heading', { name: 'Who pays the service fee' })).closest('section')
    expect(within(panel).getByRole('radio', { name: /Buyer pays the fee/ })).toBeDisabled()
    expect(within(panel).queryByRole('button', { name: 'Save fee choice' })).not.toBeInTheDocument()
  })

  it('keeps Save Changes in a sticky bar that reports unsaved details and still submits', async () => {
    const user = userEvent.setup()
    mount()
    const title = await screen.findByLabelText(/Event Title/)
    const bar = screen.getByTestId('event-details-save-bar')
    expect(bar).toHaveClass('sticky', 'bottom-0')
    expect(bar.closest('form')).not.toBeNull()
    const save = within(bar).getByRole('button', { name: 'Save Changes' })
    expect(save).toHaveAccessibleDescription('Event details are saved')
    await user.type(title, ' Live')
    expect(save).toHaveAccessibleDescription('Unsaved event detail changes')
    expect(screen.getByText('Saved separately.')).toBeInTheDocument()
    let finishSave
    apiClient.put.mockReturnValueOnce(new Promise(resolve => { finishSave = resolve }))
    await user.click(save)
    expect(apiClient.put).toHaveBeenCalledTimes(1)
    expect(apiClient.put.mock.calls[0][1]).toMatchObject({ title: 'Published Workshop Live' })
    const pending = within(bar).getByRole('button', { name: 'Saving...' })
    expect(pending).toBeDisabled()
    expect(pending).toHaveAccessibleDescription('Saving event details…')
    await act(async () => finishSave({ data: { ...event, title: 'Published Workshop Live' } }))
    await screen.findByText('Event updated successfully.')
    expect(title).toHaveValue('Published Workshop Live')
    expect(within(bar).getByRole('button', { name: 'Save Changes' })).toHaveAccessibleDescription('Event details are saved')
    expect(within(bar).getByText('Event details are saved')).toBeInTheDocument()
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

  it('focuses the invalid title and connects its summary error for a content-only marketer', async () => {
    apiClient.get.mockResolvedValue({ data: { ...event, permissions: { edit_event_content: true } } })
    const user = userEvent.setup()
    mount()
    const title = await screen.findByLabelText(/Event Title/)
    await user.clear(title)
    const save = screen.getByRole('button', { name: 'Save Changes' })
    await user.click(save)
    expect(apiClient.put).not.toHaveBeenCalled()
    await waitFor(() => expect(title).toHaveFocus())
    expect(title).toHaveAttribute('aria-invalid', 'true')
    expect(title).toHaveAttribute('aria-describedby', 'title-error')
    expect(screen.getByRole('link', { name: 'Title is required' })).toHaveAttribute('href', '#title')
    expect(screen.queryByLabelText(/Venue Name/)).not.toBeInTheDocument()
    await user.type(title, 'Corrected marketer title')
    await user.click(save)
    await screen.findByText('Event updated successfully.')
    expect(apiClient.put.mock.calls[0][1].title).toBe('Corrected marketer title')
    expect(apiClient.put.mock.calls[0][1]).not.toHaveProperty('venue_name')
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
    await screen.findByRole('link', { name: 'Explain the schedule change for ticket holders' })
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

it('requires saving before publishing, names the saved preview and confirms the saved title', async () => {
  const draft = { ...event, status: 'draft', slug: 'workshop', publish_checklist: [{ code: 'event_details', label: 'Details', complete: true }] }
  apiClient.get.mockResolvedValue({ data: draft })
  apiClient.put.mockResolvedValue({ data: { ...draft, title: 'Saved new title' } })
  apiClient.post.mockResolvedValue({ data: { ...draft, title: 'Saved new title', status: 'published' } })
  const user = userEvent.setup()
  mount()
  const title = await screen.findByLabelText(/Event Title/)
  await user.clear(title)
  await user.type(title, 'Saved new title')
  expect(screen.getByRole('button', { name: 'Publish Event' })).toBeDisabled()
  expect(screen.getByRole('link', { name: 'Preview saved event' })).toHaveAttribute('href', '/events/workshop?preview=true')
  expect(screen.getByText(/Preview shows the last saved event/)).toBeInTheDocument()
  await user.click(screen.getByRole('button', { name: 'Save Changes' }))
  await screen.findByText('Event updated successfully.')
  await user.click(screen.getByRole('button', { name: 'Publish Event' }))
  expect(screen.getByRole('dialog')).toHaveTextContent('Publish the saved event “Saved new title”?')
  await user.click(screen.getByRole('button', { name: 'Yes, Publish' }))
  await screen.findByText('Event published successfully!')
  expect(apiClient.post).toHaveBeenCalledTimes(1)
})


it('shows organizer verification as one checklist step with a request action, and it still blocks publishing', async () => {
  window.localStorage.setItem('hafapass_organization_id', '1')
  const draft = { ...event, organization_id: 1, status: 'draft', slug: 'workshop', publish_checklist: [
    { code: 'title', label: 'Title', complete: true },
    { code: 'organizer_verified', label: 'Organizer identity verified', complete: false },
    { code: 'pilot_readiness_approved', label: 'Pilot readiness', complete: true },
  ] }
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path === '/organizer_profile'
    ? { verification_status: 'unverified', organization: { role: 'owner' } } : draft }))
  apiClient.post.mockResolvedValue({ data: { verification_status: 'pending', verification_requested_at: '2026-10-21T00:30:00Z', organization: { role: 'owner' } } })
  const user = userEvent.setup()
  mount()
  const checklist = await screen.findByRole('list', { name: 'Publishing checklist' })
  expect(checklist).toHaveTextContent('Waiting for HåfaPass to verify your organization before tickets go on sale')
  expect(checklist).not.toHaveTextContent(/launch review|Pilot readiness/i)
  expect(screen.getByRole('button', { name: 'Publish Event' })).toBeDisabled()
  await user.click(await within(checklist).findByRole('button', { name: 'Request verification' }))
  expect(apiClient.post).toHaveBeenCalledWith('/organizer_profile/submit_verification', {}, expect.objectContaining({ organizationId: '1' }))
  expect(await within(checklist).findByText(/Verification requested .* HåfaPass will review it soon\./)).toBeInTheDocument()
  window.localStorage.removeItem('hafapass_organization_id')
})

it('lets an unverified organizer publish when verification only holds back sales, and says when tickets go on sale', async () => {
  const draft = { ...event, organization_id: 1, status: 'draft', slug: 'workshop', publish_checklist: [
    { code: 'title', label: 'Title', complete: true, required_to_publish: true },
    { code: 'organizer_verified', label: 'Organizer identity verified', complete: false, required_to_publish: false },
  ] }
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path === '/organizer_profile'
    ? { verification_status: 'pending', verification_requested_at: '2026-10-21T00:30:00Z', organization: { role: 'owner' } } : draft }))
  const user = userEvent.setup()
  mount()
  const checklist = await screen.findByRole('list', { name: 'Publishing checklist' })
  expect(checklist).toHaveTextContent('You can publish now. Tickets go on sale once HåfaPass verifies your organization.')
  expect(await within(checklist).findByText(/Verification requested .* HåfaPass will review it soon\./)).toBeInTheDocument()
  const publish = screen.getByRole('button', { name: 'Publish Event' })
  expect(publish).toBeEnabled()
  await user.click(publish)
  expect(screen.getByRole('dialog')).toHaveTextContent('Tickets go on sale once HåfaPass verifies your organization.')
  expect(screen.getByRole('dialog')).not.toHaveTextContent('purchase tickets')
})

describe('canonical saved event form', () => {
  const readyDraft = { ...event, status: 'draft', venue_city: 'Tamuning', max_capacity: 300,
    description: 'Keep this event description', ticket_types: [{ id: 4, name: 'Saved admission' }],
    publish_checklist: [{ code: 'event_details', label: 'Details', complete: true }] }
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.get.mockResolvedValue({ data: readyDraft })
  })

  it.each(['full', 'partial'])('clears saved default-city and leading-zero edits from a %s response', async response => {
    const normalized = { id: readyDraft.id, venue_city: 'Guam', max_capacity: 200 }
    apiClient.put.mockResolvedValue({ data: response === 'full' ? { ...readyDraft, ...normalized } : normalized })
    const user = userEvent.setup()
    mount()
    const city = await screen.findByLabelText('City')
    const capacity = screen.getByLabelText('Max Capacity')
    await user.clear(city)
    fireEvent.change(capacity, { target: { value: '0200' } })
    expect(capacity.value).toBe('0200')
    expect(screen.getByRole('button', { name: 'Publish Event' })).toBeDisabled()
    await user.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Event updated successfully.')
    expect(apiClient.put.mock.calls[0][1]).toMatchObject({ venue_city: 'Guam', max_capacity: 200 })
    expect(city).toHaveValue('Guam')
    expect(capacity.value).toBe('200')
    expect(screen.getByLabelText('Description')).toHaveValue('Keep this event description')
    expect(screen.getByText('Saved admission')).toBeInTheDocument()
    expect(screen.queryByText(/Preview shows the last saved event/)).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Publish Event' })).toBeEnabled()
  })

  it('retains raw city/capacity edits and blocks publishing after a failed save', async () => {
    apiClient.put.mockRejectedValue(new Error('Synthetic failure'))
    const user = userEvent.setup()
    mount()
    await user.clear(await screen.findByLabelText('City'))
    const capacity = screen.getByLabelText('Max Capacity')
    fireEvent.change(capacity, { target: { value: '0200' } })
    await user.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Failed to update event')
    expect(screen.getByLabelText('City')).toHaveValue('')
    expect(capacity.value).toBe('0200')
    expect(screen.getByRole('button', { name: 'Publish Event' })).toBeDisabled()
    expect(screen.getByText(/Preview shows the last saved event/)).toBeInTheDocument()
  })

  it('keeps a decimal capacity dirty and sends valid exponential notation as the validated number', async () => {
    apiClient.get.mockResolvedValue({ data: { ...readyDraft, max_capacity: 1 } })
    apiClient.put.mockResolvedValue({ data: { ...readyDraft, max_capacity: 100 } })
    const user = userEvent.setup()
    mount()
    const capacity = await screen.findByLabelText('Max Capacity')
    fireEvent.change(capacity, { target: { value: '1.2' } })
    expect(screen.getByText(/Preview shows the last saved event/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Publish Event' })).toBeDisabled()
    await user.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByRole('link', { name: 'Max capacity must be a positive integer' })
    expect(apiClient.put).not.toHaveBeenCalled()
    expect(capacity.value).toBe('1.2')
    for (const value of ['2147483648', '9007199254740992']) {
      fireEvent.change(capacity, { target: { value } })
      await user.click(screen.getByRole('button', { name: 'Save Changes' }))
      expect(apiClient.put).not.toHaveBeenCalled()
      expect(capacity).toHaveAttribute('aria-invalid', 'true')
      expect(capacity.value).toBe(value)
    }
    fireEvent.change(capacity, { target: { value: '1e2' } })
    await user.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Event updated successfully.')
    expect(apiClient.put.mock.calls[0][1].max_capacity).toBe(100)
    expect(capacity.value).toBe('100')
    expect(screen.getByRole('button', { name: 'Publish Event' })).toBeEnabled()
  })
})

describe('ticket transfer setting', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    launch.value = {}
    apiClient.get.mockResolvedValue({ data: { ...event, transfers_enabled: false } })
    apiClient.put.mockImplementation((_url, body) => Promise.resolve({ data: { ...event, ...body } }))
  })

  it('hides the setting and sends no transfer field while the capability is off', async () => {
    const user = userEvent.setup()
    mount()
    await user.type(await screen.findByLabelText(/Event Title/), ' Live')
    expect(screen.queryByLabelText('Allow ticket transfers')).not.toBeInTheDocument()
    await user.click(within(screen.getByTestId('event-details-save-bar')).getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Event updated successfully.')
    expect(apiClient.put.mock.calls[0][1]).not.toHaveProperty('transfers_enabled')
  })

  it('lets an organizer allow transfers when the capability is on', async () => {
    launch.value = { ticket_transfers: true }
    const user = userEvent.setup()
    mount()
    const toggle = await screen.findByLabelText('Allow ticket transfers')
    expect(toggle).not.toBeChecked()
    expect(toggle).toHaveAccessibleDescription(/replaces the QR code/)
    await user.click(toggle)
    await user.click(within(screen.getByTestId('event-details-save-bar')).getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Event updated successfully.')
    expect(apiClient.put.mock.calls[0][1]).toMatchObject({ transfers_enabled: true })
    expect(screen.getByLabelText('Allow ticket transfers')).toBeChecked()
  })
})
