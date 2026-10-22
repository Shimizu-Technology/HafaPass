import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Link, MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { getApiAuthContext, setAuthTokenGetter } from '../../api/client'
import EditEventPage from './EditEventPage'

const uploads = vi.hoisted(() => new Map())
vi.mock('../../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn(), put: vi.fn(), post: vi.fn(), delete: vi.fn() } }))
vi.mock('../../hooks/usePlatformFeeTerms', () => ({ default: () => ({ status: 'ready', retry: () => {}, terms: { percent: 5, flatCents: 100, bearer: 'platform', payoutScheduleText: 'within 3 business days after your event' } }) }))
vi.mock('../../components/CoverImageUpload', () => ({ default: ({ eventId, onUploaded }) => { uploads.set(String(eventId), onUploaded); return <p>Cover image control</p> } }))
vi.mock('../../components/TicketTypeCRUD', () => ({ default: ({ onRefresh, ticketTypes }) => <div><button type="button" onClick={onRefresh}>Refresh saved inventory</button>{ticketTypes.map(ticket => <p key={ticket.id}>{ticket.name}</p>)}</div> }))
vi.mock('../../hooks/useEventCategories', () => ({ default: () => [{ value: 'other', label: 'Other' }] }))
vi.mock('../../hooks/useLaunchCapabilities', () => ({ default: () => ({}) }))

const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no }); return { promise, resolve, reject } }
const dto = id => ({ id, title: id === 11 ? 'Alpha event' : 'Beta event', status: 'draft', venue_name: 'Synthetic venue',
  starts_at: '2026-11-20T07:00:00Z', timezone: 'Pacific/Guam', category: 'other', age_restriction: 'all_ages', ticket_types: [],
  permissions: { edit_event_content: true, manage_events: true, manage_inventory: true }, publish_checklist: [] })
const Location = () => <p data-testid="editor-location">{useLocation().pathname}</p>
const mount = () => render(<MemoryRouter initialEntries={['/dashboard/events/11/edit']}>
  <Link to="/dashboard/events/11/edit">Open Alpha</Link><Link to="/dashboard/events/22/edit">Open Beta</Link><Location />
  <Routes><Route path="/dashboard/events/:id/edit" element={<EditEventPage />} /><Route path="/dashboard" element={<p>Dashboard destination</p>} /></Routes>
</MemoryRouter>)
let rows, clearAuth
const bind = (userId, sessionId, getter = () => Promise.resolve('synthetic-token')) => {
  window.localStorage.setItem('hafapass_scanner_user_id', userId)
  clearAuth = setAuthTokenGetter(getter, { userId, sessionId, ready: true })
}
const beta = async () => { await userEvent.click(screen.getByRole('link', { name: 'Open Beta' })); await screen.findByDisplayValue(rows[22].title) }

beforeEach(() => {
  vi.clearAllMocks()
  for (const method of ['get', 'put', 'post', 'delete']) apiClient[method].mockReset()
  window.localStorage.clear(); uploads.clear()
  window.localStorage.setItem('hafapass_organization_id', '1')
  rows = { 11: dto(11), 22: dto(22) }
  apiClient.get.mockImplementation(path => Promise.resolve({ data: { ...rows[path.split('/').at(-1)] } }))
  apiClient.put.mockImplementation((path, payload) => Promise.resolve({ data: { id: Number(path.split('/').at(-1)), ...payload } }))
})
afterEach(() => { cleanup(); clearAuth?.(); clearAuth = null })

describe('event editor context ownership with the real router', () => {
  it.each(['success', 'error'])('clears a refused deletion while archiving and shows only the current %s result', async outcome => {
    const archive = deferred()
    const refusal = 'This event has saved history or related records and cannot be deleted. Archive it instead to keep those records.'
    apiClient.delete.mockRejectedValueOnce({ response: { data: { error: refusal } } })
    apiClient.post.mockReturnValueOnce(archive.promise)
    mount()
    await userEvent.click(await screen.findByRole('button', { name: 'Delete', exact: true }))
    await userEvent.click(screen.getByRole('button', { name: 'Yes, Delete', exact: true }))
    await screen.findByText(refusal)
    await userEvent.click(screen.getByRole('button', { name: 'Archive', exact: true }))
    expect(screen.queryByText(refusal)).not.toBeInTheDocument()
    expect(apiClient.post.mock.calls[0][0]).toBe('/organizer/events/11/archive')
    await act(async () => outcome === 'success'
      ? archive.resolve({ data: { ...rows[11], status: 'archived' } })
      : archive.reject({ response: { data: { error: 'Current archive failure' } } }))
    expect(screen.queryByText(refusal)).not.toBeInTheDocument()
    if (outcome === 'success') {
      expect(screen.getByText('Event archived.')).toBeInTheDocument()
      expect(screen.queryByRole('alert')).not.toBeInTheDocument()
      expect(screen.queryByRole('button', { name: 'Delete', exact: true })).not.toBeInTheDocument()
    } else {
      expect(screen.getByRole('alert')).toHaveTextContent('Current archive failure')
      expect(screen.queryByText('Event archived.')).not.toBeInTheDocument()
    }
  })

  it.each(['success', 'error'])('keeps Beta’s current refusal when an old Alpha archive finishes with %s', async outcome => {
    const oldArchive = deferred()
    apiClient.post.mockReturnValueOnce(oldArchive.promise)
    apiClient.delete.mockRejectedValueOnce({ response: { data: { error: 'Beta deletion refused' } } })
    mount()
    await userEvent.click(await screen.findByRole('button', { name: 'Archive', exact: true }))
    await beta()
    await userEvent.click(screen.getByRole('button', { name: 'Delete', exact: true }))
    await userEvent.click(screen.getByRole('button', { name: 'Yes, Delete', exact: true }))
    await screen.findByText('Beta deletion refused')
    await act(async () => outcome === 'success'
      ? oldArchive.resolve({ data: { ...rows[11], status: 'archived' } })
      : oldArchive.reject({ response: { data: { error: 'Old Alpha archive error' } } }))
    expect(screen.getByRole('alert')).toHaveTextContent('Beta deletion refused')
    expect(screen.getByLabelText(/Event Title/)).toHaveValue('Beta event')
    expect(screen.getByRole('button', { name: 'Archive', exact: true })).toBeEnabled()
    expect(screen.queryByText('Event archived.')).not.toBeInTheDocument()
    expect(screen.queryByText('Old Alpha archive error')).not.toBeInTheDocument()
  })

  it.each(['success', 'error'])('keeps Beta form fields when Alpha’s delayed load finishes with %s', async outcome => {
    const old = deferred()
    apiClient.get.mockImplementation(path => path.endsWith('/11') ? old.promise : Promise.resolve({ data: rows[22] }))
    mount()
    await waitFor(() => expect(apiClient.get).toHaveBeenCalled())
    await beta()
    await userEvent.clear(screen.getByLabelText(/Event Title/)); await userEvent.type(screen.getByLabelText(/Event Title/), 'Beta draft')
    await act(async () => outcome === 'success' ? old.resolve({ data: rows[11] }) : old.reject({ response: { status: 404 } }))
    if (outcome === 'error') expect(screen.getByLabelText(/Event Title/)).toHaveValue('Beta draft')
    await userEvent.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Event updated successfully.')
    expect(apiClient.put.mock.calls[0][0]).toBe('/organizer/events/22')
    expect(apiClient.put.mock.calls[0][1].title).toBe('Beta draft')
    expect(screen.getByLabelText(/Event Title/)).toHaveValue('Beta draft')
    expect(apiClient.put.mock.calls[0][2].organizationId).toBe('1')
  })

  it('does not clear Beta’s loading state when an old Alpha load completes', async () => {
    const old = deferred(), pendingBeta = deferred()
    apiClient.get.mockImplementation(path => path.endsWith('/11') ? old.promise : pendingBeta.promise)
    mount()
    await waitFor(() => expect(apiClient.get).toHaveBeenCalled())
    await userEvent.click(screen.getByRole('link', { name: 'Open Beta' }))
    await waitFor(() => expect(apiClient.get.mock.calls).toHaveLength(2))
    await act(async () => old.resolve({ data: rows[11] }))
    expect(screen.queryByLabelText(/Event Title/)).not.toBeInTheDocument()
    await act(async () => pendingBeta.resolve({ data: rows[22] }))
    expect(screen.getByLabelText(/Event Title/)).toHaveValue('Beta event')
  })

  it('does not revive a prior Alpha load after visiting Beta and returning', async () => {
    const old = deferred()
    apiClient.get.mockReturnValueOnce(old.promise).mockImplementation(path => Promise.resolve({ data: rows[path.split('/').at(-1)] }))
    mount()
    await waitFor(() => expect(apiClient.get).toHaveBeenCalled())
    await beta()
    rows[11] = { ...rows[11], title: 'Fresh Alpha visit' }
    await userEvent.click(screen.getByRole('link', { name: 'Open Alpha' }))
    await screen.findByDisplayValue('Fresh Alpha visit')
    await act(async () => old.resolve({ data: { ...dto(11), title: 'Stale Alpha visit' } }))
    expect(screen.getByLabelText(/Event Title/)).toHaveValue('Fresh Alpha visit')
  })

  it.each(['success', 'error'])('ignores Alpha save %s and finally while Beta is saving its own immutable body', async outcome => {
    const old = deferred(), current = deferred()
    apiClient.put.mockReturnValueOnce(old.promise).mockReturnValueOnce(current.promise)
    mount()
    await screen.findByDisplayValue('Alpha event')
    await userEvent.click(screen.getByRole('button', { name: 'Save Changes' }))
    await beta()
    await userEvent.clear(screen.getByLabelText(/Event Title/)); await userEvent.type(screen.getByLabelText(/Event Title/), 'Beta saved draft')
    await userEvent.click(screen.getByRole('button', { name: 'Save Changes' }))
    await act(async () => outcome === 'success' ? old.resolve({ data: rows[11] }) : old.reject(new Error('Old Alpha save error')))
    expect(screen.getByLabelText(/Event Title/)).toHaveValue('Beta saved draft')
    expect(screen.getByRole('button', { name: 'Saving...' })).toBeDisabled()
    expect(screen.queryByText('Event updated successfully.')).not.toBeInTheDocument()
    expect(apiClient.put.mock.calls[0][0]).toBe('/organizer/events/11')
    expect(apiClient.put.mock.calls[0][1].title).toBe('Alpha event')
    expect(apiClient.put.mock.calls[1][0]).toBe('/organizer/events/22')
    expect(apiClient.put.mock.calls[1][1].title).toBe('Beta saved draft')
    await act(async () => current.resolve({ data: { ...rows[22], title: 'Beta saved draft' } }))
    expect(screen.getByText('Event updated successfully.')).toBeInTheDocument()
  })

  it('rejects a cover callback belonging to the previous event editor', async () => {
    mount()
    await screen.findByDisplayValue('Alpha event')
    const oldUpload = uploads.get('11')
    await beta()
    await act(async () => oldUpload('https://synthetic.invalid/alpha-cover.png'))
    await userEvent.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Event updated successfully.')
    expect(apiClient.put.mock.calls[0][1].cover_image_url).toBeNull()
  })

  it('does not navigate Beta away when an old Alpha clone completes', async () => {
    const old = deferred()
    apiClient.post.mockReturnValueOnce(old.promise)
    mount()
    await userEvent.click(await screen.findByRole('button', { name: 'Clone', exact: true }))
    await beta()
    await act(async () => old.resolve({ data: { id: 99 } }))
    expect(screen.getByTestId('editor-location')).toHaveTextContent('/dashboard/events/22/edit')
    expect(screen.getByLabelText(/Event Title/)).toHaveValue('Beta event')
  })

  it.each(['session', 'account', 'organization', 'remount'])('ignores old editor loads across a %s replacement', async kind => {
    bind('actor-a', 'session-a')
    const old = deferred()
    apiClient.get.mockReturnValueOnce(old.promise).mockImplementation(path => Promise.resolve({ data: rows[path.split('/').at(-1)] }))
    const first = mount()
    await waitFor(() => expect(apiClient.get).toHaveBeenCalled())
    rows[11] = { ...rows[11], title: 'Fresh editor context' }
    if (kind === 'remount') { first.unmount(); mount() }
    else if (kind === 'organization') await act(async () => {
      window.localStorage.setItem('hafapass_organization_id', '2')
      window.dispatchEvent(new StorageEvent('storage', { key: 'hafapass_organization_id' }))
    })
    else await act(async () => bind(kind === 'account' ? 'actor-b' : 'actor-a', 'session-b'))
    await screen.findByDisplayValue('Fresh editor context')
    await act(async () => old.resolve({ data: { ...dto(11), title: 'Stale editor context' } }))
    expect(screen.getByLabelText(/Event Title/)).toHaveValue('Fresh editor context')
  })

  it.each(['success', 'error'])('ignores a pending Alpha inventory refresh %s after moving to Beta', async outcome => {
    const old = deferred()
    mount()
    await screen.findByDisplayValue('Alpha event')
    apiClient.get.mockReturnValueOnce(old.promise)
    await userEvent.click(screen.getByRole('button', { name: 'Refresh saved inventory' }))
    await screen.findByText('Updating ticket list…')
    await beta()
    await userEvent.type(screen.getByLabelText(/Event Title/), ' unsaved')
    await act(async () => outcome === 'success'
      ? old.resolve({ data: { ...rows[11], ticket_types: [{ id: 1, name: 'Old Alpha inventory' }] } })
      : old.reject(new Error('Old refresh failure')))
    expect(screen.getByLabelText(/Event Title/)).toHaveValue('Beta event unsaved')
    expect(screen.queryByText('Old Alpha inventory')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Retry ticket list' })).not.toBeInTheDocument()
  })

  it('does not let a delayed inventory refresh replace a newer saved schedule baseline', async () => {
    const old = deferred()
    mount()
    await screen.findByDisplayValue('Alpha event')
    apiClient.get.mockReturnValueOnce(old.promise)
    await userEvent.click(screen.getByRole('button', { name: 'Refresh saved inventory' }))
    const start = screen.getByLabelText(/Start Date & Time/)
    await userEvent.clear(start); await userEvent.type(start, '2026-11-20T19:00')
    apiClient.put.mockResolvedValueOnce({ data: { ...rows[11], starts_at: '2026-11-20T09:00:00Z' } })
    await userEvent.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Event updated successfully.')
    await act(async () => old.resolve({ data: rows[11] }))
    await userEvent.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Event updated successfully.')
    expect(apiClient.put.mock.calls[1][1]).not.toHaveProperty('starts_at')
  })

  it.each([true, false])('keeps newer saved publish readiness %s when older inventory completes', async ready => {
    const old = deferred()
    const checklist = complete => [{ code: 'tickets', label: 'Tickets', complete }]
    rows[11] = { ...rows[11], publish_checklist: checklist(!ready) }
    mount()
    await screen.findByDisplayValue('Alpha event')
    apiClient.get.mockReturnValueOnce(old.promise)
    await userEvent.click(screen.getByRole('button', { name: 'Refresh saved inventory' }))
    await screen.findByText('Updating ticket list…')
    await userEvent.type(screen.getByLabelText(/Event Title/), ' saved draft')
    apiClient.put.mockResolvedValueOnce({ data: { ...rows[11], title: 'Alpha event saved draft', publish_checklist: checklist(ready) } })
    await userEvent.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Event updated successfully.')
    expect(screen.getByRole('button', { name: 'Publish Event' })).toHaveProperty('disabled', !ready)
    // This inventory response was captured before the newer event save.
    await act(async () => old.resolve({ data: { ...rows[11], ticket_types: [{ id: 1, name: 'Refreshed admission' }] } }))
    expect(screen.getByRole('button', { name: 'Publish Event' })).toHaveProperty('disabled', !ready)
    expect(screen.getByText('Refreshed admission')).toBeInTheDocument()
    expect(screen.getByLabelText(/Event Title/)).toHaveValue('Alpha event saved draft')
    expect(screen.queryByText('Updating ticket list…')).not.toBeInTheDocument()
  })

  it('applies refreshed readiness after a failed save but blocks publish until the retained draft is saved', async () => {
    const old = deferred()
    rows[11] = { ...rows[11], publish_checklist: [{ code: 'tickets', label: 'Tickets', complete: false }] }
    mount()
    await screen.findByDisplayValue('Alpha event')
    apiClient.get.mockReturnValueOnce(old.promise)
    await userEvent.click(screen.getByRole('button', { name: 'Refresh saved inventory' }))
    await userEvent.type(screen.getByLabelText(/Event Title/), ' unsaved draft')
    apiClient.put.mockRejectedValueOnce(new Error('Synthetic save failure'))
    await userEvent.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Failed to update event')
    await act(async () => old.resolve({ data: { ...rows[11], publish_checklist: [{ code: 'tickets', label: 'Tickets', complete: true }] } }))
    expect(screen.getByRole('button', { name: 'Publish Event' })).toBeDisabled()
    expect(screen.getByText(/Preview shows the last saved event/)).toBeInTheDocument()
    expect(screen.getByLabelText(/Event Title/)).toHaveValue('Alpha event unsaved draft')
  })

  it('reconciles canonical saved fields without erasing a cover update after the save snapshot', async () => {
    const pending = deferred()
    rows[11] = { ...rows[11], venue_city: 'Tamuning', max_capacity: 300,
      publish_checklist: [{ code: 'event_details', label: 'Details', complete: true }] }
    apiClient.put.mockReturnValueOnce(pending.promise)
    mount()
    await userEvent.clear(await screen.findByLabelText('City'))
    fireEvent.change(screen.getByLabelText('Max Capacity'), { target: { value: '0200' } })
    await userEvent.click(screen.getByRole('button', { name: 'Save Changes' }))
    expect(apiClient.put.mock.calls[0][1].cover_image_url).toBeNull()
    // An upload begun before the save can finish while form inputs are disabled.
    await act(async () => uploads.get('11')('https://synthetic.invalid/new-cover.png'))
    await act(async () => pending.resolve({ data: { ...rows[11], cover_image_url: null, venue_city: 'Guam', max_capacity: 200 } }))
    await screen.findByText('Event updated successfully.')
    expect(screen.getByLabelText('City')).toHaveValue('Guam')
    expect(screen.getByLabelText('Max Capacity').value).toBe('200')
    expect(screen.getByRole('button', { name: 'Publish Event' })).toBeDisabled()
    await userEvent.click(screen.getByRole('button', { name: 'Save Changes' }))
    await screen.findByText('Event updated successfully.')
    expect(apiClient.put.mock.calls[1][1].cover_image_url).toBe('https://synthetic.invalid/new-cover.png')
    expect(screen.getByRole('button', { name: 'Publish Event' })).toBeEnabled()
  })

  it('pins the save body and identity before delayed token acquisition and suppresses transport after navigation', async () => {
    const actual = await vi.importActual('../../api/client')
    const token = deferred(), adapter = vi.fn()
    const previousAdapter = actual.default.defaults.adapter
    actual.default.defaults.adapter = adapter
    bind('actor-a', 'session-a', () => token.promise)
    apiClient.put.mockImplementation((...args) => actual.default.put(...args))
    try {
      mount()
      await screen.findByDisplayValue('Alpha event')
      await userEvent.click(screen.getByRole('button', { name: 'Save Changes' }))
      expect(apiClient.put.mock.calls[0][2].authContext).toBe(getApiAuthContext())
      await beta()
      await act(async () => token.resolve('original-token'))
      expect(adapter).not.toHaveBeenCalled()
      expect(screen.getByLabelText(/Event Title/)).toHaveValue('Beta event')
    } finally { actual.default.defaults.adapter = previousAdapter }
  })
})
