import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import DashboardPage from './DashboardPage'

vi.mock('../../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn(), post: vi.fn(), put: vi.fn() } }))
const scanner = { id: 2, name: 'Door team', role: 'scanner', permissions: { manage_events: false, manage_organization: false } }
const owner = { id: 1, name: 'Island events', role: 'owner', permissions: { manage_events: true, manage_organization: true, manage_members: true } }
const event = { id: 42, title: 'Assigned night market', status: 'published', starts_at: '2026-10-16T09:00:00Z', timezone: 'Pacific/Guam', permissions: { scan: true } }
function mount() { return render(<MemoryRouter initialEntries={['/dashboard']}><DashboardPage /></MemoryRouter>) }
function fixtures(organizations = [scanner], events = [event], summary = { upcoming_events_count: 1, tickets_sold: 0, next_event: null }) {
  apiClient.get.mockImplementation(path => {
    if (path === '/organizer/events/summary') return summary instanceof Promise ? summary : Promise.resolve({ data: summary })
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
    expect(screen.getByRole('link', { name: 'Scan tickets' })).toBeInTheDocument()
    for (const name of ['Create event', 'Settings']) expect(screen.queryByRole('link', { name })).not.toBeInTheDocument()
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
    await screen.findByRole('link', { name: 'Create event' })
    expect(screen.getByRole('button', { name: 'Accept policy' })).toBeInTheDocument()
    await userEvent.setup().selectOptions(screen.getByLabelText('Organization'), '2')
    await waitFor(() => expect(screen.queryByRole('link', { name: 'Create event' })).not.toBeInTheDocument())
    expect(window.localStorage.getItem('hafapass_organization_id')).toBe('2')
    expect(screen.queryByTitle('Edit Profile')).not.toBeInTheDocument()
  })
  it('asks for re-acceptance in a dialog with what changed instead of a browser confirm', async () => {
    window.localStorage.setItem('hafapass_organization_id', '1')
    fixtures([owner])
    const normalGet = apiClient.get.getMockImplementation()
    const stale = { business_name: 'Island events', verification_status: 'verified', policy_accepted: false,
      policy_version: '2026-07-pilot-draft', current_policy_version: '2026-10-launch-draft' }
    apiClient.get.mockImplementation(path => path === '/organizer_profile' ? Promise.resolve({ data: stale }) : normalGet(path))
    apiClient.post.mockResolvedValue({ data: { ...stale, policy_accepted: true, policy_version: '2026-10-launch-draft' } })
    const confirm = vi.spyOn(window, 'confirm')
    mount()
    expect(await screen.findByTestId('agreement-update-notice')).toHaveTextContent('updated to version 2026-10-launch-draft')
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Review and accept' }))
    const dialog = screen.getByRole('dialog', { name: 'Review the updated organizer agreement' })
    expect(dialog).toHaveTextContent('all-in ticket prices')
    expect(dialog).toHaveTextContent('named as the seller')
    expect(screen.getByRole('link', { name: 'Read the full organizer agreement' })).toHaveAttribute('href', '/policies/organizer-agreement')
    await user.click(screen.getByRole('button', { name: 'Accept version 2026-10-launch-draft' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/organizer_profile/accept_policy', {}, expect.anything()))
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
    expect(screen.queryByTestId('agreement-update-notice')).not.toBeInTheDocument()
    expect(confirm).not.toHaveBeenCalled()
    confirm.mockRestore()
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
    expect(await screen.findByRole('link', { name: /Assigned night market.*Open event/ })).toHaveAttribute('href', '/dashboard/events/42')
    expect(screen.queryByRole('link', { name: 'Create event' })).not.toBeInTheDocument()
  })
  it('keeps content editors without event management on the editor', async () => {
    fixtures([scanner], [{ ...event, permissions: { edit_event_content: true } }])
    mount()
    expect(await screen.findByRole('link', { name: /Assigned night market.*Edit event/ })).toHaveAttribute('href', '/dashboard/events/42/edit')
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
    expect(apiClient.get.mock.calls.some(([path]) => path === '/organizer/events')).toBe(false)
  })
})

describe('dashboard summary', () => {
  it('shows a loading placeholder until organization totals arrive', async () => {
    let resolve
    fixtures([owner], [event], new Promise(done => { resolve = done }))
    mount()
    expect(await screen.findByText('Loading summary…')).toBeInTheDocument()
    resolve({ data: { upcoming_events_count: 3, tickets_sold: 120, revenue_cents: 123450, next_event: { id: 42, title: 'Assigned night market', starts_at: '2026-10-16T09:00:00Z', timezone: 'Pacific/Guam' } } })
    const summary = await screen.findByRole('region', { name: 'Summary' })
    expect(summary).toHaveTextContent('Upcoming events3')
    expect(summary).toHaveTextContent('Tickets sold120')
    expect(summary).toHaveTextContent('Revenue$1,234.50')
    // The date is shown in the event's own timezone (Oct 16 19:00 in Guam).
    expect(summary).toHaveTextContent('Next eventOct 16, 2026Assigned night market')
  })
  it('shows zero totals and no next event for a new organization', async () => {
    fixtures([owner], [], { upcoming_events_count: 0, tickets_sold: 0, revenue_cents: 0, next_event: null })
    mount()
    const summary = await screen.findByRole('region', { name: 'Summary' })
    expect(summary).toHaveTextContent('Upcoming events0')
    expect(summary).toHaveTextContent('Revenue$0.00')
    expect(summary).toHaveTextContent('None scheduled')
  })
  it('omits revenue when the API withholds it from staff without finance access', async () => {
    fixtures([scanner], [event], { upcoming_events_count: 1, tickets_sold: 4, next_event: null })
    mount()
    const summary = await screen.findByRole('region', { name: 'Summary' })
    expect(summary).toHaveTextContent('Tickets sold4')
    expect(summary).not.toHaveTextContent('Revenue')
  })
  it('keeps the event list usable and offers a retry when totals fail', async () => {
    fixtures([owner], [event], Promise.reject(new Error('Synthetic outage')))
    mount()
    expect(await screen.findByText('Your summary is unavailable right now.')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: /Assigned night market/ })).toBeInTheDocument()
    fixtures([owner], [event], { upcoming_events_count: 2, tickets_sold: 9, next_event: null })
    await userEvent.setup().click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByRole('region', { name: 'Summary' })).toHaveTextContent('Upcoming events2')
  })
})
