import 'fake-indexeddb/auto'
import { act, cleanup, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import { clearAllAdmissionData, clearEventAdmissionData, localScanState, queuedActions, sha256Hex } from '../../utils/admissionStore'
import { signedManifest } from '../../test/manifestFixture'
import ScannerPage from './ScannerPage'

vi.mock('../../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() }, getApiAuthContext: () => null, subscribeApiAuthContext: () => () => {} }))

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
  async function emptyScanner(eventId = 94601, tickets = []) {
    const device = { id: eventId + 100, identifier: 'freshness-door', effective: true, last_sequence: 0,
      authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const envelope = await signedManifest(eventId, tickets)
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/me' ? { id: 'synthetic-privacy-scanner' }
      : url === '/organizer/events' ? { events: [{ id: eventId, title: 'Freshness test', status: 'published' }] }
        : url.endsWith('/manifest') ? envelope : { counts: {}, permissions: {}, recent_actions: [] } }))
    apiClient.post.mockResolvedValue({ data: device })
    render(<MemoryRouter initialEntries={[`/dashboard/scanner?event=${eventId}`]}><ScannerPage /></MemoryRouter>)
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
  })

})
