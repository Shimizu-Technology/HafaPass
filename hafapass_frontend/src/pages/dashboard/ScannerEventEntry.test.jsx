import 'fake-indexeddb/auto'
import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, useNavigate } from 'react-router-dom'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import { clearAllAdmissionData, queueAdmission, queuedActions, saveDevice, saveVerifiedManifest } from '../../utils/admissionStore'
import { signedManifest } from '../../test/manifestFixture'
import * as admissionStore from '../../utils/admissionStore'
import ScannerPage from './ScannerPage'
vi.mock('../../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() }, getApiAuthContext: () => null, subscribeApiAuthContext: () => () => {} }))
vi.mock('@zxing/browser', () => ({ BrowserQRCodeReader: class {} }))
beforeEach(async () => { vi.clearAllMocks(); window.localStorage.clear(); await clearAllAdmissionData() })
afterEach(async () => { vi.restoreAllMocks(); await clearAllAdmissionData(); window.localStorage.clear() })
async function mount(requested) {
  const manifest = await signedManifest(92002)
  apiClient.get.mockImplementation(path => {
    if (path === '/organizer/events') return Promise.resolve({ data: { events: [{ id: 92001, title: 'Earlier event' }, { id: 92002, title: 'Clicked event' }] } })
    if (path.endsWith('/manifest')) return Promise.resolve({ data: manifest })
    if (path === '/me') return Promise.resolve({ data: { id: 7 } })
    return Promise.resolve({ data: { counts: {} } })
  })
  apiClient.post.mockResolvedValue({ data: { id: 92, identifier: 'event-entry-device', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() } })
  return render(<MemoryRouter initialEntries={[`/dashboard/scanner?event=${requested}`]}><ScannerPage /></MemoryRouter>)
}
it('selects the clicked assigned event ahead of the saved event without deleting its pending journal', async () => {
  const oldDevice = { id: 91, identifier: 'old-pending-device', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
  await saveDevice(92001, oldDevice)
  await saveVerifiedManifest(await signedManifest(92001))
  await queueAdmission({ eventId: 92001, deviceId: 91, manifestVersion: 1, ticket: { ticket_id: 501 }, credentialHash: 'old-credential', source: 'offline' })
  window.localStorage.setItem('hafapass_scanner_event_id', '92001')
  await mount(92002)
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('92002'))
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/92002/scanner_devices', expect.anything()))
  expect(await queuedActions(92001, 91)).toHaveLength(1)
})
it('never registers a requested event without a list or direct authorization grant', async () => {
  window.localStorage.setItem('hafapass_scanner_event_id', '92002')
  await mount(99999)
  await screen.findByText(/This event is not assigned to your account/)
  expect(screen.getByLabelText('Event to scan')).toHaveValue('')
  expect(screen.getByLabelText('Ticket QR code')).toBeDisabled()
  expect(apiClient.post).not.toHaveBeenCalled()
  expect(window.localStorage.getItem('hafapass_scanner_event_id')).toBe('92002')
})

async function prepareCachedEvent(eventId, deviceId, pending = false) {
  const device = { id: deviceId, identifier: `route-device-${eventId}`, effective: true,
    authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
  await saveDevice(eventId, device)
  await saveVerifiedManifest(await signedManifest(eventId))
  if (pending) await queueAdmission({ eventId, deviceId, manifestVersion: 1, ticket: { ticket_id: 501 }, credentialHash: 'pending-route-ticket', source: 'offline' })
}

it.each(['query', 'verified fallback'])('uses the %s target offline rather than the last prepared event, retaining its journal', async targetSource => {
  await prepareCachedEvent(92001, 91, true)
  await prepareCachedEvent(92002, 92)
  window.localStorage.setItem('hafapass_scanner_event_id', '92001')
  render(<MemoryRouter initialEntries={[targetSource === 'query' ? '/dashboard/scanner?event=92002' : '/dashboard/scanner']}>
    <ScannerPage offlineOnly offlineEventId={targetSource === 'query' ? null : '92002'} />
  </MemoryRouter>)
  await waitFor(() => expect(screen.getByLabelText('Ticket QR code')).toBeEnabled())
  expect(screen.getByLabelText('Event to scan')).toHaveValue('92002')
  expect(screen.queryByRole('option', { name: 'Event 92001' })).not.toBeInTheDocument()
  expect(window.localStorage.getItem('hafapass_scanner_event_id')).toBe('92002')
  expect(await queuedActions(92001, 91)).toHaveLength(1)
  expect(apiClient.post).not.toHaveBeenCalled()
})

it.each(['92002', ''])('pauses entry when explicitly requested event %s has no offline authorization', async target => {
  await prepareCachedEvent(92001, 91, true)
  window.localStorage.setItem('hafapass_scanner_event_id', '92001')
  render(<MemoryRouter initialEntries={[`/dashboard/scanner?event=${target}`]}><ScannerPage offlineOnly /></MemoryRouter>)
  await screen.findByText(/This event is not saved on this device/)
  expect(screen.getByLabelText('Ticket QR code')).toBeDisabled()
  expect(screen.getByRole('button', { name: 'Start camera' })).toBeDisabled()
  expect(screen.queryByRole('option', { name: 'Event 92001' })).not.toBeInTheDocument()
  expect(window.localStorage.getItem('hafapass_scanner_event_id')).toBe('92001')
  expect(await queuedActions(92001, 91)).toHaveLength(1)
  expect(apiClient.post).not.toHaveBeenCalled()
})

it('uses only the requested offline target when the assigned-list request fails', async () => {
  await prepareCachedEvent(92001, 91, true)
  window.localStorage.setItem('hafapass_scanner_event_id', '92001')
  apiClient.get.mockRejectedValue(new Error('Network unavailable'))
  render(<MemoryRouter initialEntries={['/dashboard/scanner?event=92002']}><ScannerPage /></MemoryRouter>)
  await screen.findByText(/This event is not saved on this device/)
  expect(screen.getByLabelText('Ticket QR code')).toBeDisabled()
  expect(apiClient.post).not.toHaveBeenCalled()
  expect(await queuedActions(92001, 91)).toHaveLength(1)
})

it('withdraws a resolved old event while the new offline target loads and ignores an obsolete cache lookup', async () => {
  await prepareCachedEvent(92001, 91, true)
  await prepareCachedEvent(92002, 92)
  window.localStorage.setItem('hafapass_scanner_event_id', '92001')
  const originalLoad = admissionStore.loadAuthorizedScanner
  let releaseOld
  const releaseCurrent = []
  let holdCurrent = true
  let holdOld = false
  vi.spyOn(admissionStore, 'loadAuthorizedScanner').mockImplementation(async id => {
    const value = await originalLoad(id)
    if (String(id) === '92002' && holdCurrent) await new Promise(resolve => { releaseCurrent.push(resolve) })
    else if (String(id) === '92001' && holdOld) await new Promise(resolve => { releaseOld = resolve })
    return value
  })
  let navigate
  function Navigation() { navigate = useNavigate(); return null }
  render(<MemoryRouter initialEntries={['/dashboard/scanner?event=92001']}><Navigation /><ScannerPage offlineOnly /></MemoryRouter>)
  await waitFor(() => expect(screen.getByLabelText('Ticket QR code')).toBeEnabled())
  await act(async () => navigate('/dashboard/scanner?event=92002'))
  expect(screen.getByLabelText('Ticket QR code')).toBeDisabled()
  expect(screen.queryByText('Ticket list ready · 0 tickets')).not.toBeInTheDocument()
  await waitFor(() => expect(releaseCurrent).toHaveLength(1))
  // Another visit starts an old-event lookup; then return before it completes.
  holdOld = true
  await act(async () => navigate('/dashboard/scanner?event=92001'))
  await waitFor(() => expect(releaseOld).toBeDefined())
  await act(async () => navigate('/dashboard/scanner?event=92002'))
  await waitFor(() => expect(releaseCurrent).toHaveLength(2))
  holdCurrent = false
  await act(async () => { releaseOld(); releaseCurrent.forEach(resolve => resolve()) })
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('92002'))
  await waitFor(() => expect(screen.getByLabelText('Ticket QR code')).toBeEnabled())
  expect(screen.queryByRole('option', { name: 'Event 92001' })).not.toBeInTheDocument()
  expect(await queuedActions(92001, 91)).toHaveLength(1)
  expect(apiClient.post).not.toHaveBeenCalled()
})

it('does not register an old event when its setup cache read completes after changing the URL target', async () => {
  await prepareCachedEvent(92001, 91, true)
  const originalLoad = admissionStore.loadAuthorizedScanner
  let releaseOld
  vi.spyOn(admissionStore, 'loadAuthorizedScanner').mockImplementation(async id => {
    const value = await originalLoad(id)
    if (String(id) === '92001') await new Promise(resolve => { releaseOld = resolve })
    return value
  })
  const manifest = await signedManifest(92002)
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path === '/organizer/events'
    ? { events: [{ id: 92001, title: 'Old assigned event' }, { id: 92002, title: 'New assigned event' }] }
    : path === '/me' ? { id: 7 } : path.endsWith('/manifest') ? manifest : { counts: {} } }))
  apiClient.post.mockResolvedValue({ data: { id: 92, identifier: 'new-route-device', effective: true,
    authorization_expires_at: new Date(Date.now() + 600_000).toISOString() } })
  let navigate
  function Navigation() { navigate = useNavigate(); return null }
  render(<MemoryRouter initialEntries={['/dashboard/scanner?event=92001']}><Navigation /><ScannerPage /></MemoryRouter>)
  await waitFor(() => expect(releaseOld).toBeDefined())
  await act(async () => navigate('/dashboard/scanner?event=92002'))
  await waitFor(() => expect(screen.getByLabelText('Ticket QR code')).toBeEnabled())
  await act(async () => releaseOld())
  expect(screen.getByLabelText('Event to scan')).toHaveValue('92002')
  expect(apiClient.post.mock.calls.some(([path]) => path.includes('/92001/'))).toBe(false)
  expect(await queuedActions(92001, 91)).toHaveLength(1)
})

it('persists manual selection in the URL and reauthorizes it after Back before reviving entry', async () => {
  const pendingLookup = vi.spyOn(admissionStore, 'loadPendingDeviceIdentity')
  const manifests = { 92001: await signedManifest(92001), 92002: await signedManifest(92002) }
  const assigned = { events: [{ id: 92001, title: 'URL event A' }, { id: 92002, title: 'Manually selected event B' }] }
  let listCalls = 0
  let releaseAway
  let releaseBack
  apiClient.get.mockImplementation(path => {
    if (path === '/organizer/events') {
      if (++listCalls <= 2) return Promise.resolve({ data: assigned })
      return new Promise(resolve => { if (listCalls === 3) releaseAway = resolve; else releaseBack = resolve })
    }
    if (path === '/me') return Promise.resolve({ data: { id: 7 } })
    const eventId = path.match(/\/events\/(\d+)\//)?.[1]
    return Promise.resolve({ data: path.endsWith('/manifest') ? manifests[eventId] : { counts: {} } })
  })
  apiClient.post.mockImplementation(path => {
    const eventId = path.match(/\/events\/(\d+)\//)?.[1]
    return Promise.resolve({ data: { id: Number(eventId), identifier: `pop-device-${eventId}`, effective: true,
      authorization_expires_at: new Date(Date.now() + 600_000).toISOString() } })
  })
  let navigate
  function Navigation() { navigate = useNavigate(); return null }
  render(<MemoryRouter initialEntries={['/dashboard/scanner?event=92001']}><Navigation /><ScannerPage /></MemoryRouter>)
  await waitFor(() => expect(screen.getByLabelText('Ticket QR code')).toBeEnabled())
  await userEvent.selectOptions(screen.getByLabelText('Event to scan'), '92002')
  await waitFor(() => expect(screen.getByLabelText('Ticket QR code')).toBeEnabled())
  const registrations = id => apiClient.post.mock.calls.filter(([path]) => path === `/organizer/events/${id}/scanner_devices`).length
  const pendingLookupsForB = () => pendingLookup.mock.calls.filter(([id]) => String(id) === '92002').length
  expect(registrations(92002)).toBe(1)
  const verifiedBLookups = pendingLookupsForB()
  await act(async () => navigate('/dashboard/scanner?event=92003'))
  await waitFor(() => expect(releaseAway).toBeDefined())
  await act(async () => navigate(-1))
  await waitFor(() => expect(releaseBack).toBeDefined())
  // A stale configureEvent starts this lookup synchronously, before any IndexedDB yield.
  expect(pendingLookupsForB()).toBe(verifiedBLookups)
  expect(screen.getByLabelText('Event to scan')).toHaveValue('')
  expect(screen.getByLabelText('Ticket QR code')).toBeDisabled()
  expect(screen.queryByRole('option', { name: 'Manually selected event B' })).not.toBeInTheDocument()
  expect(registrations(92002)).toBe(1)
  await act(async () => releaseBack({ data: assigned }))
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('92002'))
  await waitFor(() => expect(screen.getByLabelText('Ticket QR code')).toBeEnabled())
  expect(registrations(92001)).toBe(1)
  expect(registrations(92002)).toBe(2)
  await act(async () => releaseAway({ data: { events: [{ id: 92003, title: 'Obsolete away event' }] } }))
  expect(screen.getByLabelText('Event to scan')).toHaveValue('92002')
  expect(screen.queryByRole('option', { name: 'Obsolete away event' })).not.toBeInTheDocument()
})

it('ignores an obsolete assigned-list response after a query change', async () => {
  let resolveFirst
  let listCalls = 0
  const manifest = await signedManifest(92002)
  apiClient.get.mockImplementation(path => {
    if (path === '/organizer/events') {
      if (++listCalls === 1) return new Promise(resolve => { resolveFirst = resolve })
      return Promise.resolve({ data: { events: [{ id: 92002, title: 'Current requested event' }] } })
    }
    if (path.endsWith('/manifest')) return Promise.resolve({ data: manifest })
    if (path === '/me') return Promise.resolve({ data: { id: 7 } })
    return Promise.resolve({ data: { counts: {} } })
  })
  apiClient.post.mockResolvedValue({ data: { id: 92, identifier: 'current-event-device', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() } })
  function ChangeEvent() {
    const navigate = useNavigate()
    return <button onClick={() => navigate('/dashboard/scanner?event=92002')}>Change requested event</button>
  }
  render(<MemoryRouter initialEntries={['/dashboard/scanner?event=92001']}><ChangeEvent /><ScannerPage /></MemoryRouter>)
  await waitFor(() => expect(resolveFirst).toBeDefined())
  await act(async () => { screen.getByRole('button', { name: 'Change requested event' }).click() })
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('92002'))
  await act(async () => { resolveFirst({ data: { events: [{ id: 92001, title: 'Obsolete requested event' }] } }) })
  expect(screen.getByLabelText('Event to scan')).toHaveValue('92002')
  expect(screen.queryByRole('option', { name: 'Obsolete requested event' })).not.toBeInTheDocument()
  expect(apiClient.post.mock.calls.some(([path]) => path.includes('/92001/'))).toBe(false)
})

it('runs an Attendees page lookup hand-off but leaves the admission to staff', async () => {
  const ticket = { ticket_id: 501, state: 'valid', attendee_name: 'Mina Cruz', credential_hash: 'handoff-credential-hash' }
  const manifest = await signedManifest(92002, [ticket])
  apiClient.get.mockImplementation((path, config) => {
    if (path === '/organizer/events') return Promise.resolve({ data: { events: [{ id: 92002, title: 'Clicked event', status: 'published' }] } })
    if (path.endsWith('/manifest')) return Promise.resolve({ data: manifest })
    if (path === '/me') return Promise.resolve({ data: { id: 7 } })
    if (path.endsWith('/admissions/search')) return Promise.resolve({ data: config?.params?.q === 'HP-T501'
      ? [{ id: 501, code: 'HP-T501', attendee_name: 'Mina Cruz', ticket_type: 'Entry', status: 'issued', admission_allowed: true }] : [] })
    return Promise.resolve({ data: { counts: {} } })
  })
  apiClient.post.mockResolvedValue({ data: { id: 92, identifier: 'handoff-device', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() } })
  render(<MemoryRouter initialEntries={['/dashboard/scanner?event=92002&lookup=HP-T501']}><ScannerPage /></MemoryRouter>)
  expect(await screen.findByText('Mina Cruz · HP-T501')).toBeInTheDocument()
  expect(screen.getByLabelText('Attendee name or ticket number')).toHaveValue('HP-T501')
  expect(apiClient.get.mock.calls.filter(([path]) => path.endsWith('/admissions/search'))).toHaveLength(1)
  expect(screen.getByRole('button', { name: 'Admit' })).toBeEnabled()
  expect(apiClient.post.mock.calls.some(([path]) => path.endsWith('/sync'))).toBe(false)
  expect(await queuedActions(92002, 92)).toHaveLength(0)
})
