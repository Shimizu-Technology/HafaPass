import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import DashboardPage from './DashboardPage'

vi.mock('../../api/client', () => ({ default: { get: vi.fn(), post: vi.fn(), put: vi.fn() } }))
const scanner = { id: 2, name: 'Door team', role: 'scanner', permissions: { manage_events: false, manage_organization: false } }
const owner = { id: 1, name: 'Island events', role: 'owner', permissions: { manage_events: true, manage_organization: true, manage_members: true } }
const event = { id: 42, title: 'Assigned night market', status: 'published', starts_at: '2026-10-16T09:00:00Z', timezone: 'Pacific/Guam', permissions: { scan: true } }
function mount() { return render(<MemoryRouter><DashboardPage /></MemoryRouter>) }
function fixtures(organizations = [scanner], events = [event]) {
  apiClient.get.mockImplementation(path => {
    if (path === '/organizer/organizations') return Promise.resolve({ data: organizations })
    if (path === '/organizer_profile') return Promise.resolve({ data: { business_name: 'Door team', verification_status: 'unverified' } })
    if (path === '/organizer/events') return Promise.resolve({ data: { events } })
    throw new Error(`Unexpected ${path}`)
  })
}
beforeEach(() => { vi.clearAllMocks(); window.localStorage.clear() })
describe('staff dashboard entry', () => {
  it('opens the clicked scanner event and hides unrelated organizer controls', async () => {
    fixtures()
    mount()
    const link = await screen.findByRole('link', { name: /Assigned night market/ })
    expect(link).toHaveAttribute('href', '/dashboard/scanner?event=42')
    expect(screen.getByRole('link', { name: 'Scan Tickets' })).toBeInTheDocument()
    for (const name of ['Create Event', 'Settings']) expect(screen.queryByRole('link', { name })).not.toBeInTheDocument()
    expect(screen.queryByTitle('Edit Profile')).not.toBeInTheDocument()
    expect(screen.queryByText('Organizer readiness')).not.toBeInTheDocument()
    expect(screen.queryByText('Accept policy')).not.toBeInTheDocument()
  })
  it('offers assignment recovery instead of creation for an empty staff list', async () => {
    fixtures([scanner], [])
    mount()
    await screen.findByText('No assigned events')
    expect(screen.getByText('Ask your event manager to assign an event to you.')).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Create Your First Event' })).not.toBeInTheDocument()
  })
  it('retains owner setup and replaces it when switching to scanner context', async () => {
    window.localStorage.setItem('hafapass_organization_id', '1')
    fixtures([owner, scanner])
    mount()
    await screen.findByRole('link', { name: 'Create Event' })
    expect(screen.getByRole('button', { name: 'Accept policy' })).toBeInTheDocument()
    await userEvent.setup().selectOptions(screen.getByLabelText('Organization'), '2')
    await waitFor(() => expect(screen.queryByRole('link', { name: 'Create Event' })).not.toBeInTheDocument())
    expect(window.localStorage.getItem('hafapass_organization_id')).toBe('2')
    expect(screen.queryByTitle('Edit Profile')).not.toBeInTheDocument()
  })
  it('shows safe recovery for an existing owner organization without provisioning another organization', async () => {
    fixtures([owner], [])
    const normalGet = apiClient.get.getMockImplementation()
    apiClient.get.mockImplementation(path => path === '/organizer_profile' ? Promise.reject({ response: { status: 404 } }) : normalGet(path))
    mount()
    await screen.findByText(/Organizer setup is unavailable for this organization/)
    expect(screen.queryByRole('button', { name: 'Create Organizer Profile' })).not.toBeInTheDocument()
    expect(apiClient.post).not.toHaveBeenCalled()
  })
  it('preserves first-time organizer setup when there are no organizations', async () => {
    fixtures([], [])
    const normalGet = apiClient.get.getMockImplementation()
    apiClient.get.mockImplementation(path => path === '/organizer_profile' ? Promise.reject({ response: { status: 404 } }) : normalGet(path))
    mount()
    await screen.findByRole('heading', { name: 'Create Your Organizer Profile' })
  })
  it('uses effective event permissions for a manager assignment without allowing organization creation', async () => {
    fixtures([scanner], [{ ...event, permissions: { scan: true, edit_event_content: true, manage_events: true } }])
    mount()
    expect(await screen.findByRole('link', { name: /Assigned night market/ })).toHaveAttribute('href', '/dashboard/events/42/edit')
    expect(screen.queryByRole('link', { name: 'Create Event' })).not.toBeInTheDocument()
  })
  it('does not apply a profile response after the selected organization changes externally', async () => {
    let resolveProfile
    fixtures([owner, scanner])
    const normalGet = apiClient.get.getMockImplementation()
    apiClient.get.mockImplementation(path => path === '/organizer_profile' ? new Promise(resolve => { resolveProfile = resolve }) : normalGet(path))
    mount()
    await waitFor(() => expect(resolveProfile).toBeDefined())
    window.localStorage.setItem('hafapass_organization_id', '2')
    resolveProfile({ data: { business_name: 'Stale owner profile' } })
    await waitFor(() => expect(screen.queryByText('Welcome, Stale owner profile')).not.toBeInTheDocument())
    expect(apiClient.get).not.toHaveBeenCalledWith('/organizer/events')
  })
})
