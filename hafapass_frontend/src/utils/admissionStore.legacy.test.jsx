import 'fake-indexeddb/auto'
import { IDBFactory } from 'fake-indexeddb'
import { openDB } from 'idb'
import { act, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import { loadAuthorizedScanner, loadPendingDeviceIdentity, pendingDeviceIdentities, queueAdmission, queuedActions, verifyLegacyJournalOwner } from './admissionStore'
import * as interchange from './admissionJournal'
import SavedJournalExports from '../components/admissions/SavedJournalExports'

const context = vi.hoisted(() => ({ auth: null }))
vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() }, getApiAuthContext: () => context.auth }))

const first = { action_uuid: 'original-v1-uuid', event_id: 98701, device_id: 881, kind: 'admit', source: 'offline',
  sequence: 7, occurred_at: '2026-10-26T00:03:00.123Z', ticket_id: 21, manifest_version: 4,
  credential_hash: 'a'.repeat(64), client_status: 'locally_accepted' }
const second = { ...first, action_uuid: 'other-account-v1-uuid', event_id: 98702, device_id: 882, ticket_id: 22 }

async function seedVersionOne() {
  const db = await openDB('hafapass-admissions', 1, { upgrade(database) {
    database.createObjectStore('devices', { keyPath: 'event_id' })
    database.createObjectStore('manifests', { keyPath: 'event_id' })
    database.createObjectStore('trusted_keys', { keyPath: 'event_id' })
    database.createObjectStore('scan_states', { keyPath: ['event_id', 'ticket_id'] })
    database.createObjectStore('queue', { keyPath: 'action_uuid' }).createIndex('event_device', ['event_id', 'device_id'])
  } })
  for (const [action, backendId] of [[first, 41], [second, 42]]) {
    await db.put('devices', { event_id: action.event_id, id: action.device_id, identifier: `original-${backendId}`,
      user: { id: backendId }, effective: true, authorization_expires_at: '2099-01-01T00:00:00Z' })
    await db.put('queue', action)
    await db.put('manifests', { event_id: action.event_id, envelope: { payload: { tickets: [{ attendee_name: 'old private attendee' }] } } })
  }
  db.close()
}

async function rawQueue() {
  const db = await openDB('hafapass-admissions', 2)
  const rows = await db.getAll('queue'); db.close(); return rows
}

describe('verified original-account export of version-one journals', () => {
  beforeEach(async () => {
    vi.resetAllMocks()
    vi.stubGlobal('indexedDB', new IDBFactory())
    localStorage.clear(); sessionStorage.clear()
    localStorage.setItem('hafapass_scanner_user_id', 'clerk-original')
    context.auth = { ready: true, userId: 'clerk-original', sessionId: 'fresh-session', generation: 1 }
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(true)
    await seedVersionOne()
    apiClient.get.mockResolvedValue({ data: { id: 41, clerk_id: 'clerk-original', workspace: { scanner: false } } })
  })
  afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); localStorage.clear(); sessionStorage.clear(); context.auth = null })

  it('exports the exact migrated journal for a verified original user with revoked scanning, preserving source data and authority', async () => {
    expect(await pendingDeviceIdentities()).toEqual([]) // Real v1 -> v2 upgrade.
    expect(await loadAuthorizedScanner(first.event_id)).toBeNull()
    const download = vi.spyOn(interchange, 'downloadJournalFile').mockImplementation(() => {})
    render(<SavedJournalExports owner="clerk-original" eventId="" pendingCount={0} />)
    await userEvent.click(await screen.findByRole('button', { name: `Export saved scans for event ${first.event_id}` }))
    expect(screen.queryByRole('button', { name: `Export saved scans for event ${second.event_id}` })).not.toBeInTheDocument()
    expect(download).toHaveBeenCalledWith(expect.objectContaining({ event_id: first.event_id, device_id: first.device_id,
      actions: [expect.objectContaining({ action_uuid: first.action_uuid, sequence: 7, occurred_at: first.occurred_at,
        manifest_version: 4, ticket_id: 21, credential_hash: first.credential_hash, source: 'offline' })] }), expect.any(String))
    expect(await rawQueue()).toEqual([first, second].sort((a, b) => a.action_uuid.localeCompare(b.action_uuid)))
    expect(await loadAuthorizedScanner(first.event_id)).toBeNull()
    await expect(queueAdmission({ eventId: first.event_id, deviceId: first.device_id, ticket: { ticket_id: 21 } })).rejects.toThrow(/not registered/)
    expect(apiClient.get).toHaveBeenCalledWith('/me', expect.objectContaining({ authContext: context.auth }))
    expect(apiClient.post).not.toHaveBeenCalled()
  })

  it('does not trust local numeric IDs and exposes only the independently authenticated second user', async () => {
    localStorage.setItem('hafapass_user', JSON.stringify({ id: 41 }))
    localStorage.setItem('hafapass_scanner_user_id', 'clerk-other')
    context.auth = { ready: true, userId: 'clerk-other', sessionId: 'other-session' }
    apiClient.get.mockResolvedValue({ data: { id: 42, clerk_id: 'clerk-other' } })
    expect(await verifyLegacyJournalOwner()).toBe(true)
    expect(await pendingDeviceIdentities()).toEqual([expect.objectContaining({ event_id: second.event_id, device_id: second.device_id })])
    expect(await queuedActions(first.event_id, first.device_id)).toEqual([])
    expect(await queuedActions(second.event_id, second.device_id)).toEqual([second])
    expect(await loadPendingDeviceIdentity(first.event_id, 41)).toBeNull()
  })

  it.each(['unresolved', 'offline', 'mismatched-clerk', 'unsigned-id', 'network'])('keeps legacy journals private without fresh matching proof: %s', async failure => {
    if (failure === 'unresolved') context.auth = { ready: false, userId: 'clerk-original' }
    if (failure === 'offline') vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false)
    if (failure === 'mismatched-clerk') apiClient.get.mockResolvedValue({ data: { id: 41, clerk_id: 'another-clerk' } })
    if (failure === 'unsigned-id') apiClient.get.mockResolvedValue({ data: { id: '41', clerk_id: 'clerk-original' } })
    if (failure === 'network') apiClient.get.mockRejectedValue(new Error('No authentication proof'))
    await act(async () => { try { await verifyLegacyJournalOwner() } catch { /* Inventory remains blocked. */ } })
    expect(await pendingDeviceIdentities()).toEqual([])
    expect(await queuedActions(first.event_id, first.device_id)).toEqual([])
    expect(await rawQueue()).toHaveLength(2)
    if (['unresolved', 'offline'].includes(failure)) expect(apiClient.get).not.toHaveBeenCalled()
  })

  it.each(['other-account', 'same-account-new-session', 'binding-withdrawal'])('ignores a stale authenticated /me response after %s', async transition => {
    let resolveMe
    apiClient.get.mockImplementation(() => new Promise(resolve => { resolveMe = resolve }))
    const pending = verifyLegacyJournalOwner()
    // Let the real upgrade and request start before replacing its context.
    while (!resolveMe) await new Promise(resolve => setTimeout(resolve, 0))
    if (transition === 'other-account') {
      localStorage.setItem('hafapass_scanner_user_id', 'clerk-other')
      context.auth = { ready: true, userId: 'clerk-other', sessionId: 'other-session' }
    } else if (transition === 'same-account-new-session') context.auth = { ...context.auth, sessionId: 'replacement-session', generation: 2 }
    else localStorage.setItem('hafapass_scanner_binding_pending', 'pending')
    resolveMe({ data: { id: 41, clerk_id: 'clerk-original' } })
    expect(await pending).toBe(false)
    expect(await pendingDeviceIdentities()).toEqual([])
    expect(await queuedActions(first.event_id, first.device_id)).toEqual([])
    expect(await rawQueue()).toHaveLength(2)
  })

  it('does not reuse a previously successful proof offline or after session replacement', async () => {
    expect(await verifyLegacyJournalOwner()).toBe(true)
    expect(await queuedActions(first.event_id, first.device_id)).toEqual([first])
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false)
    expect(await pendingDeviceIdentities()).toEqual([])
    expect(await queuedActions(first.event_id, first.device_id)).toEqual([])
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(true)
    context.auth = { ...context.auth, generation: 2 }
    expect(await pendingDeviceIdentities()).toEqual([])
    expect(await rawQueue()).toHaveLength(2)
  })
})
