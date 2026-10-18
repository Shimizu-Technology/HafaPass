import 'fake-indexeddb/auto'
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import { act, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, Link, useNavigate } from 'react-router-dom'
import apiClient from '../../api/client'
import * as admissionStore from '../../utils/admissionStore'
import { clearAllAdmissionData, clearEventAdmissionData, loadAuthorizedScanner, queueAdmission, queuedActions, saveDevice, saveVerifiedManifest } from '../../utils/admissionStore'
import { signedManifest } from '../../test/manifestFixture'
import DashboardPage from './DashboardPage'
import ScannerPage from './ScannerPage'
import RefundsPage from './RefundsPage'

vi.mock('../../api/client', async original => ({ ...(await original()), default: { get: vi.fn(), post: vi.fn() } }))
const meta = (page, count = 21) => ({ current_page: page, total_pages: Math.ceil(count / 20), total_count: count })
const event = id => ({ id, organization_id: 1, title: `Discovery event ${id}`, status: 'published', timezone: 'Pacific/Guam', permissions: { scan: true, edit_event_content: true, refund: true, view_finance: true } })
const order = id => ({ id, reference: `HP-OLDER-${id}`, buyer_name: `Buyer ${id}`, buyer_email: `buyer${id}@example.invalid`, ticket_count: 1, total_cents: 1000, refundable_cents: 1000, created_at: '2026-01-01T00:00:00Z' })
const organization = { id: 1, name: 'Discovery org', permissions: { manage_organization: true, manage_events: true } }
const deferred = () => {
  let resolve, reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}
// Hold renewal separately so these tests keep the grant unchanged. A real
// peer renewal is allowed to supersede a refusal of an older grant.
async function concurrentScannerReads() {
  const manifest = await signedManifest(1, [])
  const direct = deferred(), dashboard = deferred(), renewal = deferred()
  let holding = false, directConfig, dashboardConfig, initialSummaryReturned = false, startupSyncStarted = false
  const startupSync = deferred()
  const capture = admissionStore.captureAdmissionAccessContext
  vi.spyOn(admissionStore, 'captureAdmissionAccessContext').mockImplementation(async (...args) => {
    const context = await capture(...args)
    if (initialSummaryReturned && !startupSyncStarted) {
      startupSyncStarted = true
      await startupSync.promise
    }
    return context
  })
  apiClient.get.mockImplementation((url, config) => {
    if (url === '/organizer/events') return Promise.resolve({ data: { events: [event(config.params.page === 2 ? 21 : 1)], meta: meta(config.params.page) } })
    if (url === '/organizer/events/1') { directConfig = config; return direct.promise }
    if (holding && url.endsWith('/admissions')) { dashboardConfig = config; return dashboard.promise }
    if (holding && url.endsWith('/manifest')) return renewal.promise
    if (url.endsWith('/admissions')) initialSummaryReturned = true
    return Promise.resolve({ data: url.endsWith('/manifest') ? manifest : { counts: {}, permissions: {}, recent_actions: [] } })
  })
  apiClient.post.mockResolvedValue({ data: { id: 91, identifier: 'concurrent-scanner', effective: true, authorization_expires_at: new Date(Date.now() + 600000).toISOString() } })
  const mounted = view(ScannerPage, '/dashboard/scanner?event=1')
  // Observe and release the automatic startup sync before clicking the manual
  // control. Waiting for its initial enabled render can race this effect.
  await waitFor(() => expect(startupSyncStarted).toBe(true))
  expect(screen.getByRole('button', { name: 'Sync now' })).toBeDisabled()
  await act(async () => startupSync.resolve())
  await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
  holding = true
  return { direct, dashboard, renewal, mounted, manifest,
    directConfig: () => directConfig, dashboardConfig: () => dashboardConfig,
    startDirect: async () => {
      await userEvent.click(screen.getByRole('button', { name: 'Next', exact: true }))
      await waitFor(() => expect(directConfig).toBeDefined())
    },
    startDashboard: async () => {
      await userEvent.click(screen.getByRole('button', { name: 'Sync now' }))
      await waitFor(() => expect(dashboardConfig).toBeDefined())
    },
  }
}
function ScannerNavigation() { const navigate = useNavigate(); return <button onClick={() => navigate('/dashboard/scanner?event=21')}>Open other scanner</button> }
function view(Page, path = '/dashboard', extra = null) {
  return render(<MemoryRouter initialEntries={[path]}>{extra}<Routes>
    <Route path="/dashboard" element={<DashboardPage />} />
    <Route path="/dashboard/scanner" element={<ScannerPage />} />
    <Route path="/dashboard/events/:id/refunds" element={<RefundsPage />} />
    <Route path="/dashboard/events/:id/edit" element={<Link to="/dashboard">Return to events</Link>} />
  </Routes></MemoryRouter>)
}
beforeEach(async () => {
  vi.clearAllMocks(); window.localStorage.clear(); window.sessionStorage.clear()
  await clearAllAdmissionData()
  for (const id of [1, 2, 3, 4, 21]) await clearEventAdmissionData(id)
})
afterEach(() => vi.restoreAllMocks())

describe('complete operational discovery', () => {
  it('pages to an older dashboard event and restores the list after returning from its workspace', async () => {
    apiClient.get.mockImplementation((url, config) => Promise.resolve({ data: url === '/organizer/organizations' ? [organization]
      : url === '/organizer_profile' ? { business_name: 'Discovery org', readiness: {} }
        : { events: [event(config?.params?.page === 2 ? 1 : 21)], meta: meta(config?.params?.page || 1) } }))
    view(DashboardPage)
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Next', exact: true }))
    await user.click(await screen.findByRole('link', { name: /Discovery event 1 / }))
    await user.click(screen.getByRole('link', { name: 'Return to events' }))
    expect(await screen.findByText('Page 2 of 2 · 21 results')).toBeInTheDocument()
    await user.type(screen.getByLabelText('Find an event'), 'unique venue')
    await user.click(within(screen.getByRole('search')).getByRole('button', { name: 'Search events' }))
    await waitFor(() => expect(apiClient.get).toHaveBeenCalledWith('/organizer/events', expect.objectContaining({ params: { q: 'unique venue', page: 1 } })))
  })

  it('resolves a direct authorized scanner event outside page one and retains selection across page/search changes', async () => {
    const manifest = await signedManifest(1, [])
    apiClient.get.mockImplementation((url, config) => Promise.resolve({ data: url === '/organizer/events'
      ? { events: config?.params?.q ? [] : [event(config?.params?.page === 2 ? 2 : 21)], meta: meta(config?.params?.page || 1) }
      : url === '/organizer/events/1' ? event(1) : url.endsWith('/manifest') ? manifest : { counts: {}, permissions: {}, recent_actions: [] } }))
    apiClient.post.mockResolvedValue({ data: { id: 91, effective: true, authorization_expires_at: new Date(Date.now() + 600000).toISOString() } })
    view(ScannerPage, '/dashboard/scanner?event=1')
    const user = userEvent.setup()
    await screen.findByText('Ticket list ready · 0 tickets')
    expect(screen.getByLabelText('Event to scan')).toHaveValue('1')
    await user.click(screen.getByRole('button', { name: 'Next', exact: true }))
    await screen.findByText('Page 2 of 2 · 21 results')
    expect(screen.getByLabelText('Event to scan')).toHaveValue('1')
    await user.type(screen.getByLabelText('Find an event'), 'missing')
    await user.click(screen.getByRole('button', { name: 'Search events', exact: true }))
    await screen.findByText(/No matching events/)
    expect(screen.getByLabelText('Event to scan')).toHaveValue('1')
    expect(screen.getByLabelText('Ticket QR code')).toBeEnabled()
    expect(apiClient.post.mock.calls.filter(([url]) => url.endsWith('/scanner_devices'))).toHaveLength(1)
  })

  it.each([[401, 'query'], [403, 'query'], [401, 'saved'], [403, 'saved']])('quarantines initial cached organization grants on %s (%s) and blocks offline remount', async (status, source) => {
    window.localStorage.setItem('hafapass_organization_id', '1')
    const expiry = new Date(Date.now() + 600000).toISOString()
    for (const [id, organization_id] of [[1, '1'], [2, '1'], [3, '2'], [4, null]]) {
      await saveDevice(id, { id: 90 + id, organization_id, effective: true, authorization_expires_at: expiry })
      await saveVerifiedManifest(await signedManifest(id, []))
    }
    const pending = await queueAdmission({ eventId: 1, deviceId: 91, manifestVersion: 1, ticket: { ticket_id: 501 }, credentialHash: 'initial-unknown', source: 'offline' })
    window.localStorage.setItem('hafapass_scanner_event_id', '1')
    apiClient.get.mockRejectedValue({ response: { status, data: { error: 'Initial organization refusal' } } })
    const mounted = view(ScannerPage, source === 'query' ? '/dashboard/scanner?event=1' : '/dashboard/scanner')
    await screen.findByText('Initial organization refusal')
    await waitFor(async () => expect(await loadAuthorizedScanner(2)).toBeNull())
    expect(await loadAuthorizedScanner(1)).toBeNull()
    expect(await loadAuthorizedScanner(4)).toBeNull()
    expect(await loadAuthorizedScanner(3)).not.toBeNull()
    expect((await queuedActions(1, 91)).map(action => action.action_uuid)).toEqual([pending.action_uuid])
    expect(apiClient.post).not.toHaveBeenCalled()
    mounted.unmount()
    render(<MemoryRouter initialEntries={['/dashboard/scanner?event=1']}><ScannerPage offlineOnly /></MemoryRouter>)
    await screen.findByText(/This event is not saved on this device/)
    expect(screen.getByLabelText('Ticket QR code')).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Start camera' })).toBeDisabled()
    expect((await queuedActions(1, 91)).map(action => action.action_uuid)).toEqual([pending.action_uuid])
  })

  it.each([401, 403])('handles initial %s without cached grants without registering or restoring another event', async status => {
    apiClient.get.mockRejectedValue({ response: { status } })
    view(ScannerPage, '/dashboard/scanner?event=1')
    await screen.findByText(/Scanner access was refused. Sign in and verify/)
    expect(screen.getByLabelText('Ticket QR code')).toBeDisabled()
    expect(apiClient.post).not.toHaveBeenCalled()
  })

  it('ignores an initial list refusal after a new route has renewed cached authority', async () => {
    window.localStorage.setItem('hafapass_organization_id', '1')
    const expiry = new Date(Date.now() + 600000).toISOString()
    await saveDevice(1, { id: 91, organization_id: '1', effective: true, authorization_expires_at: expiry })
    await saveVerifiedManifest(await signedManifest(1, []))
    let rejectOld, calls = 0
    const manifest = await signedManifest(21, [])
    apiClient.get.mockImplementation(url => {
      if (url === '/organizer/events') return ++calls === 1 ? new Promise((_resolve, reject) => { rejectOld = reject }) : Promise.resolve({ data: { events: [event(21)] } })
      return Promise.resolve({ data: url.endsWith('/manifest') ? manifest : { counts: {}, permissions: {}, recent_actions: [] } })
    })
    apiClient.post.mockResolvedValue({ data: { id: 92, effective: true, authorization_expires_at: expiry } })
    view(ScannerPage, '/dashboard/scanner?event=1', <ScannerNavigation />)
    await waitFor(() => expect(rejectOld).toBeDefined())
    await userEvent.click(screen.getByRole('button', { name: 'Open other scanner' }))
    await screen.findByText('Ticket list ready · 0 tickets')
    await act(async () => rejectOld({ response: { status: 403, data: { error: 'Obsolete initial refusal' } } }))
    expect(screen.getByLabelText('Ticket QR code')).toBeEnabled()
    expect(await loadAuthorizedScanner(1)).not.toBeNull()
    expect(await loadAuthorizedScanner(21)).not.toBeNull()
    expect(screen.queryByText('Obsolete initial refusal')).not.toBeInTheDocument()
  })

  it('preserves a grant renewed by a peer after initial discovery began', async () => {
    window.localStorage.setItem('hafapass_organization_id', '1')
    const device = { id: 91, organization_id: '1', effective: true, authorization_expires_at: new Date(Date.now() + 600000).toISOString() }
    await saveDevice(1, device)
    await saveVerifiedManifest(await signedManifest(1, []))
    const purge = admissionStore.purgeExpiredAdmissionAccess
    let finishRefusal
    vi.spyOn(admissionStore, 'purgeExpiredAdmissionAccess').mockImplementation(async (...args) => {
      await new Promise(resolve => { finishRefusal = resolve })
      return purge(...args)
    })
    let rejectOld
    apiClient.get.mockImplementation(() => new Promise((_resolve, reject) => { rejectOld = reject }))
    const mounted = view(ScannerPage, '/dashboard/scanner?event=1')
    await waitFor(() => expect(rejectOld).toBeDefined())
    await saveDevice(1, { ...device, authorization_expires_at: new Date(Date.now() + 900000).toISOString() })
    await saveVerifiedManifest(await signedManifest(1, [], { version: 2 }))
    await act(async () => rejectOld({ response: { status: 403 } }))
    await screen.findByText(/Scanner access was refused. Sign in and verify/)
    await waitFor(() => expect(finishRefusal).toBeDefined())
    // The peer cache already exists while the refusal still has persistent
    // safety locks. Its presence alone does not mean refusal handling finished.
    expect((await loadAuthorizedScanner(1)).manifest.payload.version).toBe(2)
    const refusalKey = `hafapass:scanner-refusal:v1:${encodeURIComponent(admissionStore.currentScannerOwner())}:1`
    for (const storage of [window.localStorage, window.sessionStorage]) expect(storage.getItem(refusalKey)).not.toBeNull()
    expect(screen.getByLabelText('Ticket QR code')).toBeDisabled()
    await act(async () => finishRefusal())
    // Remount only after the handler recognizes the newer grant and clears
    // its own locks. Unmounting earlier must leave entry safely paused.
    await waitFor(() => {
      for (const storage of [window.localStorage, window.sessionStorage]) expect(storage.getItem(refusalKey)).toBeNull()
    })
    expect((await loadAuthorizedScanner(1)).manifest.payload.version).toBe(2)
    mounted.unmount()
    render(<MemoryRouter initialEntries={['/dashboard/scanner?event=1']}><ScannerPage offlineOnly /></MemoryRouter>)
    await screen.findByText('Ticket list ready · 0 tickets')
    expect(screen.getByLabelText('Ticket QR code')).toBeEnabled()
  })

  it.each([401, 403, 'network'])('handles a prepared scanner event-list %s without discarding pending admissions', async failure => {
    let failed = false
    const manifest = await signedManifest(1, [])
    apiClient.get.mockImplementation(url => {
      if (url === '/organizer/events') return failed ? Promise.reject(failure === 'network' ? new Error('Offline') : { response: { status: failure, data: { error: 'Organization membership required' } } }) : Promise.resolve({ data: { events: [event(1)] } })
      return Promise.resolve({ data: url.endsWith('/manifest') ? manifest : { counts: {}, permissions: {}, recent_actions: [] } })
    })
    apiClient.post.mockResolvedValue({ data: { id: 91, effective: true, authorization_expires_at: new Date(Date.now() + 600000).toISOString() } })
    view(ScannerPage, '/dashboard/scanner?event=1')
    await screen.findByText('Ticket list ready · 0 tickets')
    await queueAdmission({ eventId: 1, deviceId: 91, manifestVersion: 1, ticket: { ticket_id: 501 }, credentialHash: 'unknown-admission', source: 'offline' })
    failed = true
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Find an event'), 'another event')
    await user.click(screen.getByRole('button', { name: 'Search events', exact: true }))
    if (failure === 'network') {
      await screen.findByText(/Events could not be loaded/)
      expect(screen.getByLabelText('Ticket QR code')).toBeEnabled()
      expect(await loadAuthorizedScanner(1)).not.toBeNull()
    } else {
      await screen.findByText('Organization membership required')
      expect(screen.getByLabelText('Ticket QR code')).toBeDisabled()
      expect(screen.getByRole('button', { name: 'Start camera' })).toBeDisabled()
      expect(await loadAuthorizedScanner(1)).toBeNull()
    }
    expect(await queuedActions(1, 91)).toHaveLength(1)
  })

  it('ignores an obsolete list refusal after selecting another authorized scanner event', async () => {
    const manifests = { 1: await signedManifest(1, []), 21: await signedManifest(21, []) }
    let rejectOld
    apiClient.get.mockImplementation((url, config) => {
      if (url === '/organizer/events') return config?.params?.q === 'held list' && !rejectOld ? new Promise((_resolve, reject) => { rejectOld = reject }) : Promise.resolve({ data: { events: [event(1), event(21)] } })
      const id = url.includes('/events/21/') ? 21 : 1
      return Promise.resolve({ data: url.endsWith('/manifest') ? manifests[id] : { counts: {}, permissions: {}, recent_actions: [] } })
    })
    apiClient.post.mockImplementation(url => Promise.resolve({ data: { id: url.includes('/events/21/') ? 92 : 91, effective: true, authorization_expires_at: new Date(Date.now() + 600000).toISOString() } }))
    view(ScannerPage, '/dashboard/scanner?event=1', <ScannerNavigation />)
    await screen.findByText('Ticket list ready · 0 tickets')
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Find an event'), 'held list')
    await user.click(screen.getByRole('button', { name: 'Search events', exact: true }))
    await waitFor(() => expect(rejectOld).toBeDefined())
    await user.click(screen.getByRole('button', { name: 'Open other scanner' }))
    await waitFor(() => expect(screen.getByLabelText('Event to scan')).toHaveValue('21'))
    await waitFor(() => expect(screen.getByLabelText('Ticket QR code')).toBeEnabled())
    await act(async () => rejectOld({ response: { status: 403, data: { error: 'Obsolete membership refusal' } } }))
    expect(screen.getByLabelText('Event to scan')).toHaveValue('21')
    await waitFor(() => expect(screen.getByLabelText('Ticket QR code')).toBeEnabled())
    expect(screen.queryByText('Obsolete membership refusal')).not.toBeInTheDocument()
    expect(await loadAuthorizedScanner(21)).not.toBeNull()
  })

  it('preserves a peer-renewed grant when an earlier current-event list is refused', async () => {
    let rejectOld
    const manifest = await signedManifest(1, [])
    apiClient.get.mockImplementation((url, config) => {
      if (url === '/organizer/events') return config?.params?.q ? new Promise((_resolve, reject) => { rejectOld = reject }) : Promise.resolve({ data: { events: [event(1)] } })
      return Promise.resolve({ data: url.endsWith('/manifest') ? manifest : { counts: {}, permissions: {}, recent_actions: [] } })
    })
    const device = { id: 91, effective: true, authorization_expires_at: new Date(Date.now() + 600000).toISOString() }
    apiClient.post.mockResolvedValue({ data: device })
    view(ScannerPage, '/dashboard/scanner?event=1')
    await screen.findByText('Ticket list ready · 0 tickets')
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Find an event'), 'held renewal')
    await user.click(screen.getByRole('button', { name: 'Search events', exact: true }))
    await waitFor(() => expect(rejectOld).toBeDefined())
    await saveDevice(1, { ...device, authorization_expires_at: new Date(Date.now() + 900000).toISOString() })
    await saveVerifiedManifest(await signedManifest(1, [], { version: 2 }))
    await act(async () => rejectOld({ response: { status: 403 } }))
    await waitFor(() => expect(screen.getByLabelText('Ticket QR code')).toBeEnabled())
    expect((await loadAuthorizedScanner(1)).manifest.payload.version).toBe(2)
  })

  it.each(['dashboard-first', 'direct-first'])('completes independent scanner summary and direct reads (%s)', async order => {
    const reads = await concurrentScannerReads()
    if (order === 'dashboard-first') { await reads.startDashboard(); await reads.startDirect() }
    else { await reads.startDirect(); await reads.startDashboard() }
    expect(reads.directConfig().signal).not.toBe(reads.dashboardConfig().signal)
    expect(reads.directConfig().signal.aborted).toBe(false)
    expect(reads.dashboardConfig().signal.aborted).toBe(false)
    await act(async () => {
      reads.direct.resolve({ data: event(1) })
      reads.dashboard.resolve({ data: { counts: { admitted: 7 }, permissions: {}, recent_actions: [] } })
      reads.renewal.resolve({ data: reads.manifest })
    })
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
    expect(screen.getByRole('heading', { name: 'Door totals' }).parentElement.parentElement).toHaveTextContent('7')
    expect(screen.getByLabelText('Ticket QR code')).toBeEnabled()
    expect(screen.getByLabelText('Event to scan')).toHaveValue('1')
    expect(screen.queryByText(/canceled|could not be loaded|could not be synchronized/i)).not.toBeInTheDocument()
    expect(await loadAuthorizedScanner(1)).not.toBeNull()
    expect(apiClient.post.mock.calls.filter(([url]) => url.endsWith('/scanner_devices'))).toHaveLength(1)
  })

  it.each([401, 403, 404, 'permissions'])('honors a direct-event %s after an independent summary starts, preserving the journal', async refusal => {
    const reads = await concurrentScannerReads()
    await reads.startDirect()
    await reads.startDashboard()
    const pending = await queueAdmission({ eventId: 1, deviceId: 91, manifestVersion: 1,
      ticket: { ticket_id: 501 }, credentialHash: 'concurrent-pending', source: 'offline' })
    await act(async () => refusal === 'permissions'
      ? reads.direct.resolve({ data: { ...event(1), permissions: { scan: false } } })
      : reads.direct.reject({ response: { status: refusal } }))
    await screen.findByText('This event is no longer available for scanning. Saved scans remain on this device.')
    expect(screen.getByLabelText('Ticket QR code')).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Start camera' })).toBeDisabled()
    expect(reads.dashboardConfig().signal.aborted).toBe(true)
    expect(await loadAuthorizedScanner(1)).toBeNull()
    expect((await queuedActions(1, 91)).map(action => action.action_uuid)).toEqual([pending.action_uuid])
    await act(async () => {
      reads.dashboard.resolve({ data: { counts: { admitted: 99 }, permissions: {}, recent_actions: [] } })
      reads.renewal.resolve({ data: reads.manifest })
    })
    expect(screen.queryByRole('heading', { name: 'Door totals' })).not.toBeInTheDocument()
    expect(screen.getByLabelText('Ticket QR code')).toBeDisabled()
    expect(await loadAuthorizedScanner(1)).toBeNull()
    reads.mounted.unmount()
    render(<MemoryRouter initialEntries={['/dashboard/scanner?event=1']}><ScannerPage offlineOnly /></MemoryRouter>)
    await screen.findByText(/This event is not saved on this device/)
    expect(screen.getByLabelText('Ticket QR code')).toBeDisabled()
    expect((await queuedActions(1, 91)).map(action => action.action_uuid)).toEqual([pending.action_uuid])
  })

  it.each([403, 503])('handles concurrent summary %s without allowing a late direct success to restore refused access', async status => {
    const reads = await concurrentScannerReads()
    await reads.startDashboard()
    await reads.startDirect()
    await act(async () => reads.dashboard.reject({ response: { status, data: { error: 'Summary request failed' } } }))
    await screen.findByText('Summary request failed')
    expect(reads.directConfig().signal.aborted).toBe(status === 403)
    await act(async () => {
      reads.direct.resolve({ data: event(1) })
      reads.renewal.resolve({ data: reads.manifest })
    })
    if (status === 403) {
      expect(screen.getByLabelText('Ticket QR code')).toBeDisabled()
      expect(await loadAuthorizedScanner(1)).toBeNull()
    } else {
      expect(screen.getByLabelText('Ticket QR code')).toBeEnabled()
      expect(await loadAuthorizedScanner(1)).not.toBeNull()
    }
  })

  it.each([403, 404, 'permissions'])('withdraws prepared event access when direct revalidation refuses it (%s)', async refusal => {
    let refused = false
    const manifest = await signedManifest(1, [])
    apiClient.get.mockImplementation((url) => {
      if (url === '/organizer/events') return Promise.resolve({ data: { events: [event(21)], meta: meta(1) } })
      if (url === '/organizer/events/1') {
        if (refused && refusal !== 'permissions') return Promise.reject({ response: { status: refusal } })
        return Promise.resolve({ data: { ...event(1), permissions: { scan: !refused } } })
      }
      return Promise.resolve({ data: url.endsWith('/manifest') ? manifest : { counts: {}, permissions: {}, recent_actions: [] } })
    })
    apiClient.post.mockResolvedValue({ data: { id: 91, effective: true, authorization_expires_at: new Date(Date.now() + 600000).toISOString() } })
    view(ScannerPage, '/dashboard/scanner?event=1')
    await screen.findByText('Ticket list ready · 0 tickets')
    refused = true
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Find an event'), 'another event')
    await user.click(screen.getByRole('button', { name: 'Search events', exact: true }))
    await screen.findByText('This event is no longer available for scanning. Saved scans remain on this device.')
    expect(screen.getByLabelText('Ticket QR code')).toBeDisabled()
    expect(await loadAuthorizedScanner(1)).toBeNull()
  })

  it('refuses a direct scanner event whose detail endpoint does not grant scan permission', async () => {
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/organizer/events' ? { events: [event(21)] } : { ...event(1), permissions: { scan: false } } }))
    view(ScannerPage, '/dashboard/scanner?event=1')
    await screen.findByText(/This event is not assigned to your account/)
    expect(apiClient.post).not.toHaveBeenCalled()
    expect(screen.getByLabelText('Ticket QR code')).toBeDisabled()
  })

  it('finds older refund orders, preserves search across reload, and retries a pending operation after it leaves the result page', async () => {
    apiClient.get.mockImplementation((url, config) => Promise.resolve({ data: url.endsWith('/orders')
      ? { orders: config?.params?.q ? [] : [order(config?.params?.page === 2 ? 1 : 21)], meta: meta(config?.params?.page || 1) }
      : url === '/organizer/organizations' ? [organization] : event(1) }))
    apiClient.post.mockResolvedValue({ data: { status: 'pending' } })
    const mounted = view(RefundsPage, '/dashboard/events/1/refunds')
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Next', exact: true }))
    await screen.findByText(/HP-OLDER-1 /)
    await user.click(screen.getByRole('button', { name: 'Refund', exact: true }))
    await user.click(screen.getByRole('button', { name: 'Process Refund' }))
    await screen.findByText(/Refund pending/)
    const original = apiClient.post.mock.calls[0]
    await user.type(screen.getByLabelText('Find an order'), 'other buyer')
    await user.click(screen.getByRole('button', { name: 'Search orders' }))
    await user.click(await screen.findByRole('button', { name: 'Retry saved refund' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledTimes(2))
    const retry = apiClient.post.mock.calls[1]
    expect(retry.slice(0, 2)).toEqual(original.slice(0, 2))
    expect(retry[2].headers).toEqual(original[2].headers)
    mounted.unmount()
    view(RefundsPage, '/dashboard/events/1/refunds')
    expect(await screen.findByLabelText('Find an order')).toHaveValue('other buyer')
    expect(await screen.findByRole('button', { name: 'Retry saved refund' })).toBeEnabled()
  })
})
