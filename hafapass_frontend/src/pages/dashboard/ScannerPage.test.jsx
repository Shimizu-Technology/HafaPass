import 'fake-indexeddb/auto'
import { act, render as testingRender, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { MemoryRouter } from 'react-router-dom'
import apiClient from '../../api/client'
import * as admissionStore from '../../utils/admissionStore'
import { applySyncResults, clearAllAdmissionData, clearEventAdmissionData, loadAuthorizedScanner, localScanState, queuedActions, purgeExpiredAdmissionAccess, queueAdmission, saveDevice, saveVerifiedManifest, sha256Hex } from '../../utils/admissionStore'
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
  afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); window.localStorage.clear() })

  it.each(['accepted', 'rejected'])('waits neutrally for the exact online %s acknowledgement', async verdict => {
    const eventId = 92001
    const device = { id: 91, identifier: 'waiting-scanner', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const ticket = { ticket_id: 501, code: 'HP-T501', state: 'valid', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('waiting-qr') }
    const manifest = await signedManifest(eventId, [ticket])
    const vibrate = vi.fn()
    vi.stubGlobal('navigator', new Proxy(navigator, { get: (target, name) => name === 'vibrate' ? vibrate : Reflect.get(target, name) }))
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/organizer/events'
      ? { events: [{ id: eventId, title: 'Waiting Event' }] }
      : url.endsWith('/manifest') ? manifest : { counts: {}, permissions: {}, recent_actions: [] } }))
    let acknowledge
    let submitted
    apiClient.post.mockImplementation((url, payload) => !url.endsWith('/sync') ? Promise.resolve({ data: device })
      : new Promise(resolve => { submitted = payload.actions; acknowledge = () => resolve({ data: {
        device: { ...device, last_sequence: submitted[0].sequence }, summary: {},
        results: [{ ...submitted[0], action_uuid: 'older-same-ticket-receipt', result: 'accepted' },
          { ...submitted[0], result: verdict, reason_code: verdict === 'accepted' ? 'admitted' : 'refund_pending' }],
      } }) }))
    render(<ScannerPage />)
    await screen.findByText(/Manifest v1/)
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Ticket QR credential'), 'waiting-qr')
    await user.click(screen.getByRole('button', { name: 'Validate' }))
    const pending = await screen.findByText('Waiting for server confirmation')
    expect(pending.closest('[role="status"]')).toHaveClass('bg-neutral-50')
    expect(screen.queryByText('Admission confirmed')).not.toBeInTheDocument()
    expect(vibrate).not.toHaveBeenCalled()
    await waitFor(() => expect(acknowledge).toBeDefined())
    expect(await queuedActions(eventId, device.id)).toMatchObject([{ action_uuid: submitted[0].action_uuid, source: 'online' }])
    await act(async () => acknowledge())
    expect(await screen.findByText(verdict === 'accepted' ? 'Admission confirmed' : 'Refund pending — do not admit')).toBeInTheDocument()
    await waitFor(() => expect(screen.getByTestId('scanner-pending-count')).toHaveTextContent('0'))
    expect(await localScanState(eventId, ticket.ticket_id)).toMatchObject({ status: verdict, action_uuid: submitted[0].action_uuid })
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
  })

  it('keeps an unacknowledged online scan pending and retries the original UUID after a lost response', async () => {
    const eventId = 92001
    const device = { id: 91, identifier: 'lost-ack-scanner', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const ticket = { ticket_id: 501, state: 'valid', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('lost-ack-qr') }
    const manifest = await signedManifest(eventId, [ticket])
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/organizer/events'
      ? { events: [{ id: eventId, title: 'Lost ACK Event' }] }
      : url.endsWith('/manifest') ? manifest : { counts: {}, permissions: {}, recent_actions: [] } }))
    const sent = []
    let loseResponse
    let acknowledge
    apiClient.post.mockImplementation((url, payload) => {
      if (!url.endsWith('/sync')) return Promise.resolve({ data: device })
      sent.push(payload.actions)
      return sent.length === 1 ? new Promise((_resolve, reject) => { loseResponse = () => reject(new Error('Response lost')) })
        : new Promise(resolve => { acknowledge = () => resolve({ data: { device: { ...device, last_sequence: sent[1][0].sequence },
          results: [{ ...sent[1][0], result: 'accepted', reason_code: 'admitted' }], summary: {} } }) })
    })
    render(<ScannerPage />)
    await screen.findByText(/Manifest v1/)
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Ticket QR credential'), 'lost-ack-qr')
    await user.click(screen.getByRole('button', { name: 'Validate' }))
    await screen.findByText('Waiting for server confirmation')
    await waitFor(() => expect(loseResponse).toBeDefined())
    await act(async () => loseResponse())
    expect(await queuedActions(eventId, device.id)).toHaveLength(1)
    expect(screen.queryByText('Admission confirmed')).not.toBeInTheDocument()
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
    await user.click(screen.getByRole('button', { name: 'Sync now' }))
    await waitFor(() => expect(sent).toHaveLength(2))
    expect(sent[1]).toEqual(sent[0])
    // A duplicate while waiting may change the message, but retains this command's receipt identity.
    await user.type(screen.getByLabelText('Ticket QR credential'), 'lost-ack-qr')
    await user.click(screen.getByRole('button', { name: 'Validate' }))
    await screen.findByText('Already scanned on this device')
    await act(async () => acknowledge())
    await screen.findByText('Admission confirmed')
    expect(await queuedActions(eventId, device.id)).toHaveLength(0)
    expect(sent).toHaveLength(2)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
  })

  it('retains signed offline provisional admission without claiming a server acknowledgement', async () => {
    const eventId = 92001
    const device = { id: 91, identifier: 'offline-scanner', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const ticket = { ticket_id: 501, state: 'valid', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('offline-qr') }
    await saveDevice(eventId, device)
    await saveVerifiedManifest(await signedManifest(eventId, [ticket]))
    window.localStorage.setItem('hafapass_scanner_event_id', String(eventId))
    render(<ScannerPage offlineOnly />)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Start QR scanner' })).toBeEnabled())
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Ticket QR credential'), 'offline-qr')
    await user.click(screen.getByRole('button', { name: 'Validate' }))
    expect(await screen.findByText('Admitted offline')).toBeInTheDocument()
    expect(screen.getByText(/Other offline scanners cannot see this admission until they sync/)).toBeInTheDocument()
    expect(screen.queryByText('Admission confirmed')).not.toBeInTheDocument()
    expect(await queuedActions(eventId, device.id)).toMatchObject([{ source: 'offline' }])
    expect(apiClient.post).not.toHaveBeenCalled()
  })

  it.each(['accepted', 'rejected'])('retains the %s ACK when an in-flight sync drains a new scan before its count refresh returns', async verdict => {
    const eventId = 92001
    const device = { id: 91, identifier: 'in-flight-scanner', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const tickets = await Promise.all([501, 502].map(async ticket_id => ({ ticket_id, code: `HP-T${ticket_id}`, state: 'valid',
      attendee_name: ticket_id === 501 ? 'First Guest' : 'Second Guest', ticket_type: 'General', credential_hash: await sha256Hex(`in-flight-${ticket_id}`) })))
    const manifest = await signedManifest(eventId, tickets)
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/organizer/events'
      ? { events: [{ id: eventId, title: 'In-flight Event' }] }
      : url.endsWith('/manifest') ? manifest : { counts: {}, permissions: {}, recent_actions: [] } }))
    let acknowledgeFirst
    const sent = []
    const response = (actions, result) => ({ data: { device: { ...device, last_sequence: actions.at(-1).sequence }, summary: {},
      results: actions.map(action => ({ ...action, result, reason_code: result === 'accepted' ? 'admitted' : 'refund_pending' })) } })
    apiClient.post.mockImplementation((url, payload) => {
      if (!url.endsWith('/sync')) return Promise.resolve({ data: device })
      sent.push(payload.actions)
      return sent.length === 1 ? new Promise(resolve => { acknowledgeFirst = () => resolve(response(payload.actions, 'accepted')) })
        : Promise.resolve(response(payload.actions, verdict))
    })
    render(<ScannerPage />)
    await screen.findByText(/Manifest v1/)
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Ticket QR credential'), 'in-flight-501')
    await user.click(screen.getByRole('button', { name: 'Validate' }))
    await waitFor(() => expect(acknowledgeFirst).toBeDefined())
    const originalQueued = admissionStore.queuedActions
    let releaseCount
    let holdNext = true
    vi.spyOn(admissionStore, 'queuedActions').mockImplementation(async (...args) => {
      const actions = await originalQueued(...args)
      if (holdNext && actions.some(action => action.ticket_id === 502)) {
        holdNext = false
        await new Promise(resolve => { releaseCount = resolve })
      }
      return actions
    })
    await user.type(screen.getByLabelText('Ticket QR credential'), 'in-flight-502')
    await user.click(screen.getByRole('button', { name: 'Validate' }))
    await waitFor(() => expect(releaseCount).toBeDefined())
    await act(async () => acknowledgeFirst())
    await waitFor(async () => expect(await originalQueued(eventId, device.id)).toHaveLength(0))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
    await act(async () => releaseCount())
    expect(await screen.findByText(verdict === 'accepted' ? 'Admission confirmed' : 'Refund pending — do not admit')).toBeInTheDocument()
    expect(screen.queryByText('Waiting for server confirmation')).not.toBeInTheDocument()
    expect(screen.getByText(/Second Guest · General · HP-T502/)).toBeInTheDocument()
    await waitFor(() => expect(screen.getByTestId('scanner-pending-count')).toHaveTextContent('0'))
    expect(await localScanState(eventId, 502)).toMatchObject({ status: verdict, action_uuid: sent[1][0].action_uuid })
    expect(sent.map(batch => batch[0].ticket_id)).toEqual([501, 502])
  })

  it.each(['accepted', 'rejected'])('renders the exact durable %s receipt committed before queueAdmission returns', async verdict => {
    const eventId = 92001
    const device = { id: 91, identifier: 'peer-ack-scanner', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const ticket = { ticket_id: 501, code: 'HP-T501', state: 'valid', attendee_name: 'Peer ACK Guest', ticket_type: 'General', credential_hash: await sha256Hex('peer-ack-qr') }
    const manifest = await signedManifest(eventId, [ticket])
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/organizer/events'
      ? { events: [{ id: eventId, title: 'Peer ACK Event' }] }
      : url.endsWith('/manifest') ? manifest : { counts: {}, permissions: {}, recent_actions: [] } }))
    apiClient.post.mockResolvedValue({ data: device })
    const originalQueue = admissionStore.queueAdmission
    let action, acknowledged
    vi.spyOn(admissionStore, 'queueAdmission').mockImplementation(async input => {
      action = await originalQueue(input)
      acknowledged = await applySyncResults(eventId, device, [{ action_uuid: action.action_uuid, ticket_id: ticket.ticket_id,
        kind: 'admit', result: verdict, reason_code: verdict === 'accepted' ? 'admitted' : 'refund_pending' }])
      return action
    })
    render(<ScannerPage />)
    await screen.findByText(/Manifest v1/)
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Ticket QR credential'), 'peer-ack-qr')
    await user.click(screen.getByRole('button', { name: 'Validate' }))
    await waitFor(() => expect(acknowledged).toBe(1))
    expect(await screen.findByText(verdict === 'accepted' ? 'Admission confirmed' : 'Refund pending — do not admit')).toBeInTheDocument()
    expect(screen.queryByText('Waiting for server confirmation')).not.toBeInTheDocument()
    expect(await queuedActions(eventId, device.id)).toHaveLength(0)
    expect(await localScanState(eventId, ticket.ticket_id)).toMatchObject({ status: verdict, action_uuid: action.action_uuid })
    expect(apiClient.post.mock.calls.some(([url]) => url.endsWith('/sync'))).toBe(false)
  })

  it.each(['accepted', 'rejected'])('rechecks the exact %s receipt after a peer drains the queue following a pending receipt read', async verdict => {
    const eventId = 92001
    const device = { id: 91, identifier: 'between-reads-scanner', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const ticket = { ticket_id: 501, state: 'valid', attendee_name: 'Between Reads Guest', ticket_type: 'General', credential_hash: await sha256Hex('between-reads-qr') }
    const manifest = await signedManifest(eventId, [ticket])
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/organizer/events'
      ? { events: [{ id: eventId, title: 'Between Reads Event' }] }
      : url.endsWith('/manifest') ? manifest : { counts: {}, permissions: {}, recent_actions: [] } }))
    apiClient.post.mockResolvedValue({ data: device })
    const originalState = admissionStore.localScanState
    let acknowledged
    vi.spyOn(admissionStore, 'localScanState').mockImplementation(async (...args) => {
      const receipt = await originalState(...args)
      if (receipt?.status === 'pending' && acknowledged === undefined) {
        acknowledged = await applySyncResults(eventId, device, [{ action_uuid: receipt.action_uuid, ticket_id: 501,
          kind: 'admit', result: verdict, reason_code: verdict === 'accepted' ? 'admitted' : 'refund_pending' }])
      }
      return receipt
    })
    render(<ScannerPage />)
    await screen.findByText(/Manifest v1/)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Ticket QR credential'), 'between-reads-qr')
    await user.click(screen.getByRole('button', { name: 'Validate' }))
    await waitFor(() => expect(acknowledged).toBe(1))
    expect(await screen.findByText(verdict === 'accepted' ? 'Admission confirmed' : 'Refund pending — do not admit')).toBeInTheDocument()
    expect(screen.queryByText('Waiting for server confirmation')).not.toBeInTheDocument()
    expect(screen.getByTestId('scanner-pending-count')).toHaveTextContent('0')
    expect(await queuedActions(eventId, device.id)).toHaveLength(0)
    expect(apiClient.post.mock.calls.some(([url]) => url.endsWith('/sync'))).toBe(false)
  })

  it.each(['accepted', 'rejected'])('resolves the latest %s receipt when its own sync was busy with an older command', async verdict => {
    const eventId = 92001
    const device = { id: 91, identifier: 'busy-sync-scanner', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const tickets = await Promise.all([501, 502].map(async ticket_id => ({ ticket_id, code: `HP-T${ticket_id}`, state: 'valid',
      attendee_name: `Guest ${ticket_id}`, ticket_type: 'General', credential_hash: await sha256Hex(`busy-sync-${ticket_id}`) })))
    const manifest = await signedManifest(eventId, tickets)
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/organizer/events'
      ? { events: [{ id: eventId, title: 'Busy Sync Event' }] }
      : url.endsWith('/manifest') ? manifest : { counts: {}, permissions: {}, recent_actions: [] } }))
    let finishOlder
    let syncCalls = 0
    apiClient.post.mockImplementation((url, payload) => {
      if (!url.endsWith('/sync')) return Promise.resolve({ data: device })
      syncCalls += 1
      return new Promise(resolve => { finishOlder = () => resolve({ data: { device: { ...device, last_sequence: 2 }, summary: {},
        results: payload.actions.map(action => ({ ...action, result: 'accepted', reason_code: 'admitted' })) } }) })
    })
    render(<ScannerPage />)
    await screen.findByText(/Manifest v1/)
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Ticket QR credential'), 'busy-sync-501')
    await user.click(screen.getByRole('button', { name: 'Validate' }))
    await waitFor(() => expect(finishOlder).toBeDefined())
    const originalState = admissionStore.localScanState
    let acknowledged
    vi.spyOn(admissionStore, 'localScanState').mockImplementation(async (...args) => {
      const receipt = await originalState(...args)
      if (Number(args[1]) === 502 && receipt?.status === 'pending' && acknowledged === undefined) {
        acknowledged = await applySyncResults(eventId, device, [{ action_uuid: receipt.action_uuid, ticket_id: 502,
          kind: 'admit', result: verdict, reason_code: verdict === 'accepted' ? 'admitted' : 'refund_pending' }])
      }
      return receipt
    })
    await user.type(screen.getByLabelText('Ticket QR credential'), 'busy-sync-502')
    await user.click(screen.getByRole('button', { name: 'Validate' }))
    await waitFor(() => expect(acknowledged).toBe(1))
    expect(screen.getByText('Waiting for server confirmation')).toBeInTheDocument()
    await act(async () => finishOlder())
    expect(await screen.findByText(verdict === 'accepted' ? 'Admission confirmed' : 'Refund pending — do not admit')).toBeInTheDocument()
    expect(screen.getByText(/Guest 502 · General · HP-T502/)).toBeInTheDocument()
    expect(await queuedActions(eventId, device.id)).toHaveLength(0)
    expect(syncCalls).toBe(1)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
  })

  it('does not let an older refused handler replace the newer same-ticket accepted command', async () => {
    const eventId = 92001
    const device = { id: 91, identifier: 'later-command-scanner', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const ticket = { ticket_id: 501, state: 'valid', attendee_name: 'Later Guest', ticket_type: 'General', credential_hash: await sha256Hex('later-command-qr') }
    const manifest = await signedManifest(eventId, [ticket])
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/organizer/events'
      ? { events: [{ id: eventId, title: 'Later Command Event' }] }
      : url.endsWith('/manifest') ? manifest : { counts: {}, permissions: {}, recent_actions: [] } }))
    apiClient.post.mockResolvedValue({ data: device })
    const originalQueue = admissionStore.queueAdmission
    const actions = []
    let releaseFirst
    vi.spyOn(admissionStore, 'queueAdmission').mockImplementation(async input => {
      const action = await originalQueue(input)
      actions.push(action)
      const first = actions.length === 1
      await applySyncResults(eventId, device, [{ action_uuid: action.action_uuid, ticket_id: ticket.ticket_id,
        kind: 'admit', result: first ? 'rejected' : 'accepted', reason_code: first ? 'refund_pending' : 'admitted' }])
      if (first) await new Promise(resolve => { releaseFirst = resolve })
      return action
    })
    render(<ScannerPage />)
    await screen.findByText(/Manifest v1/)
    const user = userEvent.setup()
    for (let index = 0; index < 2; index += 1) {
      await user.type(screen.getByLabelText('Ticket QR credential'), 'later-command-qr')
      await user.click(screen.getByRole('button', { name: 'Validate' }))
      if (index === 0) await waitFor(() => expect(releaseFirst).toBeDefined())
    }
    await screen.findByText('Admission confirmed')
    await act(async () => releaseFirst())
    expect(screen.getByText('Admission confirmed')).toBeInTheDocument()
    expect(screen.queryByText('Waiting for server confirmation')).not.toBeInTheDocument()
    expect(await localScanState(eventId, ticket.ticket_id)).toMatchObject({ status: 'accepted', action_uuid: actions[1].action_uuid })
    expect(await queuedActions(eventId, device.id)).toHaveLength(0)
  })

  it('keeps the older unknown journal while its late handler cannot overwrite the newer accepted result', async () => {
    const eventId = 92001
    const device = { id: 91, identifier: 'unknown-journal-scanner', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const tickets = await Promise.all([501, 502].map(async ticket_id => ({ ticket_id, code: `HP-T${ticket_id}`, state: 'valid',
      attendee_name: `Guest ${ticket_id}`, ticket_type: 'General', credential_hash: await sha256Hex(`unknown-${ticket_id}`) })))
    const manifest = await signedManifest(eventId, tickets)
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/organizer/events'
      ? { events: [{ id: eventId, title: 'Unknown Journal Event' }] }
      : url.endsWith('/manifest') ? manifest : { counts: {}, permissions: {}, recent_actions: [] } }))
    apiClient.post.mockImplementation(url => url.endsWith('/sync') ? Promise.reject(new Error('Response unavailable')) : Promise.resolve({ data: device }))
    const originalQueue = admissionStore.queueAdmission
    const actions = []
    let releaseFirst
    vi.spyOn(admissionStore, 'queueAdmission').mockImplementation(async input => {
      const action = await originalQueue(input)
      actions.push(action)
      if (action.ticket_id === 501) await new Promise(resolve => { releaseFirst = resolve })
      else await applySyncResults(eventId, device, [{ action_uuid: action.action_uuid, ticket_id: 502, kind: 'admit', result: 'accepted' }])
      return action
    })
    render(<ScannerPage />)
    await screen.findByText(/Manifest v1/)
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Ticket QR credential'), 'unknown-501')
    await user.click(screen.getByRole('button', { name: 'Validate' }))
    await waitFor(() => expect(releaseFirst).toBeDefined())
    await user.type(screen.getByLabelText('Ticket QR credential'), 'unknown-502')
    await user.click(screen.getByRole('button', { name: 'Validate' }))
    await screen.findByText('Admission confirmed')
    await act(async () => releaseFirst())
    expect(screen.getByText('Admission confirmed')).toBeInTheDocument()
    expect(screen.getByText(/Guest 502 · General · HP-T502/)).toBeInTheDocument()
    expect(await queuedActions(eventId, device.id)).toMatchObject([{ action_uuid: actions[0].action_uuid, ticket_id: 501 }])
    expect(await localScanState(eventId, 501)).toMatchObject({ status: 'pending', action_uuid: actions[0].action_uuid })
    expect(await localScanState(eventId, 502)).toMatchObject({ status: 'accepted', action_uuid: actions[1].action_uuid })
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
  })

  it('blocks a pending-refund ticket from a freshly verified manifest without queuing admission', async () => {
    const eventId = 92001
    const device = { id: 91, identifier: 'refund-device', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const ticket = { ticket_id: 501, state: 'refund_pending', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('refund-qr') }
    await saveDevice(eventId, device)
    await saveVerifiedManifest(await signedManifest(eventId, [ticket]))
    window.localStorage.setItem('hafapass_scanner_event_id', String(eventId))
    apiClient.get.mockRejectedValue(new Error('API unavailable'))
    apiClient.post.mockRejectedValue(new Error('API unavailable'))
    render(<ScannerPage />)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Start QR scanner' })).toBeEnabled())
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Ticket QR credential'), 'refund-qr')
    await user.click(screen.getByRole('button', { name: 'Validate' }))
    expect(await screen.findByText('Refund pending — do not admit')).toBeInTheDocument()
    expect(await queuedActions(eventId, device.id)).toHaveLength(0)
  })

  it('shows the pending-refund refusal when a scan from an older valid manifest is reconciled online', async () => {
    const eventId = 92001
    const device = { id: 91, identifier: 'old-refund-device', effective: true, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const ticket = { ticket_id: 501, state: 'valid', attendee_name: 'Guest', ticket_type: 'General', credential_hash: await sha256Hex('old-refund-qr') }
    const original = await signedManifest(eventId, [ticket])
    const updated = await signedManifest(eventId, [{ ...ticket, state: 'refund_pending' }], { version: 2 })
    let currentManifest = original
    apiClient.get.mockImplementation(url => {
      if (url === '/organizer/events') return Promise.resolve({ data: { events: [{ id: eventId, title: 'Refund Event' }] } })
      if (url.endsWith('/manifest')) return Promise.resolve({ data: currentManifest })
      return Promise.resolve({ data: { counts: {}, permissions: {}, recent_actions: [] } })
    })
    apiClient.post.mockImplementation((url, payload) => {
      if (!url.endsWith('/sync')) return Promise.resolve({ data: device })
      currentManifest = updated
      const action = payload.actions[0]
      return Promise.resolve({ data: { device: { ...device, last_sequence: action.sequence }, summary: {}, results: [{
        action_uuid: action.action_uuid, ticket_id: 501, kind: 'admit', result: 'rejected', reason_code: 'refund_pending',
      }] } })
    })
    render(<ScannerPage />)
    await screen.findByText(/Manifest v1/)
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Ticket QR credential'), 'old-refund-qr')
    await user.click(screen.getByRole('button', { name: 'Validate' }))
    expect(await screen.findByText('Refund pending — do not admit')).toBeInTheDocument()
    await waitFor(() => expect(screen.getByTestId('scanner-pending-count')).toHaveTextContent('0'))
    expect(await localScanState(eventId, ticket.ticket_id)).toMatchObject({ status: 'rejected' })
  })

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
    await screen.findByText('Waiting for server confirmation')
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
    await user.click(await screen.findByRole('button', { name: 'Undo admission for HP-T501' }))
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
    await screen.findByText('Waiting for server confirmation')
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
