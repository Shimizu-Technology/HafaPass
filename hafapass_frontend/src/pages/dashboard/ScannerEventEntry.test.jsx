import 'fake-indexeddb/auto'
import { act, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, useNavigate } from 'react-router-dom'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import { clearAllAdmissionData, queueAdmission, queuedActions, saveDevice, saveVerifiedManifest } from '../../utils/admissionStore'
import { signedManifest } from '../../test/manifestFixture'
import ScannerPage from './ScannerPage'
vi.mock('../../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('@zxing/browser', () => ({ BrowserQRCodeReader: class {} }))
beforeEach(async () => { vi.clearAllMocks(); window.localStorage.clear(); await clearAllAdmissionData() })
afterEach(async () => { await clearAllAdmissionData(); window.localStorage.clear() })
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
it('never registers a requested event outside the server assigned list', async () => {
  window.localStorage.setItem('hafapass_scanner_event_id', '92002')
  await mount(99999)
  await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('92002'))
  await waitFor(() => expect(apiClient.post).toHaveBeenCalled())
  expect(apiClient.post.mock.calls.some(([path]) => path.includes('/99999/'))).toBe(false)
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
