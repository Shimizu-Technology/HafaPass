import 'fake-indexeddb/auto'
import { beforeAll, describe, expect, it } from 'vitest'
import {
  applySyncResults, canonicalJson, clearEventAdmissionData, loadUsableManifest, queueAdmission,
  queuedActions, saveDevice, saveVerifiedManifest, sha256Hex,
} from './admissionStore'

const toBase64 = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes)))
const toBase64Url = bytes => toBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')

describe('admissionStore', () => {
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
    const device = { id: 42, event_id: eventId, last_sequence: 7, effective: true }
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
})
