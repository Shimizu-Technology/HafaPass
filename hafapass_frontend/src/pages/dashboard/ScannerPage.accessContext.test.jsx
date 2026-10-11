import 'fake-indexeddb/auto'
import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { AxiosError } from 'axios'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const auth = vi.hoisted(() => ({ userId: 'staff-a', sessionId: 'session-a', getToken: vi.fn() }))
async function findManifest(version) {
  const summary = await screen.findByText('Device details', { exact: true })
  if (!summary.closest('details').open) await userEvent.click(summary)
  return screen.findByText(new RegExp(`Manifest v${version}`))
}

vi.mock('@clerk/clerk-react', () => ({
  ClerkProvider: ({ children }) => children,
  useAuth: () => ({ isLoaded: true, ...auth }),
  useUser: () => ({ isLoaded: true, isSignedIn: true, user: { id: auth.userId } }),
}))
vi.mock('../../monitoring', () => ({ Sentry: { setUser: vi.fn(), captureException: vi.fn() } }))

const deferred = () => {
  let resolve, reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}
const response = (config, data) => ({ config, data, status: 200, statusText: 'OK', headers: {} })
let api, store, Wrapper, Scanner, signedManifest
const eventId = 95501
const device = id => ({ id, identifier: `context-${id}`, effective: true, last_sequence: 0,
  authorization_expires_at: new Date(Date.now() + 600_000).toISOString() })
const ticket = { ticket_id: 501, code: 'HP-T501', state: 'valid', attendee_name: 'Synthetic Guest',
  ticket_type: 'Admission', credential_hash: 'c'.repeat(64) }
function view() {
  return <MemoryRouter><Wrapper><Scanner /></Wrapper></MemoryRouter>
}

beforeEach(async () => {
  vi.resetModules()
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_scanner_context')
  window.localStorage.clear()
  Object.assign(auth, { userId: 'staff-a', sessionId: 'session-a', getToken: vi.fn().mockResolvedValue('synthetic-token-a') })
  ;({ default: api } = await import('../../api/client'))
  store = await import('../../utils/admissionStore')
  ;({ default: Wrapper } = await import('../../components/ClerkProviderWrapper'))
  ;({ default: Scanner } = await import('./ScannerPage'))
  ;({ signedManifest } = await import('../../test/manifestFixture'))
  await store.clearAllAdmissionData()
  await store.clearEventAdmissionData(eventId)
})
afterEach(async () => {
  vi.restoreAllMocks()
  await store.clearAllAdmissionData()
  for (const owner of ['staff-a', 'staff-b']) {
    window.localStorage.setItem('hafapass_scanner_user_id', owner)
    await store.clearEventAdmissionData(eventId)
  }
  window.localStorage.clear()
  vi.unstubAllEnvs()
})

describe('scanner setup refusal with the real Clerk wrapper and Axios interceptor', () => {
  it('disables offline entry for a known terminal revoked ACK despite a peer lease and another unknown scan', async () => {
    const oldDevice = { ...device(91), status: 'active', authorization_expires_at: new Date(Date.now() + 60_000).toISOString() }
    const renewedDevice = { ...oldDevice, authorization_expires_at: new Date(Date.now() + 3_600_000).toISOString() }
    const tickets = await Promise.all([501, 503].map(async ticket_id => ({ ...ticket, ticket_id,
      credential_hash: await store.sha256Hex(`terminal-qr-${ticket_id}`) })))
    let currentManifest = await signedManifest(eventId, tickets)
    const held = deferred()
    let action, ackConfig
    let syncCalls = 0
    api.defaults.adapter = vi.fn(config => {
      if (config.url.endsWith('/sync')) {
        if (++syncCalls === 1) { action = JSON.parse(config.data).actions[0]; ackConfig = config; return held.promise }
        return Promise.reject(new AxiosError('Remaining scan outcome unknown', undefined, config, null,
          { config, status: 503, data: {}, headers: {} }))
      }
      return Promise.resolve(response(config, config.url === '/organizer/events'
        ? { events: [{ id: eventId, title: 'Context event' }] } : config.url === '/me' ? { id: 1, clerk_id: 'staff-a' }
          : config.url.endsWith('/scanner_devices') ? oldDevice : config.url.endsWith('/manifest') ? currentManifest
            : { counts: {}, permissions: {}, recent_actions: [] }))
    })
    const mounted = render(view())
    await findManifest(1)
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Ticket QR code'), 'terminal-qr-501')
    await user.click(screen.getByRole('button', { name: 'Check ticket', exact: true }))
    await waitFor(() => expect(action).toBeDefined())
    await store.saveDevice(eventId, renewedDevice, { context: await store.captureAdmissionAccessContext(eventId) })
    currentManifest = await signedManifest(eventId, [{ ...tickets[0], state: 'admitted' }, tickets[1]],
      { version: 2, expires_at: renewedDevice.authorization_expires_at })
    await store.saveVerifiedManifest(currentManifest)
    const unknown = await store.queueAdmission({ eventId, deviceId: 91, manifestVersion: 2,
      ticket: { ...ticket, ticket_id: 502 }, credentialHash: 'd'.repeat(64), source: 'offline' })
    // Revocation commits after the accepted action and peer renewal, before the
    // controller reloads its device DTO. The remaining request loses its ACK.
    await act(async () => held.resolve(response(ackConfig, { device: { ...renewedDevice, status: 'revoked', effective: false,
      last_sequence: action.sequence }, results: [{ ...action, result: 'accepted', reason_code: 'admitted' }], summary: {} })))
    await screen.findByText('Admission confirmed')
    await waitFor(() => expect(syncCalls).toBe(2))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' }).querySelector('.animate-spin')).toBeNull())
    await act(async () => window.dispatchEvent(new Event('offline')))
    await waitFor(() => expect(screen.queryByText('Authorizing device and verifying manifest…')).not.toBeInTheDocument())
    const entry = screen.getByLabelText('Ticket QR code')
    if (!entry.disabled) {
      await user.type(entry, 'terminal-qr-503')
      await user.click(screen.getByRole('button', { name: 'Check ticket', exact: true }))
      await screen.findByText('Admitted offline')
    }
    expect(entry).toBeDisabled()
    expect(screen.queryByText('Admitted offline')).not.toBeInTheDocument()
    expect((await store.loadDevice(eventId)).status).toBe('revoked')
    expect(await store.loadAuthorizedScanner(eventId)).toBeNull()
    expect((await store.queuedActions(eventId, 91)).map(item => item.action_uuid)).toEqual([unknown.action_uuid])
    expect(await store.loadPendingDeviceIdentity(eventId)).toMatchObject({ device_id: 91 })
    mounted.unmount()
  })

  it.each([false, true])('uses the manifest GET context for a refusal after an older ACK (peer refresh during GET: %s)', async refreshedAgain => {
    const oldDevice = { ...device(91), authorization_expires_at: new Date(Date.now() + 60_000).toISOString() }
    const renewedDevice = { ...oldDevice, authorization_expires_at: new Date(Date.now() + 3_600_000).toISOString() }
    const firstTicket = { ...ticket, credential_hash: await store.sha256Hex('manifest-refusal-qr') }
    const originalManifest = await signedManifest(eventId, [firstTicket])
    const heldAck = deferred()
    const heldManifest = deferred()
    let action, ackConfig, manifestConfig
    let downloads = 0
    api.defaults.adapter = vi.fn(config => {
      if (config.url.endsWith('/sync')) { action = JSON.parse(config.data).actions[0]; ackConfig = config; return heldAck.promise }
      if (config.url.endsWith('/manifest') && ++downloads > 1) { manifestConfig = config; return heldManifest.promise }
      return Promise.resolve(response(config, config.url === '/organizer/events'
        ? { events: [{ id: eventId, title: 'Context event' }] } : config.url === '/me' ? { id: 1, clerk_id: 'staff-a' }
          : config.url.endsWith('/scanner_devices') ? oldDevice : config.url.endsWith('/manifest') ? originalManifest
            : { counts: {}, permissions: {}, recent_actions: [] }))
    })
    const mounted = render(view())
    await findManifest(1)
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Ticket QR code'), 'manifest-refusal-qr')
    await user.click(screen.getByRole('button', { name: 'Check ticket', exact: true }))
    await waitFor(() => expect(action).toBeDefined())
    await store.saveDevice(eventId, renewedDevice, { context: await store.captureAdmissionAccessContext(eventId) })
    await store.saveVerifiedManifest(await signedManifest(eventId, [{ ...firstTicket, state: 'admitted' }],
      { version: 2, expires_at: renewedDevice.authorization_expires_at }))
    await act(async () => heldAck.resolve(response(ackConfig, { device: { ...oldDevice, last_sequence: action.sequence },
      results: [{ ...action, result: 'accepted', reason_code: 'admitted' }], summary: {} })))
    await waitFor(() => expect(manifestConfig).toBeDefined())
    if (refreshedAgain) {
      const newest = { ...renewedDevice, authorization_expires_at: new Date(Date.now() + 7_200_000).toISOString() }
      await store.saveDevice(eventId, newest, { context: await store.captureAdmissionAccessContext(eventId) })
      await store.saveVerifiedManifest(await signedManifest(eventId, [{ ...firstTicket, state: 'admitted' }],
        { version: 3, expires_at: newest.authorization_expires_at }))
    }
    const unknown = await store.queueAdmission({ eventId, deviceId: 91, manifestVersion: refreshedAgain ? 3 : 2,
      ticket: { ...firstTicket, ticket_id: 502 }, credentialHash: 'd'.repeat(64), source: 'offline' })
    await act(async () => heldManifest.reject(new AxiosError('Current manifest access refused', undefined, manifestConfig, null,
      { config: manifestConfig, status: 403, data: { error: 'Current manifest access refused' }, headers: {} })))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' }).querySelector('.animate-spin')).toBeNull())
    if (refreshedAgain) {
      expect((await store.loadAuthorizedScanner(eventId)).manifest.payload.version).toBe(3)
      expect(screen.queryByText('Current manifest access refused')).not.toBeInTheDocument()
    } else {
      await screen.findByText('Current manifest access refused')
      expect(await store.loadAuthorizedScanner(eventId)).toBeNull()
    }
    expect((await store.queuedActions(eventId, 91)).map(item => item.action_uuid)).toEqual([unknown.action_uuid])
    expect(await store.loadPendingDeviceIdentity(eventId)).toMatchObject({ device_id: 91 })
    mounted.unmount()
  })

  it.each(['accepted', 'rejected'])('uses the retained peer lease after an old %s receipt, even while another saved scan remains unknown', async verdict => {
    const now = Date.now()
    const oldDevice = { ...device(91), authorization_expires_at: new Date(now + 60_000).toISOString() }
    const renewedDevice = { ...oldDevice, authorization_expires_at: new Date(now + 3_600_000).toISOString() }
    const hash = await store.sha256Hex('late-ACK-qr')
    const firstTicket = { ...ticket, credential_hash: hash }
    const guardedTicket = { ...ticket, ticket_id: 503, credential_hash: await store.sha256Hex('peer-guard-qr') }
    let currentManifest = await signedManifest(eventId, [firstTicket, guardedTicket], { expires_at: renewedDevice.authorization_expires_at })
    const held = deferred()
    let original
    let syncCalls = 0
    api.defaults.adapter = vi.fn(config => {
      if (config.url.endsWith('/sync')) {
        syncCalls += 1
        if (syncCalls === 1) { original = JSON.parse(config.data).actions[0]; return held.promise }
        return Promise.reject(new AxiosError('Other saved scan remains unknown', undefined, config, null,
          { config, status: 503, data: {}, headers: {} }))
      }
      return Promise.resolve(response(config, config.url === '/organizer/events'
        ? { events: [{ id: eventId, title: 'Context event' }] } : config.url === '/me' ? { id: 1, clerk_id: 'staff-a' }
          : config.url.endsWith('/scanner_devices') ? oldDevice : config.url.endsWith('/manifest') ? currentManifest
            : { counts: {}, permissions: {}, recent_actions: [] }))
    })
    const mounted = render(view())
    await findManifest(1)
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Ticket QR code'), 'late-ACK-qr')
    await user.click(screen.getByRole('button', { name: 'Check ticket', exact: true }))
    await waitFor(() => expect(original).toBeDefined())
    const peerContext = await store.captureAdmissionAccessContext(eventId)
    await store.saveDevice(eventId, renewedDevice, { context: peerContext })
    const guardContext = await store.captureAdmissionAccessContext(eventId)
    const guarded = await store.queueAdmission({ eventId, deviceId: 91, manifestVersion: 1,
      ticket: guardedTicket, credentialHash: guardedTicket.credential_hash, source: 'online' })
    await store.applySyncResults(eventId, { ...renewedDevice, last_sequence: guarded.sequence }, [{ action_uuid: guarded.action_uuid,
      ticket_id: 503, kind: 'admit', result: 'accepted' }], 'staff-a', { context: guardContext })
    currentManifest = await signedManifest(eventId, [{ ...firstTicket, state: verdict === 'accepted' ? 'admitted' : 'refund_pending' },
      { ...guardedTicket, state: 'admitted' }],
      { version: 2, expires_at: renewedDevice.authorization_expires_at })
    await store.saveVerifiedManifest(currentManifest)
    const unknown = await store.queueAdmission({ eventId, deviceId: 91, manifestVersion: 2,
      ticket: { ...firstTicket, ticket_id: 502 }, credentialHash: 'd'.repeat(64), source: 'offline' })
    await act(async () => held.resolve(response({}, { device: { ...oldDevice, last_sequence: original.sequence },
      results: [{ ...original, result: verdict, reason_code: verdict === 'accepted' ? 'admitted' : 'refund_pending' }], summary: {} })))
    await screen.findByText(verdict === 'accepted' ? 'Admission confirmed' : 'Refund pending — do not admit')
    await waitFor(() => expect(syncCalls).toBe(2))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
    vi.spyOn(Date, 'now').mockReturnValue(now + 61_000)
    await user.type(screen.getByLabelText('Ticket QR code'), 'peer-guard-qr')
    await user.click(screen.getByRole('button', { name: 'Check ticket', exact: true }))
    await screen.findByText('Already scanned on this device')
    expect(screen.queryByText('Scanner unavailable')).not.toBeInTheDocument()
    expect((await store.loadAuthorizedScanner(eventId)).device.authorization_expires_at).toBe(renewedDevice.authorization_expires_at)
    expect((await store.queuedActions(eventId, 91)).map(action => action.action_uuid)).toEqual([unknown.action_uuid])
    expect((await store.localScanState(eventId, 501)).action_uuid).toBe(original.action_uuid)
    mounted.unmount()
  })

  it.each([['timer', false], ['timer', true], ['lookup', false], ['lookup', true]])(
    'binds %s expiry to its original snapshot (peer renewed: %s)', async (method, peerRenewed) => {
      const prepared = device(91)
      const manifest = await signedManifest(eventId, [ticket])
      const expiryCallbacks = []
      const originalTimeout = window.setTimeout.bind(window)
      vi.spyOn(window, 'setTimeout').mockImplementation((callback, delay, ...args) => {
        if (delay > 590_000) expiryCallbacks.push(callback)
        return originalTimeout(callback, delay, ...args)
      })
      api.defaults.adapter = vi.fn(config => Promise.resolve(response(config,
        config.url === '/organizer/events' ? { events: [{ id: eventId, title: 'Context event' }] }
          : config.url === '/me' ? { id: 1, clerk_id: 'staff-a' }
            : config.url.endsWith('/scanner_devices') ? prepared
              : config.url.endsWith('/manifest') ? manifest
                : config.url.endsWith('/search') ? [{ id: 501, code: 'HP-T501', attendee_name: 'Synthetic Guest',
                  ticket_type: 'Admission', status: 'issued', admission_allowed: true }]
                  : { counts: {}, permissions: {}, recent_actions: [] })))
      const mounted = render(view())
      await findManifest(1)
      await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
      // Settle the automatic empty-journal sync before injecting a scan that
      // must remain unknown. The first ready render can precede that sync's
      // IndexedDB read; an explicit interaction also flushes its busy state.
      const user = userEvent.setup()
      await user.click(screen.getByRole('button', { name: 'Sync now' }))
      await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
      expect(api.defaults.adapter.mock.calls.some(([config]) => config.url.endsWith('/sync'))).toBe(false)
      await waitFor(() => expect(expiryCallbacks.length).toBeGreaterThan(0))
      const timer = expiryCallbacks.at(-1)
      const unknown = await store.queueAdmission({ eventId, deviceId: 91, manifestVersion: 1,
        ticket: { ...ticket, ticket_id: 502 }, credentialHash: 'd'.repeat(64), source: 'offline' })
      if (method === 'lookup') {
        await user.type(screen.getByLabelText('Attendee name or ticket number'), 'Guest')
        await user.click(screen.getByRole('button', { name: 'Search', exact: true }))
        await screen.findByRole('button', { name: 'Admit', exact: true })
      }
      const clock = Date.now()
      vi.spyOn(Date, 'now').mockReturnValue(clock + 601_000)
      if (peerRenewed) {
        await store.saveDevice(eventId, { ...prepared, authorization_expires_at: new Date(Date.now() + 600_000).toISOString() })
        await store.saveVerifiedManifest(await signedManifest(eventId, [ticket], { version: 2 }))
      }
      if (method === 'timer') await act(async () => timer())
      else await user.click(screen.getByRole('button', { name: 'Admit', exact: true }))
      if (peerRenewed) {
        const retained = await store.loadAuthorizedScanner(eventId)
        expect(retained?.manifest.payload.version).toBe(2)
        expect(screen.queryByText('Scanner access expired')).not.toBeInTheDocument()
        expect(api.defaults.adapter.mock.calls.some(([config]) => config.url.endsWith('/sync'))).toBe(false)
      } else {
        await screen.findByText(method === 'timer'
          ? 'Saved scanner access has expired. Reconnect with the original staff account to renew access and sync saved scans.'
          : 'Scanner access expired')
        expect(await store.loadAuthorizedScanner(eventId)).toBeNull()
      }
      expect((await store.queuedActions(eventId, 91)).map(action => action.action_uuid)).toEqual([unknown.action_uuid])
      expect(await store.loadPendingDeviceIdentity(eventId)).toMatchObject({ device_id: 91 })
      mounted.unmount()
    },
  )

  it('retains a newer same-actor setup after returning to the same event before the old refusal', async () => {
    const old = deferred()
    const refused = deferred()
    let oldConfig
    let first = true
    const manifests = new Map(await Promise.all([eventId, eventId + 1].map(async id =>
      [id, await signedManifest(id, [ticket], { version: 2 })])))
    const originalPurge = store.purgeExpiredAdmissionAccess
    vi.spyOn(store, 'purgeExpiredAdmissionAccess').mockImplementation(async (...args) => {
      const result = await originalPurge(...args)
      refused.resolve()
      return result
    })
    api.defaults.adapter = vi.fn(config => {
      if (first && config.url === `/organizer/events/${eventId}/scanner_devices`) {
        first = false
        oldConfig = config
        return old.promise
      }
      if (config.url === '/organizer/events') return Promise.resolve(response(config, { events: [
        { id: eventId, title: 'Original event' }, { id: eventId + 1, title: 'Other event' },
      ] }))
      if (config.url === '/me') return Promise.resolve(response(config, { id: 1, clerk_id: 'staff-a' }))
      const selected = config.url.includes(`/${eventId + 1}/`) ? eventId + 1 : eventId
      if (config.url.endsWith('/scanner_devices')) return Promise.resolve(response(config, device(selected === eventId ? 91 : 93)))
      if (config.url.endsWith('/manifest')) return Promise.resolve(response(config, manifests.get(selected)))
      return Promise.resolve(response(config, { counts: {}, permissions: {}, recent_actions: [] }))
    })
    const mounted = render(view())
    await waitFor(() => expect(oldConfig).toBeDefined())
    const user = userEvent.setup()
    await user.selectOptions(screen.getByLabelText('Event to scan'), String(eventId + 1))
    await findManifest(2)
    await user.selectOptions(screen.getByLabelText('Event to scan'), String(eventId))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
    const admitted = await store.queueAdmission({ eventId, deviceId: 91, manifestVersion: 2,
      ticket, credentialHash: ticket.credential_hash, source: 'online' })
    await store.applySyncResults(eventId, device(91), [{ action_uuid: admitted.action_uuid, ticket_id: 501,
      kind: 'admit', result: 'accepted' }])
    await act(async () => {
      old.reject(new AxiosError('Earlier setup refused', undefined, oldConfig, null,
        { config: oldConfig, status: 403, data: { error: 'Earlier setup refused' }, headers: {} }))
      await refused.promise
    })
    expect((await store.loadAuthorizedScanner(eventId))?.device.id).toBe(91)
    expect((await store.localScanState(eventId, 501))?.action_uuid).toBe(admitted.action_uuid)
    expect(screen.queryByText('Earlier setup refused')).not.toBeInTheDocument()
    mounted.unmount()
    await store.clearEventAdmissionData(eventId + 1)
  })

  it('removes current refused access while retaining its unknown original journal', async () => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'staff-a')
    const prepared = device(91)
    await store.saveDevice(eventId, prepared)
    await store.saveVerifiedManifest(await signedManifest(eventId, [ticket]))
    const action = await store.queueAdmission({ eventId, deviceId: 91, manifestVersion: 1,
      ticket, credentialHash: ticket.credential_hash, source: 'offline' })
    api.defaults.adapter = vi.fn(config => {
      if (config.url.endsWith('/scanner_devices')) return Promise.reject(new AxiosError('Current access refused', undefined, config, null,
        { config, status: 403, data: { error: 'Current access refused' }, headers: {} }))
      return Promise.resolve(response(config, config.url === '/organizer/events'
        ? { events: [{ id: eventId, title: 'Context event' }] } : { id: 1, clerk_id: 'staff-a' }))
    })
    const mounted = render(view())
    await screen.findByText('Current access refused')
    expect(await store.loadAuthorizedScanner(eventId)).toBeNull()
    expect(await store.localScanState(eventId, 501)).toBeNull()
    expect((await store.queuedActions(eventId, 91)).map(item => item.action_uuid)).toEqual([action.action_uuid])
    expect(await store.loadPendingDeviceIdentity(eventId)).toMatchObject({ device_id: 91 })
    mounted.unmount()
  })

  it.each(['registration', 'manifest'])('retains the new actor cache and original journals after an old %s refusal', async phase => {
    const old = deferred()
    let oldConfig
    const manifest = await signedManifest(eventId, [ticket], { version: 2 })
    const refused = deferred()
    const originalPurge = store.purgeExpiredAdmissionAccess
    vi.spyOn(store, 'purgeExpiredAdmissionAccess').mockImplementation(async (...args) => {
      const result = await originalPurge(...args)
      refused.resolve()
      return result
    })
    api.defaults.adapter = vi.fn(config => {
      const a = config.headers.get('Authorization') === 'Bearer synthetic-token-a'
      const held = a && (phase === 'registration' ? config.method === 'post' && config.url.endsWith('/scanner_devices') : config.url.endsWith('/manifest'))
      if (held) { oldConfig = config; return old.promise }
      if (config.url === '/organizer/events') return Promise.resolve(response(config, { events: [{ id: eventId, title: 'Context event' }] }))
      if (config.url === '/me') return Promise.resolve(response(config, { id: a ? 1 : 2, clerk_id: a ? 'staff-a' : 'staff-b' }))
      if (config.url.endsWith('/scanner_devices')) return Promise.resolve(response(config, device(a ? 91 : 92)))
      if (config.url.endsWith('/manifest')) return Promise.resolve(response(config, manifest))
      return Promise.resolve(response(config, { counts: {}, permissions: {}, recent_actions: [] }))
    })
    const mounted = render(view())
    await waitFor(() => expect(oldConfig).toBeDefined())
    // A's unknown journal must survive the wrapper's account purge too.
    if (phase === 'registration') await store.saveDevice(eventId, device(91))
    const aAction = await store.queueAdmission({ eventId, deviceId: 91, manifestVersion: 1,
      ticket: { ...ticket, ticket_id: 500 }, credentialHash: ticket.credential_hash, source: 'offline' })
    Object.assign(auth, { userId: 'staff-b', sessionId: 'session-b', getToken: vi.fn().mockResolvedValue('synthetic-token-b') })
    mounted.rerender(view())
    await findManifest(2)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
    const bAction = await store.queueAdmission({ eventId, deviceId: 92, manifestVersion: 2,
      ticket, credentialHash: ticket.credential_hash, source: 'online' })
    await store.applySyncResults(eventId, device(92), [{ action_uuid: bAction.action_uuid, ticket_id: 501,
      kind: 'admit', result: 'accepted', reason_code: 'admitted' }])
    const unknown = await store.queueAdmission({ eventId, deviceId: 92, manifestVersion: 2,
      ticket: { ...ticket, ticket_id: 502 }, credentialHash: 'd'.repeat(64), source: 'offline' })
    await act(async () => {
      old.reject(new AxiosError('Old actor access refused', undefined, oldConfig, null,
        { config: oldConfig, status: 403, data: { error: 'Old actor access refused' }, headers: {} }))
      await refused.promise // Observe the complete actual IDB purge attempt, not a timer.
    })
    expect((await store.loadAuthorizedScanner(eventId))?.device.id).toBe(92)
    expect((await store.localScanState(eventId, 501))?.action_uuid).toBe(bAction.action_uuid)
    expect(await store.queueAdmission({ eventId, deviceId: 92, manifestVersion: 2,
      ticket, credentialHash: ticket.credential_hash, source: 'offline' })).toBeNull()
    expect((await store.queuedActions(eventId, 92)).map(action => action.action_uuid)).toEqual([unknown.action_uuid])
    expect(await store.loadPendingDeviceIdentity(eventId)).toMatchObject({ device_id: 92 })
    mounted.unmount()
    window.localStorage.setItem('hafapass_scanner_user_id', 'staff-a')
    expect((await store.queuedActions(eventId, 91)).map(action => action.action_uuid)).toEqual([aAction.action_uuid])
    expect(await store.loadPendingDeviceIdentity(eventId)).toMatchObject({ device_id: 91 })
  })
})
