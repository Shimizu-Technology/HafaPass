import 'fake-indexeddb/auto'
import { setTimeout as nativeDelay } from 'node:timers/promises'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, useNavigate } from 'react-router-dom'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { getApiAuthContext } from '../../api/client'
import { clearAllAdmissionData, clearEventAdmissionData, loadAuthorizedScanner, localScanState, queuedActions, sha256Hex } from '../../utils/admissionStore'
import { signedManifest } from '../../test/manifestFixture'
import ScannerPage from './ScannerPage'
import * as store from '../../utils/admissionStore'

vi.mock('../../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() }, getApiAuthContext: vi.fn(() => null), subscribeApiAuthContext: () => () => {} }))

function ScannerVisitControl() {
  const navigate = useNavigate()
  return <><button onClick={() => navigate('/dashboard/scanner?event=94602')}>Switch event</button><ScannerPage /></>
}

async function findManifest(version) {
  const details = await screen.findByText('Device details', { exact: true })
  if (!details.closest('details').open) await userEvent.click(details)
  return screen.findByText(new RegExp(`Saved ticket list · version ${version}`))
}

// Uses the real ScannerPage, signed manifest verification, IndexedDB journal and
// local receipt logic. Only API transport/auth is mocked, as in ScannerPage.test.
describe('online unknown credential recovery', () => {
  beforeEach(async () => {
    vi.resetAllMocks()
    window.localStorage.clear()
    window.sessionStorage.clear()
    await clearAllAdmissionData()
    for (const eventId of [94601, 94602]) await clearEventAdmissionData(eventId)
    window.localStorage.setItem('hafapass_scanner_user_id', 'synthetic-privacy-scanner')
    vi.spyOn(window.navigator, 'onLine', 'get').mockReturnValue(true)
    vi.stubGlobal('fetch', vi.fn(() => { throw new Error('External fetch prohibited in privacy repro') }))
  })
  afterEach(async () => {
    cleanup()
    await clearAllAdmissionData()
    window.localStorage.setItem('hafapass_scanner_user_id', 'synthetic-privacy-scanner')
    for (const eventId of [94601, 94602]) await clearEventAdmissionData(eventId)
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
    window.localStorage.clear()
    window.sessionStorage.clear()
  })

  it.each([['newly-issued', 94601], ['transferred-credential', 94602]])(
    'refreshes the current %s and admits once without manual sync', async (scenario, eventId) => {
      const device = { id: eventId + 100, identifier: `synthetic-${scenario}`, effective: true, last_sequence: 0,
        authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
      const known = { ticket_id: 501, state: 'valid', attendee_name: 'Known synthetic guest',
        ticket_type: 'General', credential_hash: await sha256Hex(`known-${scenario}`) }
      const currentQr = `synthetic-current-${scenario}`
      const newlyCurrent = { ticket_id: 502, state: 'valid', attendee_name: 'New synthetic holder',
        ticket_type: 'General', credential_hash: await sha256Hex(currentQr) }
      const oldTransferred = { ...newlyCurrent, attendee_name: 'Previous synthetic holder', credential_hash: await sha256Hex('old-transfer-credential') }
      const initial = await signedManifest(eventId, scenario === 'newly-issued' ? [known] : [known, oldTransferred])
      const updated = await signedManifest(eventId, [known, newlyCurrent], { version: 2 })
      const admitted = await signedManifest(eventId, [known, { ...newlyCurrent, state: 'admitted' }], { version: 3 })
      let serverManifest = initial
      const requestLog = []
      apiClient.get.mockImplementation(url => {
        requestLog.push(['GET', url, url.endsWith('/manifest') ? serverManifest.payload.version : null])
        if (url === '/me') return Promise.resolve({ data: { id: 'synthetic-privacy-scanner' } })
        if (url === '/organizer/events') return Promise.resolve({ data: { events: [{ id: eventId, title: 'Synthetic Guam GA event', timezone: 'Pacific/Guam', status: 'published' }] } })
        if (url.endsWith('/manifest')) return Promise.resolve({ data: serverManifest })
        if (url.endsWith('/admissions')) return Promise.resolve({ data: { counts: {}, permissions: { can_reverse: false }, recent_actions: [] } })
        throw new Error(`Unexpected GET ${url}`)
      })
      apiClient.post.mockImplementation((url, payload) => {
        requestLog.push(['POST', url, payload])
        if (url.endsWith('/scanner_devices')) return Promise.resolve({ data: device })
        if (url.endsWith('/sync')) {
          serverManifest = admitted
          return Promise.resolve({ data: {
            device: { ...device, last_sequence: payload.actions.at(-1).sequence },
            results: payload.actions.map(action => ({ ...action, result: 'accepted', reason_code: 'admitted' })), summary: {},
          } })
        }
        throw new Error(`Unexpected POST ${url}`)
      })
      render(<MemoryRouter initialEntries={[`/dashboard/scanner?event=${eventId}`]}><ScannerPage /></MemoryRouter>)
      await findManifest(1)
      const sync = screen.getByRole('button', { name: 'Sync now' })
      await waitFor(() => expect(sync).toBeEnabled())
      expect(screen.getByText('Online', { exact: true })).toBeInTheDocument()
      expect(await queuedActions(eventId, device.id)).toHaveLength(0)
      // Simulate a separate purchase/transfer after setup. No reconnect/remount,
      // no queued scan, and no service/provider activity occurs in this test.
      serverManifest = updated
      const beforeMiss = requestLog.length
      await act(async () => { await new Promise(resolve => setTimeout(resolve, 150)) })
      const user = userEvent.setup()
      await user.type(screen.getByLabelText('Ticket QR code'), currentQr)
      await user.click(screen.getByRole('button', { name: 'Check in ticket' }))
      expect(await screen.findByText('Admission confirmed', { exact: true })).toBeInTheDocument()
      await findManifest(2) // Quiet sync keeps the verified list; no per-scan download.
      await waitFor(() => expect(sync).toBeEnabled())
      expect(await queuedActions(eventId, device.id)).toHaveLength(0)
      expect(await localScanState(eventId, newlyCurrent.ticket_id)).toMatchObject({ status: 'accepted' })
      const syncCalls = requestLog.filter(([method, url]) => method === 'POST' && url.endsWith('/sync'))
      expect(syncCalls).toHaveLength(1)
      expect(syncCalls[0][2].actions).toMatchObject([{ ticket_id: 502, credential_hash: newlyCurrent.credential_hash, manifest_version: 2 }])
      expect(requestLog.slice(beforeMiss).filter(([method]) => method === 'GET')).toHaveLength(1)

    },
  )
  async function emptyScanner(eventId = 94601, tickets = [], manifestOptions = {}) {
    const device = { id: eventId + 100, identifier: 'freshness-door', effective: true, last_sequence: 0,
      authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const envelope = await signedManifest(eventId, tickets, manifestOptions)
    const otherEnvelope = await signedManifest(94602, [])
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/me' ? { id: 'synthetic-privacy-scanner' }
      : url === '/organizer/events' ? { events: [{ id: eventId, title: 'Freshness test', status: 'published' }, { id: 94602, title: 'Other event', status: 'published' }] }
        : url.endsWith('/manifest') ? (url.includes('/94602/') ? otherEnvelope : envelope) : { counts: {}, permissions: {}, recent_actions: [] } }))
    apiClient.post.mockResolvedValue({ data: device })
    render(<MemoryRouter initialEntries={[`/dashboard/scanner?event=${eventId}`]}><ScannerVisitControl /></MemoryRouter>)
    await findManifest(1)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
    return { device, envelope }
  }
  async function enterQr(code) {
    await userEvent.type(screen.getByLabelText('Ticket QR code'), code)
    await userEvent.click(screen.getByRole('button', { name: 'Check in ticket' }))
  }

  it('bounds repeated unfamiliar codes, while explicit empty-queue sync remains available', async () => {
    const { device } = await emptyScanner()
    apiClient.get.mockClear()
    apiClient.get.mockClear()
    await enterQr('unfamiliar-first')
    await screen.findByText('Invalid ticket')
    await enterQr('unfamiliar-second')
    await screen.findByText('Ticket not verified yet')
    expect(apiClient.get).toHaveBeenCalledTimes(1)
    expect(apiClient.get.mock.calls[0][0]).toMatch(/manifest$/)
    expect(await queuedActions(94601, device.id)).toHaveLength(0)
    await userEvent.click(screen.getByRole('button', { name: 'Sync now' }))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
    expect(apiClient.get.mock.calls.filter(([url]) => url.endsWith('/manifest'))).toHaveLength(2)
    expect(apiClient.post.mock.calls.filter(([url]) => url.endsWith('/sync'))).toHaveLength(0)
  })

  it.each([429, 503, 403, 'signature'])('preserves an empty journal and refuses entry when refresh fails: %s', async status => {
    const { device, envelope } = await emptyScanner()
    apiClient.get.mockClear()
    apiClient.get.mockImplementation(url => {
      if (!url.endsWith('/manifest')) throw new Error('Unexpected request amplification')
      if (status === 'signature') return Promise.resolve({ data: { ...envelope, signature: 'broken' } })
      return Promise.reject({ response: { status, headers: { 'retry-after': '60' }, data: { error: 'Synthetic refresh refusal' } } })
    })
    await enterQr('current-unfamiliar-credential')
    await screen.findByText('Scanner unavailable')
    expect(apiClient.get).toHaveBeenCalledTimes(1)
    expect(await queuedActions(94601, device.id)).toHaveLength(0)
    expect(apiClient.post.mock.calls.filter(([url]) => url.endsWith('/sync'))).toHaveLength(0)
    if ([429, 503].includes(status)) {
      await enterQr('another-unfamiliar-credential')
      await screen.findByText('Ticket not verified yet')
      expect(apiClient.get).toHaveBeenCalledTimes(1)
    }
  })

  it('backs off a throttled sync, retaining the same command and sequence for an explicit retry', async () => {
    const ticket = { ticket_id: 501, state: 'valid', credential_hash: await sha256Hex('known-qr') }
    const { device } = await emptyScanner(94601, [ticket])
    apiClient.post.mockImplementation(url => url.endsWith('/sync') ? Promise.reject({ response: {
      status: 429, headers: { 'retry-after': '60' }, data: { retry_after: 60 },
    } }) : Promise.resolve({ data: device }))
    await enterQr('known-qr')
    await screen.findByText('Waiting for server confirmation')
    await waitFor(() => expect(apiClient.post.mock.calls.filter(([url]) => url.endsWith('/sync'))).toHaveLength(1))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
    const before = await queuedActions(94601, device.id)
    expect(before).toHaveLength(1)
    expect(before[0].sequence).toBe(1)
    await enterQr('known-qr')
    await screen.findByText('Already scanned on this device')
    expect(apiClient.post.mock.calls.filter(([url]) => url.endsWith('/sync'))).toHaveLength(1)
    expect(await queuedActions(94601, device.id)).toEqual(before)
    await userEvent.click(screen.getByRole('button', { name: 'Sync now' }))
    await waitFor(() => expect(apiClient.post.mock.calls.filter(([url]) => url.endsWith('/sync'))).toHaveLength(2))
    expect(await queuedActions(94601, device.id)).toEqual(before)
    const payloads = apiClient.post.mock.calls.filter(([url]) => url.endsWith('/sync')).map(([, payload]) => payload)
    expect(payloads[1]).toEqual(payloads[0])
    expect(payloads[1].actions[0]).toMatchObject({ action_uuid: before[0].action_uuid, sequence: before[0].sequence })
  })

  it('keeps a verified saved list and retained journal after unknown manifest 422, then admits a known credential', async () => {
    const known = { ticket_id: 501, state: 'valid', credential_hash: await sha256Hex('known-qr') }
    const { device } = await emptyScanner(94601, [known])
    apiClient.get.mockRejectedValue({ response: { status: 422, data: { error: 'private signing key configuration / raw-token-marker' } } })
    await enterQr('unfamiliar')
    await screen.findByText('Scanner unavailable')
    expect(screen.queryByText(/raw-token-marker/)).not.toBeInTheDocument()
    expect(await queuedActions(94601, device.id)).toHaveLength(0)
    expect(await loadAuthorizedScanner(94601)).not.toBeNull()
    apiClient.post.mockImplementation((_url, payload) => Promise.resolve({ data: {
      device: { ...device, last_sequence: payload.actions.at(-1).sequence },
      results: payload.actions.map(action => ({ ...action, result: 'accepted' })), summary: {},
    } }))
    await enterQr('known-qr')
    await screen.findByText('Admission confirmed')
    expect(await queuedActions(94601, device.id)).toHaveLength(0)
    expect(await localScanState(94601, 501)).toMatchObject({ status: 'accepted' })
  })

  it('owns credential processing before deferred hashing, keeps busy manual input, and refreshes only once', async () => {
    const currentQr = 'new-credential'
    const ticket = { ticket_id: 502, state: 'valid', credential_hash: await sha256Hex(currentQr) }
    const { device } = await emptyScanner()
    apiClient.get.mockClear()
    const updated = await signedManifest(94601, [ticket], { version: 2 })
    let resolveHash, resolveRefresh
    const hashing = vi.spyOn(store, 'sha256Hex').mockImplementationOnce(() => new Promise(resolve => { resolveHash = resolve }))
    apiClient.get.mockImplementation(() => new Promise(resolve => { resolveRefresh = resolve }))
    apiClient.post.mockImplementation((_url, payload) => Promise.resolve({ data: {
      device: { ...device, last_sequence: payload.actions.at(-1).sequence },
      results: payload.actions.map(action => ({ ...action, result: 'accepted' })), summary: {},
    } }))
    const field = screen.getByLabelText('Ticket QR code')
    fireEvent.change(field, { target: { value: currentQr } })
    fireEvent.submit(field.closest('form'))
    await screen.findByRole('button', { name: 'Checking ticket…' })
    fireEvent.change(field, { target: { value: 'retain-manual-B' } })
    fireEvent.submit(field.closest('form'))
    expect(hashing).toHaveBeenCalledTimes(1)
    expect(field).toHaveValue('retain-manual-B')
    await act(async () => resolveHash(ticket.credential_hash))
    await screen.findByText('Checking the latest ticket list')
    await waitFor(() => expect(resolveRefresh).toBeTypeOf('function'))
    fireEvent.change(field, { target: { value: 'retain-manual-C' } })
    fireEvent.submit(field.closest('form'))
    expect(field).toHaveValue('retain-manual-C')
    expect(hashing).toHaveBeenCalledTimes(1)
    await act(async () => resolveRefresh({ data: updated }))
    await screen.findByText('Admission confirmed')
    expect(field).toHaveValue('retain-manual-C')
    expect(apiClient.get).toHaveBeenCalledTimes(1)
    expect(apiClient.post.mock.calls.filter(([url]) => url.endsWith('/sync'))).toHaveLength(1)
    expect(await queuedActions(94601, device.id)).toHaveLength(0)
  })

  it.each(['authorizationExpired', 'manifestExpired', 'refused'])('keeps actionable local policy feedback: %s', async policy => {
    const { device } = await emptyScanner(94601, [], policy === 'manifestExpired' ? { expires_at: new Date(Date.now() + 30_000).toISOString() } : {})
    const field = screen.getByLabelText('Ticket QR code')
    if (policy === 'refused') localStorage.setItem('hafapass:scanner-refusal:v1:synthetic-privacy-scanner:94601', 'refused')
    else {
      // Move only Date.now beyond the specific saved bound, without running the
      // expiry interval first; the command must diagnose its own policy check.
      const access = await loadAuthorizedScanner(94601)
      if (policy === 'authorizationExpired') {
        vi.spyOn(Date, 'now').mockReturnValue(Date.parse(device.authorization_expires_at) + 1)
      } else {
        const expires = Date.parse(access.manifest.payload.expires_at)
        vi.spyOn(Date, 'now').mockReturnValue(expires + 1)
      }
    }
    fireEvent.change(field, { target: { value: 'policy-qr' } })
    fireEvent.submit(field.closest('form'))
    await screen.findByText('Scanner access needs verification')
    const messages = { authorizationExpired: 'This scanner authorization expired. Reconnect before scanning.',
      manifestExpired: 'The saved ticket list is missing or expired. Reconnect before scanning.',
      refused: 'Reconnect and verify scanner access before scanning.' }
    expect(screen.getByText(messages[policy])).toBeInTheDocument()
    expect(apiClient.post.mock.calls.filter(([url]) => url.endsWith('/sync'))).toHaveLength(0)
  })

  async function runBackoff({ status = 503, retryAfter, cancellation, secondFailure = false } = {}) {
    const tickets = await Promise.all(['first-qr', 'second-qr'].map(async (qr, index) => ({
      ticket_id: 501 + index, state: 'valid', credential_hash: await sha256Hex(qr),
    })))
    const { device } = await emptyScanner(94601, tickets)
    const payloads = []
    apiClient.post.mockImplementation((url, payload) => {
      if (!url.endsWith('/sync')) return Promise.resolve({ data: device })
      payloads.push(structuredClone(payload))
      if (payloads.length === 1 || secondFailure) return Promise.reject(status === 'network' ? new Error('Transport failed') : { response: { status, headers: { 'retry-after': retryAfter } } })
      return Promise.resolve({ data: { device: { ...device, last_sequence: payload.actions.at(-1).sequence },
        results: payload.actions.map(action => ({ ...action, result: 'accepted' })), summary: {} } })
    })
    // Fake only the scheduler and clock. RSA/IndexedDB use real async work.
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] })
    const settle = async () => { for (let index = 0; index < 20; index++) await act(async () => { await nativeDelay(2) }) }
    const submit = async qr => {
      const field = screen.getByLabelText('Ticket QR code')
      fireEvent.change(field, { target: { value: qr } }); fireEvent.submit(field.closest('form'))
      await settle()
    }
    try {
      await submit('first-qr')
      expect(payloads).toHaveLength(1)
      await act(async () => vi.advanceTimersByTimeAsync(2000)); await settle()
      await submit('second-qr')
      expect(payloads).toHaveLength(1)
      const queued = await queuedActions(94601, device.id)
      expect(queued).toHaveLength(2)
      if (cancellation === 'unmount') cleanup()
      if (cancellation === 'offline') fireEvent(window, new Event('offline'))
      if (cancellation === 'event') fireEvent.click(screen.getByRole('button', { name: 'Switch event' }))
      if (cancellation === 'session') getApiAuthContext.mockReturnValue({ ready: true, userId: 'synthetic-privacy-scanner', sessionId: 'replacement' })
      if (cancellation === 'account') {
        localStorage.setItem('hafapass_scanner_user_id', 'another-staff')
        fireEvent(window, new StorageEvent('storage', { key: 'hafapass_scanner_user_id', newValue: 'another-staff' }))
      }
      if (cancellation === 'access') await store.purgeExpiredAdmissionAccess(94601)
      if (cancellation === 'device') await store.saveDevice(94601, { ...device, id: device.id + 1 })
      const seconds = retryAfter == null ? 15 : Number(retryAfter)
      const delay = Math.min(300_000, Math.max(5000, seconds * 1000))
      await act(async () => vi.advanceTimersByTimeAsync(delay - 2001)); await settle()
      expect(payloads).toHaveLength(1)
      await act(async () => vi.advanceTimersByTimeAsync(1)); await settle()
      expect(payloads).toHaveLength(cancellation ? 1 : 2)
      if (!cancellation) {
        expect(payloads[1].actions[0]).toEqual(payloads[0].actions[0])
        expect(payloads[1].actions.map(row => [row.action_uuid, row.sequence])).toEqual(queued.map(row => [row.action_uuid, row.sequence]))
        expect(await queuedActions(94601, device.id)).toHaveLength(secondFailure ? 2 : 0)
        if (!secondFailure) {
          expect(screen.getByText('Admission confirmed')).toBeInTheDocument()
          expect(screen.getByTestId('scanner-pending-count')).toHaveTextContent('0')
        }
      }
      // No repeated requests during an ongoing outage or after a successful ACK.
      await act(async () => vi.advanceTimersByTimeAsync(600_000)); await settle()
      expect(payloads).toHaveLength(cancellation ? 1 : 2)
    } finally { vi.useRealTimers() }
  }

  it('acknowledges both saved scans at the 503 retry deadline without another scan', async () => runBackoff())
  it('acknowledges both saved scans after a network failure without another scan', async () => runBackoff({ status: 'network' }))
  it('makes one automatic follow-up during an ongoing outage without a polling loop', async () => runBackoff({ secondFailure: true }))
  it.each(['unmount', 'offline', 'account', 'session', 'event', 'access', 'device'])('cancels automatic retry after %s withdrawal', async cancellation => runBackoff({ cancellation }))
  it.each(['-10', '60', '900000'])('honors bounded 429 Retry-After %s without request amplification', async retryAfter => runBackoff({ status: 429, retryAfter }))

})
