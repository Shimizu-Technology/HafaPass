import 'fake-indexeddb/auto'
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest'
import { signedManifest } from '../test/manifestFixture'
import {
  applySyncResults, canonicalJson, clearEventAdmissionData, clearAllAdmissionData, loadAuthorizedScanner, loadDevice, loadPendingDeviceIdentity, loadUsableManifest, localScanState, queueAdmission, queueReversal,
  queuedActions, purgeExpiredAdmissionAccess, invalidateManifestAccess, saveDevice, saveVerifiedManifest, sha256Hex,
} from './admissionStore'

const toBase64 = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes)))
const toBase64Url = bytes => toBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')

describe('admissionStore', () => {
  afterEach(() => { vi.restoreAllMocks(); window.localStorage.clear() })
  let signingKeys

  beforeAll(async () => {
    signingKeys = await crypto.subtle.generateKey(
      { name: 'RSA-PSS', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
      true,
      ['sign', 'verify'],
    )
  })

  it('uses the same stable canonical representation regardless of key order', () => {
    expect(canonicalJson({ z: 2, a: { d: 4, b: 3 } })).toBe('{"a":{"b":3,"d":4},"z":2}')
  })

  it('verifies and persists a signed, unexpired manifest', async () => {
    const eventId = 91001
    await clearEventAdmissionData(eventId)
    const payload = {
      schema_version: 1,
      event: { id: eventId, title: 'Guam Night Market' },
      version: 1,
      generated_at: new Date().toISOString(),
      expires_at: new Date(Date.now() + 60_000).toISOString(),
      tickets: [],
    }
    const digest = await sha256Hex(canonicalJson(payload))
    const signature = await crypto.subtle.sign(
      { name: 'RSA-PSS', saltLength: 32 },
      signingKeys.privateKey,
      new TextEncoder().encode(digest),
    )
    const publicKey = await crypto.subtle.exportKey('spki', signingKeys.publicKey)
    const envelope = {
      payload,
      digest,
      signature: toBase64Url(signature),
      algorithm: 'PS256',
      key_id: await sha256Hex(publicKey),
      public_key_spki: toBase64(publicKey),
    }

    await saveVerifiedManifest(envelope)

    expect(await loadUsableManifest(eventId)).toEqual(envelope)
  })

  it('allocates durable device sequences and removes only server-acknowledged actions', async () => {
    const eventId = 91002
    const device = { id: 42, event_id: eventId, last_sequence: 7, effective: true, authorization_expires_at: new Date(Date.now() + 60_000).toISOString() }
    const ticket = { ticket_id: 12, attendee_name: 'Mina', ticket_type: 'General' }
    await clearEventAdmissionData(eventId)
    await saveDevice(eventId, device)

    const first = await queueAdmission({ eventId, deviceId: device.id, manifestVersion: 3, ticket,
      credentialHash: 'a'.repeat(64), source: 'offline' })
    const second = await queueAdmission({ eventId, deviceId: device.id, manifestVersion: 3,
      ticket: { ...ticket, ticket_id: 13 }, credentialHash: 'b'.repeat(64), source: 'offline' })

    expect([first.sequence, second.sequence]).toEqual([8, 9])
    await applySyncResults(eventId, { ...device, last_sequence: 8 }, [{
      action_uuid: first.action_uuid,
      ticket_id: 12,
      kind: 'admit',
      result: 'accepted',
      reason_code: 'admitted',
      occurred_at: first.occurred_at,
    }])
    expect((await queuedActions(eventId, device.id)).map(action => action.action_uuid)).toEqual([second.action_uuid])
  })

  it.each([
    ['conflict', 'already_reversed', true],
    ['rejected', 'reversal_not_authorized', false],
  ])('acknowledges %s Undo without losing the correct original admission state', async (result, reason_code, canReadmit) => {
    const eventId = result === 'conflict' ? 91011 : 91012
    const device = { id: 43, effective: true, last_sequence: 0, authorization_expires_at: new Date(Date.now() + 60_000).toISOString() }
    await saveDevice(eventId, device)
    const input = { eventId, deviceId: device.id, manifestVersion: 1, ticket: { ticket_id: 14 }, credentialHash: 'c'.repeat(64), source: 'online' }
    const admitted = await queueAdmission(input)
    await applySyncResults(eventId, device, [{ action_uuid: admitted.action_uuid, ticket_id: 14, kind: 'admit', result: 'accepted' }])
    const reversal = await queueReversal({ eventId, deviceId: device.id, manifestVersion: 1, ticketId: 14, reversesActionUuid: admitted.action_uuid })
    await applySyncResults(eventId, device, [{ action_uuid: reversal.action_uuid, ticket_id: 14, kind: 'reverse', result, reason_code }])
    expect(await queuedActions(eventId, device.id)).toHaveLength(0)
    expect(Boolean(await queueAdmission(input))).toBe(canReadmit)
    if (!canReadmit) expect((await localScanState(eventId, 14)).status).toBe('accepted')
  })

  it('retains the newer Undo state when an older Undo acknowledgement arrives', async () => {
    const eventId = 91013
    const device = { id: 43, effective: true, last_sequence: 0, authorization_expires_at: new Date(Date.now() + 60_000).toISOString() }
    await saveDevice(eventId, device)
    const first = await queueReversal({ eventId, deviceId: device.id, manifestVersion: 1, ticketId: 14, reversesActionUuid: 'original' })
    const second = await queueReversal({ eventId, deviceId: device.id, manifestVersion: 1, ticketId: 14, reversesActionUuid: 'original' })
    await applySyncResults(eventId, device, [{ action_uuid: first.action_uuid, ticket_id: 14, kind: 'reverse', result: 'accepted' }])
    expect((await localScanState(eventId, 14)).reversal_action_uuid).toBe(second.action_uuid)
    expect((await queuedActions(eventId, device.id)).map(action => action.action_uuid)).toEqual([second.action_uuid])
    await applySyncResults(eventId, device, [{ action_uuid: second.action_uuid, ticket_id: 14, kind: 'reverse', result: 'conflict', reason_code: 'already_reversed' }])
    expect(await localScanState(eventId, 14)).toBeUndefined()
    expect(await queuedActions(eventId, device.id)).toHaveLength(0)
  })

  it('atomically admits one ticket when camera and manual entry overlap', async () => {
    const eventId = 91003
    const device = { id: 43, effective: true, last_sequence: 0, authorization_expires_at: new Date(Date.now() + 60_000).toISOString() }
    await saveDevice(eventId, device)
    const payload = { eventId, deviceId: device.id, manifestVersion: 1, ticket: { ticket_id: 14 }, credentialHash: 'c'.repeat(64), source: 'offline' }
    const results = await Promise.all([queueAdmission(payload), queueAdmission(payload)])
    expect(results.filter(Boolean)).toHaveLength(1)
    expect(await queuedActions(eventId, device.id)).toHaveLength(1)
    expect((await loadDevice(eventId)).next_sequence).toBe(1)
  })

  it('purges signed-out access and attendee details while retaining a journal only the original account can recover', async () => {
    const eventId = 91004
    window.localStorage.setItem('hafapass_scanner_user_id', 'staff-a')
    const device = { id: 44, identifier: 'device-owned-by-a', effective: true, last_sequence: 0, authorization_expires_at: new Date(Date.now() + 60_000).toISOString() }
    await saveDevice(eventId, device)
    await saveVerifiedManifest(await signedManifest(eventId))
    await queueAdmission({ eventId, deviceId: 44, manifestVersion: 1, ticket: { ticket_id: 15, attendee_name: 'Private attendee' }, credentialHash: 'd'.repeat(64), source: 'offline' })
    await clearAllAdmissionData()
    expect(await loadAuthorizedScanner(eventId)).toBeNull()
    expect(await localScanState(eventId, 15)).toBeNull()
    window.localStorage.setItem('hafapass_scanner_user_id', 'staff-b')
    expect(await queuedActions(eventId, 44)).toHaveLength(0)
    expect(await loadPendingDeviceIdentity(eventId)).toBeUndefined()
    window.localStorage.setItem('hafapass_scanner_user_id', 'staff-a')
    expect(await loadPendingDeviceIdentity(eventId)).toMatchObject({ device_id: 44, identifier: 'device-owned-by-a' })
    const pending = await queuedActions(eventId, 44)
    expect(pending).toHaveLength(1)
    expect(JSON.stringify(pending)).not.toContain('Private attendee')
    await saveDevice(eventId, device)
    expect((await loadDevice(eventId)).next_sequence).toBe(1)
    await applySyncResults(eventId, { ...device, last_sequence: 1 }, [{ action_uuid: pending[0].action_uuid, ticket_id: 15, kind: 'admit', result: 'accepted' }])
    expect(await queuedActions(eventId, 44)).toHaveLength(0)
  })

  it('removes expired authorization and attendee data without losing unacknowledged scans', async () => {
    const eventId = 91005
    const now = Date.now()
    const device = { id: 45, identifier: 'expiring-device', effective: true, last_sequence: 0, authorization_expires_at: new Date(now + 1_000).toISOString() }
    await saveDevice(eventId, device)
    await saveVerifiedManifest(await signedManifest(eventId))
    await queueAdmission({ eventId, deviceId: 45, manifestVersion: 1, ticket: { ticket_id: 16, attendee_name: 'Private attendee' }, credentialHash: 'e'.repeat(64), source: 'offline' })
    vi.spyOn(Date, 'now').mockReturnValue(now + 2_000)
    expect(await loadAuthorizedScanner(eventId)).toBeNull()
    expect(await loadUsableManifest(eventId)).toBeNull()
    expect(await localScanState(eventId, 16)).toBeNull()
    expect(await queuedActions(eventId, 45)).toHaveLength(1)
  })

  it('finds and hashes a credential in a 500-ticket cached manifest within 100ms at p95', async () => {
    const credential = 'admission-performance-credential'
    const targetHash = await sha256Hex(credential)
    const entries = Array.from({ length: 500 }, (_, index) => ({
      ticket_id: index + 1,
      credential_hash: index === 499 ? targetHash : index.toString(16).padStart(64, '0'),
    }))
    const index = new Map(entries.map(ticket => [ticket.credential_hash, ticket]))
    const samples = []
    for (let attempt = 0; attempt < 20; attempt += 1) {
      const started = performance.now()
      const hash = await sha256Hex(credential)
      expect(index.get(hash)?.ticket_id).toBe(500)
      samples.push(performance.now() - started)
    }
    samples.sort((left, right) => left - right)
    expect(samples[Math.ceil(samples.length * 0.95) - 1]).toBeLessThan(100)
  })

  it('removes admission access and attendee state after invalid verification while retaining pinned trust and minimal pending journal', async () => {
    const eventId = 91006
    const device = { id: 46, identifier: 'invalid-manifest-device', effective: true, authorization_expires_at: new Date(Date.now() + 60_000).toISOString() }
    await saveDevice(eventId, device)
    const envelope = await signedManifest(eventId)
    await saveVerifiedManifest(envelope)
    await queueAdmission({ eventId, deviceId: device.id, manifestVersion: 1, ticket: { ticket_id: 17, attendee_name: 'Private attendee' }, credentialHash: 'f'.repeat(64), source: 'offline' })
    await invalidateManifestAccess(eventId)
    expect(await loadAuthorizedScanner(eventId)).toBeNull()
    expect(await localScanState(eventId, 17)).toBeUndefined()
    expect(await loadPendingDeviceIdentity(eventId)).toMatchObject({ device_id: device.id })
    expect(await queuedActions(eventId, device.id)).toHaveLength(1)
    expect(JSON.stringify(await queuedActions(eventId, device.id))).not.toContain('Private attendee')
    await expect(clearEventAdmissionData(eventId, { requireEmptyQueue: true })).rejects.toThrow('Sync every queued action')
    expect(await queuedActions(eventId, device.id)).toHaveLength(1)
    expect(await loadPendingDeviceIdentity(eventId)).toMatchObject({ device_id: device.id })
    // The old trust pin still refuses a changed key until a deliberate reset.
    const replacementKey = new TextEncoder().encode('replacement-spki')
    await expect(saveVerifiedManifest({ ...envelope, public_key_spki: toBase64(replacementKey), key_id: await sha256Hex(replacementKey) })).rejects.toThrow('Scanner signing key changed')
  })
  it('acknowledges the original account journal after access expires without recreating attendee access', async () => {
    const eventId = 91007
    window.localStorage.setItem('hafapass_scanner_user_id', 'staff-a')
    const device = { id: 47, identifier: 'expired-manifest-device', effective: true, authorization_expires_at: new Date(Date.now() + 60_000).toISOString() }
    await saveDevice(eventId, device)
    await saveVerifiedManifest(await signedManifest(eventId))
    const action = await queueAdmission({ eventId, deviceId: device.id, manifestVersion: 1, ticket: { ticket_id: 18, attendee_name: 'Private attendee' }, credentialHash: 'a'.repeat(64), source: 'offline' })
    await purgeExpiredAdmissionAccess(eventId)
    expect(await applySyncResults(eventId, { ...device, last_sequence: 1 }, [{ action_uuid: action.action_uuid, ticket_id: 18, kind: 'admit', result: 'accepted' }], 'staff-a')).toBe(1)
    expect(await queuedActions(eventId, device.id)).toHaveLength(0)
    expect(await loadDevice(eventId)).toBeNull()
    expect(await loadUsableManifest(eventId)).toBeNull()
    expect(await localScanState(eventId, 18)).toBeNull()
  })

  it('serializes renewed device sequence snapshots with an admission from another tab', async () => {
    const eventId = 91008
    const device = { id: 48, user: { id: 7 }, identifier: 'renewed-device', effective: true, last_sequence: 0, authorization_expires_at: new Date(Date.now() + 60_000).toISOString() }
    await saveDevice(eventId, device)
    let otherTabFinished
    let overlap = true
    const originalGetAll = IDBIndex.prototype.getAll
    vi.spyOn(IDBIndex.prototype, 'getAll').mockImplementation(function (...args) {
      const request = originalGetAll.apply(this, args)
      if (overlap && this.name === 'event_device') {
        overlap = false
        // A second connection requests admission writes exactly while renewal reads
        // its queue snapshot. IndexedDB must serialize the complete renewal with it.
        const transaction = this.objectStore.transaction.db.transaction(['devices', 'queue'], 'readwrite')
        otherTabFinished = new Promise((resolve, reject) => {
          transaction.oncomplete = resolve
          transaction.onerror = reject
        })
        const getDevice = transaction.objectStore('devices').get(eventId)
        getDevice.onsuccess = () => {
          const sequence = Number(getDevice.result.next_sequence || 0) + 1
          transaction.objectStore('devices').put({ ...getDevice.result, next_sequence: sequence })
          transaction.objectStore('queue').put({ action_uuid: 'other-tab-admission', event_id: eventId, device_id: device.id, owner_user_id: getDevice.result.owner_user_id, sequence, kind: 'admit', ticket_id: 1900 })
        }
      }
      return request
    })
    await saveDevice(eventId, device)
    await otherTabFinished
    const admission = await queueAdmission({ eventId, deviceId: device.id, manifestVersion: 1, ticket: { ticket_id: 2000 }, credentialHash: 'c'.repeat(64), source: 'offline' })
    expect((await queuedActions(eventId, device.id)).map(action => action.sequence)).toEqual([1, 2])
    expect(admission.sequence).toBe(2)
    expect((await loadDevice(eventId)).next_sequence).toBe(2)
  })

  it('does not apply a previous account response or another device acknowledgement to current access', async () => {
    const eventId = 91009
    window.localStorage.setItem('hafapass_scanner_user_id', 'staff-a')
    const device = { id: 49, identifier: 'account-a-device', effective: true, authorization_expires_at: new Date(Date.now() + 60_000).toISOString() }
    await saveDevice(eventId, device)
    const action = await queueAdmission({ eventId, deviceId: device.id, manifestVersion: 1, ticket: { ticket_id: 20 }, credentialHash: 'd'.repeat(64), source: 'offline' })
    const result = { action_uuid: action.action_uuid, ticket_id: 20, kind: 'admit', result: 'accepted' }
    await clearAllAdmissionData()
    window.localStorage.setItem('hafapass_scanner_user_id', 'staff-b')
    const currentDevice = { ...device, id: 50, identifier: 'account-b-device' }
    await saveDevice(eventId, currentDevice)
    expect(await applySyncResults(eventId, device, [result], 'staff-a')).toBe(0)
    expect(await loadDevice(eventId)).toMatchObject({ id: 50, owner_user_id: 'staff-b' })
    window.localStorage.setItem('hafapass_scanner_user_id', 'staff-a')
    expect(await applySyncResults(eventId, currentDevice, [result], 'staff-a')).toBe(0)
    expect(await queuedActions(eventId, device.id)).toHaveLength(1)
  })

  it('retains a scan when acknowledgement is nonterminal or has a different action kind', async () => {
    const eventId = 91010
    const device = { id: 51, identifier: 'terminal-result-device', effective: true, authorization_expires_at: new Date(Date.now() + 60_000).toISOString() }
    await saveDevice(eventId, device)
    const action = await queueAdmission({ eventId, deviceId: device.id, manifestVersion: 1, ticket: { ticket_id: 21 }, credentialHash: 'e'.repeat(64), source: 'offline' })
    expect(await applySyncResults(eventId, device, [{ action_uuid: action.action_uuid, kind: 'admit', result: 'processing' }])).toBe(0)
    expect(await applySyncResults(eventId, device, [{ action_uuid: action.action_uuid, kind: 'reverse', result: 'accepted' }])).toBe(0)
    expect(await queuedActions(eventId, device.id)).toHaveLength(1)
    expect(await applySyncResults(eventId, device, [{ action_uuid: action.action_uuid, kind: 'admit', result: 'accepted' }])).toBe(1)
    expect(await queuedActions(eventId, device.id)).toHaveLength(0)
  })

})
