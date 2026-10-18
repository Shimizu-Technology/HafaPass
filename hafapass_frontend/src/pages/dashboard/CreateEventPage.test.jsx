import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { createMemoryRouter, Link, MemoryRouter, Outlet, RouterProvider } from 'react-router-dom'
import { beforeEach, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import CreateEventPage from './CreateEventPage'
vi.mock('../../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn(), post: vi.fn() } }))
import DraftNavigationProvider from '../../components/DraftNavigationProvider'
import userEvent from '@testing-library/user-event'
vi.mock('../../hooks/useEventCategories', () => ({ default: () => [] }))
function mount() { return render(<MemoryRouter initialEntries={['/dashboard/events/new']}><CreateEventPage /></MemoryRouter>) }
beforeEach(() => { vi.clearAllMocks(); window.sessionStorage.clear(); window.localStorage.clear() })
it('denies direct creation to staff with a dashboard recovery link and no form', async () => {
  apiClient.get.mockResolvedValue({ data: { permissions: { manage_events: false } } })
  mount()
  await screen.findByText(/does not include creating events/)
  expect(screen.getByRole('link', { name: 'Back to dashboard' })).toHaveAttribute('href', '/dashboard')
  expect(screen.queryByLabelText(/Event Title/)).not.toBeInTheDocument()
  expect(apiClient.post).not.toHaveBeenCalled()
})
it('preserves permitted creation and fails closed when confirmation is unavailable', async () => {
  apiClient.get.mockResolvedValue({ data: { permissions: { manage_events: true } } })
  const view = mount()
  await screen.findByRole('heading', { name: 'Create New Event' })
  view.unmount()
  apiClient.get.mockRejectedValue(new Error('Unavailable'))
  mount()
  await screen.findByText(/Could not confirm event creation access/)
  expect(screen.queryByLabelText(/Event Title/)).not.toBeInTheDocument()
})

it('connects validation errors, focuses the first invalid field and keeps entered details on API failure', async () => {
  apiClient.get.mockResolvedValue({ data: { permissions: { manage_events: true } } })
  apiClient.post.mockRejectedValue(new Error('Offline'))
  const user = userEvent.setup()
  mount()
  await user.click(await screen.findByRole('button', { name: 'Create Event' }))
  expect(screen.getByRole('alert')).toHaveTextContent('Check the event details')
  await waitFor(() => expect(screen.getByLabelText(/Event Title/)).toHaveFocus())
  for (const id of ['title', 'venue_name', 'starts_at']) {
    expect(document.getElementById(id)).toHaveAttribute('aria-invalid', 'true')
    expect(document.getElementById(id)).toHaveAttribute('aria-describedby', `${id}-error`)
  }
  await user.click(screen.getByRole('link', { name: 'Venue name is required' }))
  expect(screen.getByLabelText(/Venue Name/)).toHaveFocus()
  await user.type(screen.getByLabelText(/Event Title/), 'Recoverable event')
  await user.type(screen.getByLabelText(/Venue Name/), 'Guam')
  fireEvent.change(screen.getByLabelText(/Start Date/), { target: { value: '2099-10-20T17:00' } })
  await user.click(screen.getByRole('button', { name: 'Create Event' }))
  await screen.findByText('Failed to create event')
  expect(screen.getByLabelText(/Event Title/)).toHaveValue('Recoverable event')
})

it('blocks shared departure, recovers a new draft on return, and clears recovery after successful creation', async () => {
  apiClient.get.mockResolvedValue({ data: { permissions: { manage_events: true } } })
  apiClient.post.mockResolvedValue({ data: { id: 99 } })
  const router = createMemoryRouter([{ element: <DraftNavigationProvider><Outlet /></DraftNavigationProvider>, children: [
    { path: '/dashboard/events/new', element: <CreateEventPage /> },
    { path: '/dashboard', element: <Link to="/dashboard/events/new">New event</Link> },
    { path: '/dashboard/events/99/edit', element: <p>Created event editor</p> },
  ] }], { initialEntries: ['/dashboard/events/new'] })
  const user = userEvent.setup()
  render(<RouterProvider router={router} />)
  await user.type(await screen.findByLabelText(/Event Title/), 'Recovered new event')
  await user.click(screen.getByRole('link', { name: 'Back to Dashboard' }))
  await user.click(screen.getByRole('button', { name: 'Stay and save' }))
  expect(screen.getByLabelText(/Event Title/)).toHaveValue('Recovered new event')
  await user.click(screen.getByRole('link', { name: 'Back to Dashboard' }))
  await user.click(screen.getByRole('button', { name: 'Leave without saving' }))
  await user.click(screen.getByRole('link', { name: 'New event' }))
  expect(await screen.findByLabelText(/Event Title/)).toHaveValue('Recovered new event')
  expect(screen.getByRole('status')).toHaveTextContent('restored')
  await user.type(screen.getByLabelText(/Venue Name/), 'Venue')
  fireEvent.change(screen.getByLabelText(/Start Date/), { target: { value: '2099-10-20T17:00' } })
  await user.click(screen.getByRole('button', { name: 'Create Event' }))
  await screen.findByText('Created event editor')
  expect(window.sessionStorage.length).toBe(0)
  expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
})

it('recovers the verified default organization draft after dashboard selection becomes explicit', async () => {
  apiClient.get.mockResolvedValue({ data: { id: 7, permissions: { manage_events: true } } })
  const user = userEvent.setup()
  const first = mount()
  await user.type(await screen.findByLabelText(/Event Title/), 'Default organization draft')
  first.unmount()
  window.localStorage.setItem('hafapass_organization_id', '7')
  const second = mount()
  expect(await screen.findByLabelText(/Event Title/)).toHaveValue('Default organization draft')
  second.unmount()
  window.localStorage.setItem('hafapass_organization_id', '8')
  apiClient.get.mockResolvedValue({ data: { id: 8, permissions: { manage_events: true } } })
  mount()
  expect(await screen.findByLabelText(/Event Title/)).toHaveValue('')
})
