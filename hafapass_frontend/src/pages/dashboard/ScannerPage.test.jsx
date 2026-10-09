import 'fake-indexeddb/auto'
import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import { clearAllAdmissionData, clearEventAdmissionData, queuedActions, saveDevice, saveVerifiedManifest, sha256Hex } from '../../utils/admissionStore'
import { signedManifest } from '../../test/manifestFixture'
import ScannerPage from './ScannerPage'

const camera = vi.hoisted(() => ({ callbacks: [], stops: [] }))
vi.mock('../../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('@zxing/browser', () => ({ BrowserQRCodeReader: class {
  decodeFromVideoDevice(_device, _video, callback) { camera.callbacks.push(callback); const stop = vi.fn(); camera.stops.push(stop); return Promise.resolve({ stop }) }
} }))

describe('scanner recovery and camera ownership', () => {
  beforeEach(async () => {
    vi.clearAllMocks()
    camera.callbacks = []
    camera.stops = []
    window.localStorage.clear()
    await clearAllAdmissionData()
    for (const id of [92001, 92002]) await clearEventAdmissionData(id)
  })
  afterEach(() => { vi.restoreAllMocks(); window.localStorage.clear() })

  it('boots from verified local authorization when navigator is online but the API is down', async () => {
    const eventId = 92001
    const device = { id: 91, identifier: 'cached-scanner', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const ticket = { ticket_id: 501, state: 'valid', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('cached-qr') }
    await saveDevice(eventId, device)
    await saveVerifiedManifest(await signedManifest(eventId, [ticket]))
    window.localStorage.setItem('hafapass_scanner_event_id', String(eventId))
    apiClient.get.mockRejectedValue(new Error('API unavailable'))
    apiClient.post.mockRejectedValue(new Error('API unavailable'))
    render(<ScannerPage />)
    const user = userEvent.setup()
    await waitFor(() => expect(screen.getByRole('button', { name: 'Start QR scanner' })).toBeEnabled())
    await user.type(screen.getByLabelText('Ticket QR credential'), 'cached-qr')
    await user.click(screen.getByRole('button', { name: 'Validate' }))
    await screen.findByText('Admitted — syncing')
    expect(await queuedActions(eventId, device.id)).toHaveLength(1)
    await user.type(screen.getByLabelText('Ticket QR credential'), 'cached-qr')
    await user.click(screen.getByRole('button', { name: 'Validate' }))
    expect(await screen.findByText('Already scanned on this device')).toBeInTheDocument()
    expect(await queuedActions(eventId, device.id)).toHaveLength(1)
  })

  it('refuses cached admission after the API definitively rejects renewed authorization', async () => {
    const eventId = 92001
    await saveDevice(eventId, { id: 91, identifier: 'revoked-device', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() })
    await saveVerifiedManifest(await signedManifest(eventId))
    window.localStorage.setItem('hafapass_scanner_event_id', String(eventId))
    apiClient.get.mockResolvedValue({ data: { events: [{ id: eventId, title: 'Revoked Event' }] } })
    apiClient.post.mockRejectedValue({ response: { status: 422, data: { error: 'You are not assigned to scan this event' } } })
    render(<ScannerPage />)
    await screen.findByText('You are not assigned to scan this event')
    expect(screen.getByRole('button', { name: 'Start QR scanner' })).toBeDisabled()
    expect(screen.getByLabelText('Ticket QR credential')).toBeDisabled()
  })

  it('keeps the camera running across a verified refresh and rejects a newly cancelled credential using the current manifest', async () => {
    const eventId = 92001
    const ticket = { ticket_id: 501, state: 'valid', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('refresh-qr') }
    const initial = await signedManifest(eventId, [ticket])
    const cancelled = await signedManifest(eventId, [{ ...ticket, state: 'cancelled' }], { version: 2 })
    let manifestCalls = 0
    apiClient.get.mockImplementation(url => {
      if (url === '/organizer/events') return Promise.resolve({ data: { events: [{ id: eventId, title: 'Refresh Event' }] } })
      if (url.endsWith('/manifest')) return Promise.resolve({ data: ++manifestCalls === 1 ? initial : cancelled })
      return Promise.resolve({ data: { counts: { admitted: 0, remaining: 1, conflicts: 0, rejected: 0 }, permissions: {}, recent_actions: [] } })
    })
    apiClient.post.mockResolvedValue({ data: { id: 91, identifier: 'refresh-device', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() } })
    render(<ScannerPage />)
    const user = userEvent.setup()
    await waitFor(() => expect(screen.getByRole('button', { name: 'Start QR scanner' })).toBeEnabled())
    await user.click(screen.getByRole('button', { name: 'Start QR scanner' }))
    await waitFor(() => expect(camera.callbacks).toHaveLength(1))
    await user.click(screen.getByRole('button', { name: 'Sync now' }))
    await screen.findByText(/Manifest v2/)
    expect(camera.stops[0]).not.toHaveBeenCalled()
    expect(screen.getByRole('button', { name: 'Stop camera' })).toBeInTheDocument()
    await act(async () => camera.callbacks[0]({ getText: () => 'refresh-qr' }))
    expect(await screen.findByText('Cancelled ticket')).toBeInTheDocument()
    expect(await queuedActions(eventId, 91)).toHaveLength(0)
  })

  it('stops the old camera on an event switch and accepts scans only from the new callback and manifest', async () => {
    const tickets = await Promise.all([92001, 92002].map(async id => ({ ticket_id: id + 1, state: 'valid', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex(`qr-${id}`) })))
    const manifests = await Promise.all([92001, 92002].map((id, index) => signedManifest(id, [tickets[index]])))
    apiClient.get.mockImplementation(url => {
      if (url === '/organizer/events') return Promise.resolve({ data: { events: [{ id: 92001, title: 'Event A' }, { id: 92002, title: 'Event B' }] } })
      if (url.endsWith('/manifest')) return Promise.resolve({ data: manifests[url.includes('/92001/') ? 0 : 1] })
      return Promise.resolve({ data: { counts: { admitted: 0, remaining: 1, conflicts: 0, rejected: 0 }, permissions: {}, recent_actions: [] } })
    })
    apiClient.post.mockImplementation(url => url.endsWith('/sync') ? Promise.reject(new Error('sync paused')) : Promise.resolve({ data: { id: url.includes('/92001/') ? 91 : 92, identifier: 'camera-scanner', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() } }))
    render(<ScannerPage />)
    const user = userEvent.setup()
    await waitFor(() => expect(screen.getByRole('button', { name: 'Start QR scanner' })).toBeEnabled())
    await user.click(screen.getByRole('button', { name: 'Start QR scanner' }))
    await waitFor(() => expect(camera.callbacks).toHaveLength(1))
    await user.selectOptions(screen.getByLabelText('Event to scan'), '92002')
    await waitFor(() => expect(camera.stops[0]).toHaveBeenCalled())
    await waitFor(() => expect(screen.getByRole('button', { name: 'Start QR scanner' })).toBeEnabled())
    await act(async () => camera.callbacks[0]({ getText: () => 'qr-92001' }))
    expect(await queuedActions(92001, 91)).toHaveLength(0)
    await user.click(screen.getByRole('button', { name: 'Start QR scanner' }))
    await waitFor(() => expect(camera.callbacks).toHaveLength(2))
    await act(async () => camera.callbacks[1]({ getText: () => 'qr-92002' }))
    await screen.findByText('Admitted — syncing')
    expect(await queuedActions(92002, 92)).toHaveLength(1)
    expect(await queuedActions(92001, 91)).toHaveLength(0)
  })
})
