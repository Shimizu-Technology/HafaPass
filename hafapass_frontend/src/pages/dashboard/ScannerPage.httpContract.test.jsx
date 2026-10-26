import 'fake-indexeddb/auto'
import { act, cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../../api/client'
import { clearAllAdmissionData, loadDevice, loadPendingDeviceIdentity, loadUsableManifest, localScanState, queuedActions } from '../../utils/admissionStore'
import ScannerPage from './ScannerPage'
import JournalRecovery from '../../components/admissions/JournalRecovery'
import { journalExport } from '../../utils/admissionJournal'

// Optional real HTTP contract lane. The local-only fixture launcher lives in
// the private admissions evidence/handoff. No mocked Axios adapter or manifest.
const endpoint = import.meta.env.VITE_ADMISSIONS_CONTRACT_URL
const contract = endpoint ? describe : describe.skip
contract('ScannerPage through actual Rails HTTP', () => {
  const defaults = { baseURL: apiClient.defaults.baseURL, adapter: apiClient.defaults.adapter }
  let releaseAuth
  beforeEach(async () => {
    localStorage.clear(); sessionStorage.clear()
    await clearAllAdmissionData()
    apiClient.defaults.baseURL = `${endpoint}/api/v1`
    apiClient.defaults.adapter = 'fetch'
  })
  afterEach(async () => {
    cleanup(); releaseAuth?.()
    await clearAllAdmissionData()
    Object.assign(apiClient.defaults, defaults)
    vi.restoreAllMocks()
    localStorage.clear(); sessionStorage.clear()
  })

  it.each(['newly-issued', 'transferred'])('confirms %s after one verified refresh and one durable admission', async scenario => {
    const fixture = await (await fetch(`${endpoint}/__admissions/new-event`, { method: 'POST' })).json()
    localStorage.setItem('hafapass_scanner_user_id', fixture.user_id)
    localStorage.setItem('hafapass_organization_id', String(fixture.org_id))
    releaseAuth = setAuthTokenGetter(async () => fixture.token, { userId: fixture.user_id, sessionId: 'synthetic-http-session', ready: true })
    render(<MemoryRouter initialEntries={[`/dashboard/scanner?event=${fixture.event_id}`]}><ScannerPage /></MemoryRouter>)
    await screen.findByText('Ticket list ready · 1 ticket', {}, { timeout: 10_000 })
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeEnabled())
    const initial = await loadUsableManifest(fixture.event_id)
    const changed = await (await fetch(`${endpoint}/__admissions/advance`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ scenario }) })).json()
    const get = vi.spyOn(apiClient, 'get')
    const post = vi.spyOn(apiClient, 'post')
    await userEvent.type(screen.getByLabelText('Ticket QR code'), changed.credential)
    await userEvent.click(screen.getByRole('button', { name: 'Check in ticket' }))
    await screen.findByText('Admission confirmed', {}, { timeout: 10_000 })
    const manifest = await loadUsableManifest(fixture.event_id)
    expect(manifest.payload.version).toBe(initial.payload.version + 1)
    const syncs = post.mock.calls.filter(([url]) => url.endsWith('/sync'))
    expect(syncs).toHaveLength(1)
    const action = syncs[0][1].actions[0]
    expect(action).toMatchObject({ ticket_id: changed.ticket_id, sequence: 1, manifest_version: manifest.payload.version })
    expect(get.mock.calls.filter(([url]) => url.endsWith('/manifest'))).toHaveLength(1)
    expect(get.mock.calls.filter(([url]) => url.endsWith('/admissions'))).toHaveLength(0)
    expect(await queuedActions(fixture.event_id, syncs[0][0].split('/').at(-2))).toHaveLength(0)
    expect(await localScanState(fixture.event_id, changed.ticket_id)).toMatchObject({ status: 'accepted', action_uuid: action.action_uuid })
    const state = await (await fetch(`${endpoint}/__admissions/state`)).json()
    expect(state.actions).toEqual([{ uuid: action.action_uuid, ticket_id: changed.ticket_id, sequence: 1, result: 'accepted' }])
    expect(state.checked_in).toEqual([changed.ticket_id])
    expect(screen.getByRole('button', { name: `Undo admission for HP-T${changed.ticket_id}` })).toBeEnabled()
    // A repeated physical scan does not create another local or server action.
    await userEvent.type(screen.getByLabelText('Ticket QR code'), changed.credential)
    await userEvent.click(screen.getByRole('button', { name: 'Check in ticket' }))
    await screen.findByText('Already scanned on this device')
    expect(post.mock.calls.filter(([url]) => url.endsWith('/sync'))).toHaveLength(1)
  })
  it('recovers the exported offline journal through the real manager endpoint while leaving the device revoked', async () => {
    const fixture = await (await fetch(`${endpoint}/__admissions/new-event`, { method: 'POST' })).json()
    localStorage.setItem('hafapass_scanner_user_id', fixture.user_id)
    localStorage.setItem('hafapass_organization_id', String(fixture.org_id))
    releaseAuth = setAuthTokenGetter(async () => fixture.token, { userId: fixture.user_id, sessionId: 'synthetic-http-session', ready: true })
    const scanner = render(<MemoryRouter initialEntries={[`/dashboard/scanner?event=${fixture.event_id}`]}><ScannerPage /></MemoryRouter>)
    await screen.findByText('Ticket list ready · 1 ticket', {}, { timeout: 10_000 })
    await act(async () => window.dispatchEvent(new Event('offline')))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' })).toBeDisabled())
    await waitFor(() => expect(screen.getByLabelText('Ticket QR code')).toBeEnabled())
    await userEvent.type(screen.getByLabelText('Ticket QR code'), fixture.credential)
    await userEvent.click(screen.getByRole('button', { name: 'Check in ticket' }))
    await screen.findByText('Admitted offline')
    const device = await loadDevice(fixture.event_id)
    const pending = await queuedActions(fixture.event_id, device.id)
    expect(pending).toHaveLength(1)
    const journal = journalExport(fixture.event_id, await loadPendingDeviceIdentity(fixture.event_id), pending)
    await apiClient.delete(`/organizer/events/${fixture.event_id}/scanner_devices/${device.id}`)
    const end = new Date().toISOString()
    scanner.unmount()
    render(<JournalRecovery eventId={String(fixture.event_id)} />)
    await userEvent.click(screen.getByText('Manager: recover an offline journal'))
    const file = new File([JSON.stringify(journal)], 'retained-journal.json', { type: 'application/json' })
    file.text = async () => JSON.stringify(journal)
    await userEvent.upload(screen.getByLabelText('Saved journal file'), file)
    await userEvent.type(screen.getByLabelText('Reviewed start (ISO 8601 with timezone)'), new Date(Date.parse(pending[0].occurred_at) - 1000).toISOString())
    await userEvent.type(screen.getByLabelText('Reviewed end, exclusive (ISO 8601 with timezone)'), end)
    await userEvent.type(screen.getByLabelText('Gate evidence and reason'), 'Synthetic paper gate record independently reviewed by event manager')
    await userEvent.click(screen.getByRole('checkbox'))
    await userEvent.click(screen.getByRole('button', { name: 'Recover reviewed admissions' }))
    await screen.findByText(/Review recorded: 1 accepted, 0 conflicts, 0 rejected/, {}, { timeout: 10_000 })
    expect(await queuedActions(fixture.event_id, device.id)).toEqual(pending)
    const state = await (await fetch(`${endpoint}/__admissions/state`)).json()
    expect(state.checked_in).toEqual([fixture.ticket_id])
    expect(state.actions).toHaveLength(1)
    const devices = (await apiClient.get(`/organizer/events/${fixture.event_id}/scanner_devices`)).data
    expect(devices.find(item => item.id === device.id)).toMatchObject({ status: 'revoked', effective: false, last_sequence: 1 })
    await expect(apiClient.post(`/organizer/events/${fixture.event_id}/scanner_devices/${device.id}/sync`, { actions: pending })).rejects.toMatchObject({ response: { status: 422 } })
  })

})
