import 'fake-indexeddb/auto'
import { act, render as testingRender, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { MemoryRouter } from 'react-router-dom'
import apiClient from '../../api/client'
import { clearAllAdmissionData, clearEventAdmissionData, loadAuthorizedScanner, localScanState, queuedActions, purgeExpiredAdmissionAccess, queueAdmission, saveDevice, saveVerifiedManifest, sha256Hex } from '../../utils/admissionStore'
import { signedManifest } from '../../test/manifestFixture'
import ScannerPage from './ScannerPage'

const render = element => testingRender(<MemoryRouter>{element}</MemoryRouter>)

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
    for (const id of [92001, 92002, 92003]) await clearEventAdmissionData(id)
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

  it('acknowledges an already reversed Undo and permits a fresh admission from the updated manifest', async () => {
    const eventId = 92001
    const device = { id: 91, identifier: 'undo-device', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const ticket = { ticket_id: 501, state: 'admitted', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('undo-qr') }
    const initial = await signedManifest(eventId, [ticket])
    const renewed = await signedManifest(eventId, [{ ...ticket, state: 'valid' }], { version: 2 })
    let manifestCalls = 0
    apiClient.get.mockImplementation(url => {
      if (url === '/organizer/events') return Promise.resolve({ data: { events: [{ id: eventId, title: 'Undo Event' }] } })
      if (url.endsWith('/manifest')) return Promise.resolve({ data: ++manifestCalls === 1 ? initial : renewed })
      return Promise.resolve({ data: { counts: { admitted: 0, remaining: 1, conflicts: 0, rejected: 0 }, permissions: { can_reverse: true },
        recent_actions: [{ action_uuid: 'original-admission', ticket_id: 501, kind: 'admit', result: 'accepted', attendee: { attendee_name: 'Guest' } }] } })
    })
    const synced = []
    apiClient.post.mockImplementation((url, payload) => {
      if (!url.endsWith('/sync')) return Promise.resolve({ data: device })
      const action = payload.actions[0]
      synced.push(action.kind)
      return Promise.resolve({ data: { device: { ...device, last_sequence: action.sequence }, summary: {}, results: [{
        action_uuid: action.action_uuid, ticket_id: 501, kind: action.kind,
        result: action.kind === 'reverse' ? 'conflict' : 'accepted',
        reason_code: action.kind === 'reverse' ? 'already_reversed' : 'admitted',
      }] } })
    })
    render(<ScannerPage />)
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Undo' }))
    expect(await screen.findByText('Admission already reversed')).toBeInTheDocument()
    await waitFor(() => expect(screen.getByTestId('scanner-pending-count')).toHaveTextContent('0'))
    await screen.findByText(/Manifest v2/)
    await user.type(screen.getByLabelText('Ticket QR credential'), 'undo-qr')
    await user.click(screen.getByRole('button', { name: 'Validate' }))
    expect(await screen.findByText('Admission confirmed')).toBeInTheDocument()
    expect(synced).toEqual(['reverse', 'admit'])
    expect(await queuedActions(eventId, device.id)).toHaveLength(0)
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

  it('retains and reconciles saved scans across a signing-key change before allowing a trust reset', async () => {
    const eventId = 92001
    const device = { id: 91, identifier: 'original-device', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const ticket = { ticket_id: 501, state: 'valid', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('saved-key-qr') }
    await saveDevice(eventId, device)
    await saveVerifiedManifest(await signedManifest(eventId, [ticket]))
    const action = await queueAdmission({ eventId, deviceId: device.id, manifestVersion: 1, ticket, credentialHash: ticket.credential_hash, source: 'offline' })
    window.localStorage.setItem('hafapass_scanner_event_id', String(eventId))
    const changed = await signedManifest(eventId, [ticket], { version: 2 })
    const keys = await crypto.subtle.generateKey({ name: 'RSA-PSS', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify'])
    const publicKey = await crypto.subtle.exportKey('spki', keys.publicKey)
    const signature = await crypto.subtle.sign({ name: 'RSA-PSS', saltLength: 32 }, keys.privateKey, new TextEncoder().encode(changed.digest))
    const base64 = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes)))
    Object.assign(changed, { key_id: await sha256Hex(publicKey), public_key_spki: base64(publicKey), signature: base64(signature).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '') })
    apiClient.get.mockImplementation(url => {
      if (url === '/organizer/events') return Promise.resolve({ data: { events: [{ id: eventId, title: 'Rotated Key Event' }] } })
      if (url.endsWith('/manifest')) return Promise.resolve({ data: changed })
      return Promise.resolve({ data: { counts: {}, permissions: {}, recent_actions: [] } })
    })
    apiClient.post.mockImplementation(url => Promise.resolve({ data: url.endsWith('/sync') ? {
      device: { ...device, last_sequence: 1 },
      results: [{ action_uuid: action.action_uuid, ticket_id: ticket.ticket_id, kind: 'admit', result: 'accepted' }], summary: {},
    } : device }))
    vi.spyOn(window, 'confirm').mockReturnValue(true)
    render(<ScannerPage />)
    const user = userEvent.setup()
    await screen.findByText(/Scanner signing key changed/)
    expect(await loadAuthorizedScanner(eventId)).toBeNull()
    expect(await localScanState(eventId, ticket.ticket_id)).toBeUndefined()
    expect(screen.getByTestId('scanner-pending-count')).toHaveTextContent('1')
    expect(screen.getByRole('button', { name: 'Start QR scanner' })).toBeDisabled()
    await user.click(screen.getByRole('button', { name: 'Reset trusted device' }))
    expect(await screen.findByText('Sync every queued action before resetting this scanner.')).toBeInTheDocument()
    expect(await queuedActions(eventId, device.id)).toHaveLength(1)
    await user.click(screen.getByRole('button', { name: 'Sync saved scans' }))
    await waitFor(() => expect(screen.getByTestId('scanner-pending-count')).toHaveTextContent('0'))
    expect(await queuedActions(eventId, device.id)).toHaveLength(0)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Reset trusted device' })).toBeEnabled())
    await user.click(screen.getByRole('button', { name: 'Reset trusted device' }))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Start QR scanner' })).toBeEnabled())
    expect(await queuedActions(eventId, device.id)).toHaveLength(0)
  })
  it.each(['empty', 'unknown'])('retains queued scans and stops after a %s synchronization response', async kind => {
    const eventId = 92001
    const device = { id: 91, identifier: 'unconfirmed-device', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const ticket = { ticket_id: 501, state: 'valid', credential_hash: await sha256Hex('unconfirmed-qr') }
    await saveDevice(eventId, device)
    await saveVerifiedManifest(await signedManifest(eventId, [ticket]))
    const action = await queueAdmission({ eventId, deviceId: 91, manifestVersion: 1, ticket, credentialHash: ticket.credential_hash, source: 'offline' })
    window.localStorage.setItem('hafapass_scanner_event_id', String(eventId))
    apiClient.get.mockRejectedValue(new Error('API unavailable'))
    let syncCalls = 0
    apiClient.post.mockImplementation(url => {
      if (!url.endsWith('/sync')) return Promise.reject(new Error('registration unavailable'))
      syncCalls += 1
      return Promise.resolve({ data: { device, results: kind === 'empty' ? [] : [{ action_uuid: action.action_uuid, kind: 'admit', result: 'processing' }] } })
    })
    render(<ScannerPage />)
    await waitFor(() => expect(syncCalls).toBe(1))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
    await userEvent.setup().click(screen.getByRole('button', { name: 'Sync now' }))
    expect(await screen.findByText(/server did not confirm every saved scan/)).toBeInTheDocument()
    expect(syncCalls).toBe(2) // automatic startup and the explicit retry each make one attempt
    expect(await queuedActions(eventId, 91)).toHaveLength(1)
  })

  it('finishes a successful acknowledgement when manifest expiry removes access during the request', async () => {
    const eventId = 92001
    const device = { id: 91, identifier: 'expiry-recovery-device', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const ticket = { ticket_id: 501, state: 'valid', credential_hash: await sha256Hex('expiry-recovery-qr') }
    await saveDevice(eventId, device)
    await saveVerifiedManifest(await signedManifest(eventId, [ticket]))
    const action = await queueAdmission({ eventId, deviceId: 91, manifestVersion: 1, ticket, credentialHash: ticket.credential_hash, source: 'offline' })
    window.localStorage.setItem('hafapass_scanner_event_id', String(eventId))
    apiClient.get.mockRejectedValue(new Error('API unavailable'))
    let finishSync
    let syncCalls = 0
    apiClient.post.mockImplementation(url => {
      if (!url.endsWith('/sync')) return Promise.reject(new Error('registration unavailable'))
      syncCalls += 1
      return new Promise(resolve => { finishSync = resolve })
    })
    render(<ScannerPage />)
    await waitFor(() => expect(finishSync).toBeTypeOf('function'))
    await purgeExpiredAdmissionAccess(eventId)
    await act(async () => finishSync({ data: { device: { ...device, last_sequence: 1 }, results: [{ action_uuid: action.action_uuid, ticket_id: ticket.ticket_id, kind: 'admit', result: 'accepted' }], summary: {} } }))
    await waitFor(() => expect(screen.getByTestId('scanner-pending-count')).toHaveTextContent('0'))
    expect(syncCalls).toBe(1)
    expect(await queuedActions(eventId, 91)).toHaveLength(0)
    expect(await loadAuthorizedScanner(eventId)).toBeNull()
    expect(await localScanState(eventId, ticket.ticket_id)).toBeNull()
    expect(screen.getByRole('button', { name: 'Start QR scanner' })).toBeDisabled()
    expect(screen.getByLabelText('Ticket QR credential')).toBeDisabled()
    expect(await screen.findByText(/Saved scans synchronized/)).toBeInTheDocument()
  })

  it.each(['account', 'device'])('ignores an obsolete authorization failure after a %s change without purging current access', async change => {
    const eventId = 92001
    window.localStorage.setItem('hafapass_scanner_user_id', 'staff-a')
    const device = { id: 91, identifier: 'switching-device', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const ticket = { ticket_id: 501, state: 'valid', credential_hash: await sha256Hex('switching-qr') }
    await saveDevice(eventId, device)
    const envelope = await signedManifest(eventId, [ticket])
    await saveVerifiedManifest(envelope)
    await queueAdmission({ eventId, deviceId: 91, manifestVersion: 1, ticket, credentialHash: ticket.credential_hash, source: 'offline' })
    window.localStorage.setItem('hafapass_scanner_event_id', String(eventId))
    apiClient.get.mockRejectedValue(new Error('API unavailable'))
    let rejectSync
    apiClient.post.mockImplementation(url => url.endsWith('/sync') ? new Promise((_resolve, reject) => { rejectSync = reject }) : Promise.reject(new Error('registration unavailable')))
    render(<ScannerPage />)
    await waitFor(() => expect(rejectSync).toBeTypeOf('function'))
    await clearAllAdmissionData()
    if (change === 'account') window.localStorage.setItem('hafapass_scanner_user_id', 'staff-b')
    await saveDevice(eventId, { ...device, id: 92, identifier: 'new-account-device' })
    await saveVerifiedManifest(envelope)
    await act(async () => rejectSync({ response: { status: 403, data: { error: 'Old account refused' } } }))
    expect((await loadAuthorizedScanner(eventId))?.device.id).toBe(92)
    expect(screen.queryByText('Old account refused')).not.toBeInTheDocument()
    window.localStorage.setItem('hafapass_scanner_user_id', 'staff-a')
    expect(await queuedActions(eventId, 91)).toHaveLength(1)
  })

  it('reports a journal storage failure during sync recovery without deleting saved access or scans', async () => {
    const eventId = 92003
    const device = { id: 91, identifier: 'storage-recovery-device', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const ticket = { ticket_id: 501, state: 'valid', credential_hash: await sha256Hex('storage-recovery-qr') }
    await saveDevice(eventId, device)
    await saveVerifiedManifest(await signedManifest(eventId, [ticket]))
    await queueAdmission({ eventId, deviceId: 91, manifestVersion: 1, ticket, credentialHash: ticket.credential_hash, source: 'offline' })
    window.localStorage.setItem('hafapass_scanner_event_id', String(eventId))
    apiClient.get.mockRejectedValue(new Error('API unavailable'))
    let syncCalls = 0
    apiClient.post.mockImplementation(url => {
      if (url.endsWith('/sync')) syncCalls += 1
      return Promise.reject(new Error('API unavailable'))
    })
    render(<ScannerPage />)
    await waitFor(() => expect(syncCalls).toBe(1))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
    const originalGet = IDBObjectStore.prototype.get
    vi.spyOn(IDBObjectStore.prototype, 'get').mockImplementation(function (...args) {
      if (this.name === 'journal_devices') throw new DOMException('Storage unavailable', 'UnknownError')
      return originalGet.apply(this, args)
    })
    await userEvent.setup().click(screen.getByRole('button', { name: 'Sync now' }))
    expect(await screen.findByText(/Saved scanner data could not be read/)).toBeInTheDocument()
    expect(syncCalls).toBe(1)
    expect(await queuedActions(eventId, device.id)).toHaveLength(1)
    expect((await loadAuthorizedScanner(eventId))?.device.id).toBe(device.id)
    expect(screen.getByRole('button', { name: 'Start QR scanner' })).toBeEnabled()
  })

})
