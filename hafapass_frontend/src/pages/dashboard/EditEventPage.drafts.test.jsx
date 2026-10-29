import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import EditEventPage from './EditEventPage'

vi.mock('../../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn(), put: vi.fn(), post: vi.fn(), delete: vi.fn() } }))
vi.mock('../../hooks/usePlatformFeeTerms', () => ({ default: () => ({ status: 'ready', retry: () => {}, terms: { percent: 5, flatCents: 100, bearer: 'platform', payoutScheduleText: 'within 3 to 5 business days after your event' } }) }))
vi.mock('../../components/CoverImageUpload', () => ({ default: () => null }))
vi.mock('../../components/PricingTiersCRUD', () => ({ default: () => null }))
vi.mock('../../hooks/useEventCategories', () => ({ default: () => [{ value: 'other', label: 'Other' }] }))
vi.mock('../../hooks/useLaunchCapabilities', () => ({ default: () => ({}) }))

const ticket = { id: 1, name: 'Admission', price_cents: 1250, quantity_available: 20 }
const event = { id: 37, title: 'Saved title', description: 'Saved description', status: 'published',
  venue_name: 'Synthetic venue', timezone: 'Pacific/Guam', category: 'other', age_restriction: 'all_ages',
  starts_at: '2026-10-16T09:00:42.123Z', ends_at: '2026-10-16T12:00:42.123Z', max_capacity: 50,
  permissions: { edit_event_content: true, manage_events: true, manage_inventory: true }, ticket_types: [ticket] }
const deferred = () => { let resolve; const promise = new Promise(yes => { resolve = yes }); return { promise, resolve } }
const mount = () => render(<MemoryRouter initialEntries={['/dashboard/events/37/edit']}><Routes>
  <Route path="/dashboard/events/:id/edit" element={<EditEventPage />} />
  <Route path="/dashboard/events/:id/:tool" element={<p>Tool destination</p>} />
</Routes></MemoryRouter>)
beforeEach(() => {
  vi.clearAllMocks()
  for (const method of ['get', 'put', 'post', 'delete']) apiClient[method].mockReset()
  apiClient.get.mockResolvedValue({ data: event })
  apiClient.put.mockResolvedValue({ data: event })
  apiClient.post.mockResolvedValue({ data: ticket })
  apiClient.delete.mockResolvedValue({})
})

describe('ticket changes alongside an unsaved event draft', () => {
  it.each(['create', 'update', 'delete'])('preserves the draft and mounted editor during a pending %s refresh', async action => {
    const refresh = deferred()
    let eventLoads = 0
    apiClient.get.mockImplementation(path => path === '/organizer/organizations'
      ? Promise.resolve({ data: [] })
      : ++eventLoads === 1 ? Promise.resolve({ data: event }) : refresh.promise)
    const user = userEvent.setup()
    mount()
    const title = await screen.findByLabelText(/Event Title/)
    await user.clear(title); await user.type(title, 'Unsaved local title')
    await user.clear(screen.getByLabelText('Description')); await user.type(screen.getByLabelText('Description'), 'Unsaved local description')
    if (action === 'create') {
      await user.click(screen.getByRole('button', { name: 'Add Ticket Type' }))
      await user.type(screen.getByLabelText(/^Name/), 'Added admission')
      expect(screen.getByLabelText(/Tickets available/)).toHaveValue(30)
      await user.click(screen.getByRole('button', { name: 'Add Ticket Type', exact: true }))
    } else if (action === 'update') {
      await user.click(screen.getByRole('button', { name: 'Edit Admission' }))
      await user.clear(screen.getByLabelText(/^Name/)); await user.type(screen.getByLabelText(/^Name/), 'Updated admission')
      await user.click(screen.getByRole('button', { name: 'Update', exact: true }))
    } else {
      await user.click(screen.getByRole('button', { name: 'Delete Admission' }))
      await user.click(screen.getByRole('button', { name: 'Yes', exact: true }))
    }
    await screen.findByText('Updating ticket list…')
    expect(screen.getByLabelText(/Event Title/)).toBe(title)
    expect(title).toHaveValue('Unsaved local title')
    await user.type(screen.getByLabelText('Description'), ' during refresh')
    const ticketTypes = action === 'delete' ? [] : [{ ...ticket, name: action === 'create' ? 'Added admission' : 'Updated admission' }]
    await act(async () => refresh.resolve({ data: { ...event, title: 'Old server title', ticket_types: ticketTypes } }))
    expect(title).toHaveValue('Unsaved local title')
    expect(screen.getByLabelText('Description')).toHaveValue('Unsaved local description during refresh')
    if (action === 'delete') expect(screen.queryByRole('button', { name: 'Edit Admission' })).not.toBeInTheDocument()
    else expect(screen.getByRole('button', { name: `Edit ${ticketTypes[0].name}` })).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Event updated successfully.')
    const payload = apiClient.put.mock.calls.find(([path]) => path === '/organizer/events/37')[1]
    expect(payload).toMatchObject({ title: 'Unsaved local title', description: 'Unsaved local description during refresh' })
    expect(payload).not.toHaveProperty('starts_at')
    expect(payload).not.toHaveProperty('ends_at')
  })

  it('retains the draft/list on refresh failure and retries without repeating the mutation', async () => {
    let eventLoads = 0
    apiClient.get.mockImplementation(path => {
      if (path === '/organizer/organizations') return Promise.resolve({ data: [] })
      eventLoads += 1
      if (eventLoads === 1) return Promise.resolve({ data: event })
      if (eventLoads === 2) return Promise.reject(new Error('Synthetic outage'))
      return Promise.resolve({ data: { ...event, ticket_types: [] } })
    })
    const user = userEvent.setup()
    mount()
    await user.type(await screen.findByLabelText(/Event Title/), ' unsaved')
    await user.click(screen.getByRole('button', { name: 'Delete Admission' }))
    await user.click(screen.getByRole('button', { name: 'Yes', exact: true }))
    await screen.findByRole('alert')
    expect(screen.getByLabelText(/Event Title/)).toHaveValue('Saved title unsaved')
    expect(screen.getByRole('button', { name: 'Edit Admission' })).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Retry ticket list' }))
    await waitFor(() => expect(screen.queryByRole('alert')).not.toBeInTheDocument())
    expect(screen.getByLabelText(/Event Title/)).toHaveValue('Saved title unsaved')
    expect(apiClient.delete).toHaveBeenCalledTimes(1)
    expect(screen.queryByRole('button', { name: 'Edit Admission' })).not.toBeInTheDocument()
  })
})

describe('event tool navigation follows server permissions', () => {
  it.each([
    ['manager', { edit_event_content: true, manage_attendees: true, manage_marketing: true }, ['Guest list', 'Promo codes']],
    ['finance', { view_finance: true, refund: true }, ['Refunds']],
    ['marketer', { edit_event_content: true, manage_marketing: true }, ['Promo codes']],
    ['box office', { box_office: true, manage_attendees: true }, ['Guest list']],
    ['scanner', { scan: true }, []],
    ['finance reader', { view_finance: true }, []],
    ['unscoped refund', { refund: true }, []],
  ])('shows the appropriate tools for %s access', async (_role, permissions, visible) => {
    apiClient.get.mockResolvedValue({ data: { ...event, permissions } })
    mount()
    if (permissions.edit_event_content) await screen.findByRole('button', { name: 'Save Changes' })
    else await screen.findByRole('status')
    for (const [name, path] of Object.entries({ 'Guest list': 'guest-list', 'Promo codes': 'promo-codes', Refunds: 'refunds' })) {
      if (visible.includes(name)) expect(screen.getByRole('link', { name, exact: true })).toHaveAttribute('href', `/dashboard/events/37/${path}`)
      else expect(screen.queryByRole('link', { name, exact: true })).not.toBeInTheDocument()
    }
  })
  it('guards actual dirty editor navigation and clears the guard after a saved response', async () => {
    apiClient.get.mockImplementation(path => Promise.resolve({ data: path === '/organizer/organizations' ? []
      : { ...event, permissions: { ...event.permissions, manage_marketing: true } } }))
    apiClient.put.mockImplementation((_path, payload) => Promise.resolve({ data: { ...event, ...payload,
      permissions: { ...event.permissions, manage_marketing: true } } }))
    mount()
    await userEvent.type(await screen.findByLabelText(/Event Title/), ' unsaved')
    await userEvent.click(screen.getByRole('link', { name: 'Promo codes', exact: true }))
    expect(screen.getByRole('dialog', { name: 'Leave unsaved event changes?' })).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Stay and save' }))
    expect(screen.getByLabelText(/Event Title/)).toHaveValue('Saved title unsaved')
    await userEvent.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Event updated successfully.')
    await userEvent.click(screen.getByRole('link', { name: 'Promo codes', exact: true }))
    expect(screen.getByText('Tool destination')).toBeInTheDocument()
  })

  it('opens a tool through its organizer link', async () => {
    apiClient.get.mockResolvedValue({ data: { ...event, permissions: { edit_event_content: true, manage_marketing: true } } })
    mount()
    await userEvent.click(await screen.findByRole('link', { name: 'Promo codes', exact: true }))
    expect(screen.getByText('Tool destination')).toBeInTheDocument()
  })
})
