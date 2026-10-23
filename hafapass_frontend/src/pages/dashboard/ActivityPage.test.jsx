import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import ActivityPage from './ActivityPage'
import { activityDay, activityPath } from '../../utils/activity'

vi.mock('../../api/client', async original => ({ ...await original(), default: { get: vi.fn(), post: vi.fn() } }))

const organization = { id: 7, name: 'Island Events', role: 'owner', permissions: { manage_members: true, view_activity_all: true } }
const entry = { id: 31, occurred_at: '2026-10-23T18:00:00Z', sentence: 'Updated the ticket price.', area: 'tickets', outcome: 'succeeded', actor: { name: 'Island Owner' },
  event: { id: 4, title: 'Reef Night', url: '/dashboard/events/4' }, changes: [{ field: 'Price', before: '$20', after: '$25' }] }
const response = (rows = [entry], meta = {}) => ({ activity_logs: rows, meta: { activity_logging_started_at: '2026-10-22', ...meta },
  filters: { actors: [{ id: 1, name: 'Island Owner' }], areas: ['tickets'], events: [{ id: 4, title: 'Reef Night' }] } })
const mount = (query = '') => render(<MemoryRouter initialEntries={[`/dashboard/settings/activity${query}`]}><ActivityPage /></MemoryRouter>)
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done }); return { promise, resolve } }

beforeEach(() => {
  vi.clearAllMocks()
  window.localStorage.clear()
  window.localStorage.setItem('hafapass_organization_id', '7')
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path === '/organizer/organization' ? organization : response() }))
})

describe('organization activity', () => {
  it('shows the marker, readable timeline, event link and changed fields', async () => {
    const user = userEvent.setup()
    mount('?event_id=4')
    expect(await screen.findByText(entry.sentence)).toBeInTheDocument()
    expect(screen.getByText('Activity is recorded from Oct 22, 2026. Earlier changes aren’t shown.')).toBeInTheDocument()
    expect(screen.getByText('Island Owner · tickets')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Reef Night' })).toHaveAttribute('href', '/dashboard/events/4')
    expect(screen.queryByText('succeeded')).not.toBeInTheDocument()
    await user.click(screen.getByText('Details'))
    expect(screen.getByRole('heading', { name: 'What changed' })).toBeInTheDocument()
    expect(screen.getByText('Before: $20')).toBeInTheDocument()
    expect(screen.getByText('After: $25')).toBeInTheDocument()
    expect(apiClient.get).toHaveBeenCalledWith('/organizer/activity_logs', expect.objectContaining({ organizationId: '7', params: { event_id: '4', limit: 50 } }))
  })

  it.each(['owner', 'manager', 'finance'])('allows %s with an activity permission', async role => {
    apiClient.get.mockImplementation(path => Promise.resolve({ data: path === '/organizer/organization' ? { ...organization, role, permissions: { view_activity_finance: true } } : response() }))
    mount()
    expect(await screen.findByText(entry.sentence)).toBeInTheDocument()
  })

  it.each([
    { ...organization, role: 'scanner', permissions: { scan: true } }, { ...organization, role: 'box_office', permissions: { box_office: true } }, { ...organization, permissions: { manage_members: true } },
  ])('does not request private activity without an activity audience (%j)', async org => {
    apiClient.get.mockResolvedValue({ data: org })
    mount()
    expect(await screen.findByText('Activity is not available for your role')).toBeInTheDocument()
    expect(apiClient.get.mock.calls.some(([path]) => path === '/organizer/activity_logs')).toBe(false)
    expect(screen.queryByRole('button', { name: 'Download CSV' })).not.toBeInTheDocument()
  })

  it('allows an event-assigned manager through the explicit activity audience flag', async () => {
    apiClient.get.mockImplementation(path => Promise.resolve({ data: path === '/organizer/organization'
      ? { ...organization, role: 'marketer', activity_access: true, permissions: { manage_marketing: true } } : response() }))
    mount('?event_id=4')
    expect(await screen.findByText(entry.sentence)).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Activity' })).toHaveAttribute('aria-current', 'page')
    expect(screen.queryByRole('link', { name: 'Team & payouts' })).not.toBeInTheDocument()
  })

  it('shows loading, empty and a recoverable error while preserving filters', async () => {
    const user = userEvent.setup()
    const pending = deferred()
    apiClient.get.mockImplementation(path => path === '/organizer/organization' ? Promise.resolve({ data: organization }) : pending.promise)
    mount('?event_id=4')
    expect(screen.getByRole('status')).toHaveTextContent('Loading activity')
    await act(async () => pending.resolve({ data: response([]) }))
    expect(await screen.findByText('No activity matches these filters.')).toBeInTheDocument()
    apiClient.get.mockRejectedValueOnce(new Error('Offline'))
    await user.click(screen.getByRole('button', { name: 'Clear all filters' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Your filters have been kept')
    apiClient.get.mockImplementation(path => Promise.resolve({ data: path === '/organizer/organization' ? organization : response([]) }))
    await user.click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByText('No activity yet')).toBeInTheDocument()
  })

  it('loads more with the same exact filters, and clears filters', async () => {
    const user = userEvent.setup()
    apiClient.get.mockImplementation((path, config) => Promise.resolve({ data: path === '/organizer/organization' ? organization
      : config.params.cursor ? response([{ ...entry, id: 32, sentence: 'Invited a teammate.' }]) : response([entry], { next_cursor: 'next-31' }) }))
    mount('?event_id=4&area=tickets')
    await user.click(await screen.findByRole('button', { name: 'Load more' }))
    expect(await screen.findByText('Invited a teammate.')).toBeInTheDocument()
    expect(screen.getByText(entry.sentence)).toBeInTheDocument()
    expect(apiClient.get).toHaveBeenLastCalledWith('/organizer/activity_logs', expect.objectContaining({ params: { area: 'tickets', event_id: '4', limit: 50, cursor: 'next-31' } }))
    await user.click(screen.getByRole('button', { name: 'Clear all filters' }))
    await waitFor(() => expect(apiClient.get).toHaveBeenLastCalledWith('/organizer/activity_logs', expect.objectContaining({ params: { limit: 50 } })))
  })

  it('drops rows and CSV access after a denied retry', async () => {
    const user = userEvent.setup()
    mount()
    await screen.findByText(entry.sentence)
    apiClient.get.mockRejectedValue({ response: { status: 403 } })
    await user.selectOptions(screen.getByLabelText('Area'), 'tickets')
    expect(await screen.findByText('Activity is not available for your role')).toBeInTheDocument()
    expect(screen.queryByText(entry.sentence)).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Download CSV' })).not.toBeInTheDocument()
  })

  it('ignores an older filter response that arrives after the newer response', async () => {
    const user = userEvent.setup()
    const old = deferred()
    apiClient.get.mockImplementation((path, config) => path === '/organizer/organization' ? Promise.resolve({ data: organization })
      : config.params.q ? Promise.resolve({ data: response([{ ...entry, sentence: 'Newer result.' }]) }) : old.promise)
    mount()
    await user.type(screen.getByRole('searchbox', { name: 'Search activity' }), 'newer')
    // The search is disabled during initial loading; finish the first read,
    // then make a slow filter read followed by a faster one.
    await act(async () => old.resolve({ data: response() }))
    const slow = deferred()
    apiClient.get.mockImplementation((path, config) => path === '/organizer/organization' ? Promise.resolve({ data: organization })
      : config.params.area ? slow.promise : Promise.resolve({ data: response([{ ...entry, sentence: 'Newer result.' }]) }))
    await user.selectOptions(screen.getByLabelText('Area'), 'tickets')
    await user.click(screen.getByRole('button', { name: 'Clear all filters' }))
    expect(await screen.findByText('Newer result.')).toBeInTheDocument()
    await act(async () => slow.resolve({ data: response([{ ...entry, sentence: 'Stale result.' }]) }))
    expect(screen.queryByText('Stale result.')).not.toBeInTheDocument()
  })

  it('does not display a response after organization selection changes', async () => {
    const pending = deferred()
    apiClient.get.mockImplementation(path => path === '/organizer/organization' ? Promise.resolve({ data: organization }) : pending.promise)
    mount()
    await waitFor(() => expect(apiClient.get).toHaveBeenCalledWith('/organizer/activity_logs', expect.anything()))
    await act(async () => {
      window.localStorage.setItem('hafapass_organization_id', '8')
      window.dispatchEvent(new StorageEvent('storage', { key: 'hafapass_organization_id' }))
      pending.resolve({ data: response() })
    })
    expect(screen.queryByText(entry.sentence)).not.toBeInTheDocument()
  })
})

it('groups days by Guam calendar dates around UTC midnight', () => {
  const now = new Date('2026-10-24T01:00:00Z')
  expect(activityDay('2026-10-23T18:00:00Z', now)).toBe('Today')
  expect(activityDay('2026-10-22T18:00:00Z', now)).toBe('Yesterday')
  expect(activityDay('2026-10-21T18:00:00Z', now)).toBe('Oct 22')
})

it('accepts internal record paths and rejects unsafe links', () => {
  expect(activityPath('/dashboard/events/4')).toBe('/dashboard/events/4')
  for (const path of ['javascript:alert(1)', '//outside.test', '/\\outside.test', 'https://outside.test']) expect(activityPath(path)).toBeNull()
})
