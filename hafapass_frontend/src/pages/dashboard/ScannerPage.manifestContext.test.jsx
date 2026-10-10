import 'fake-indexeddb/auto'
import { act, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import { applySyncResults, canonicalJson, clearAllAdmissionData, clearEventAdmissionData, loadUsableManifest,
  localScanState, queueAdmission, saveDevice, saveVerifiedManifest, sha256Hex } from '../../utils/admissionStore'
import { signedManifest } from '../../test/manifestFixture'
import ScannerPage from './ScannerPage'

vi.mock('../../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))

async function signWithKey(payload, keys) {
  const digest = await sha256Hex(canonicalJson(payload))
  const signature = await crypto.subtle.sign({ name: 'RSA-PSS', saltLength: 32 }, keys.privateKey, new TextEncoder().encode(digest))
  const publicKey = await crypto.subtle.exportKey('spki', keys.publicKey)
  const base64 = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes)))
  return { payload, digest, signature: base64(signature).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, ''),
    algorithm: 'PS256', key_id: await sha256Hex(publicKey), public_key_spki: base64(publicKey) }
}

describe('stale manifest callbacks preserve newer account and key state', () => {
  beforeEach(async () => {
    vi.clearAllMocks()
    window.localStorage.clear()
    await clearAllAdmissionData()
    window.localStorage.setItem('hafapass_scanner_user_id', 'owner-a')
  })
  afterEach(() => { vi.restoreAllMocks(); window.localStorage.clear() })

  it.each([['download', 'owner-b'], ['download', 'owner-a'], ['setup', 'owner-a']])(
    'does not let a late %s callback invalidate the newer accepted guard for %s', async (phase, nextOwner) => {
      const eventId = 94401
      const device = { id: 43, identifier: 'original-device', effective: true, last_sequence: 1,
        authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
      const ticket = { ticket_id: 14, state: 'valid', credential_hash: 'c'.repeat(64), attendee_name: 'Guest' }
      await saveDevice(eventId, device)
      const input = { eventId, deviceId: device.id, manifestVersion: 1, ticket, credentialHash: ticket.credential_hash, source: 'online' }
      const originalAction = await queueAdmission(input)
      await applySyncResults(eventId, device, [{ action_uuid: originalAction.action_uuid, ticket_id: ticket.ticket_id, kind: 'admit', result: 'accepted' }])
      const initial = await signedManifest(eventId, [{ ...ticket, state: 'admitted' }], { version: 2 })
      await saveVerifiedManifest(initial)
      window.localStorage.setItem('hafapass_scanner_event_id', String(eventId))
      let manifestResponse = initial
      apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/organizer/events'
        ? { events: [{ id: eventId, title: 'Context event' }] }
        : url.endsWith('/manifest') ? manifestResponse
          : { counts: {}, permissions: { can_reverse: false }, recent_actions: [] } }))
      apiClient.post.mockResolvedValue({ data: device })

      let finishVerification, startedVerification
      const started = new Promise(resolve => { startedVerification = resolve })
      const verify = crypto.subtle.verify.bind(crypto.subtle)
      const pauseVerification = () => {
        let calls = 0
        vi.spyOn(crypto.subtle, 'verify').mockImplementation(async (...args) => {
          const valid = await verify(...args)
          // Setup first verifies its existing cache, then the incoming API envelope.
          if (++calls === (phase === 'setup' ? 2 : 1)) {
            startedVerification()
            await new Promise(resolve => { finishVerification = resolve })
          }
          return valid
        })
      }
      if (phase === 'setup') pauseVerification()
      render(<MemoryRouter><ScannerPage /></MemoryRouter>)
      if (phase === 'download') {
        await screen.findByText(/Manifest v2/)
        manifestResponse = await signedManifest(eventId,
          [{ ...ticket, reversed_admission_action_uuids: [originalAction.action_uuid] }], { version: 3 })
        pauseVerification()
        await userEvent.setup().click(screen.getByRole('button', { name: 'Sync now' }))
      }
      await started

      if (nextOwner !== 'owner-a') {
        await clearAllAdmissionData()
        window.localStorage.setItem('hafapass_scanner_user_id', nextOwner)
      } else await clearEventAdmissionData(eventId)
      const replacementDevice = { ...device, id: nextOwner === 'owner-a' ? device.id : 44 }
      await saveDevice(eventId, replacementDevice)
      const keys = await crypto.subtle.generateKey({ name: 'RSA-PSS', modulusLength: 2048,
        publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify'])
      const current = await signWithKey({ ...initial.payload, version: 4, tickets: [ticket] }, keys)
      await saveVerifiedManifest(current)
      const later = await queueAdmission({ ...input, deviceId: replacementDevice.id, manifestVersion: 4 })
      await applySyncResults(eventId, replacementDevice, [{ action_uuid: later.action_uuid,
        ticket_id: ticket.ticket_id, kind: 'admit', result: 'accepted' }])
      const latest = await signWithKey({ ...current.payload, version: 5, tickets: [{ ...ticket, state: 'admitted' }] }, keys)
      await saveVerifiedManifest(latest)
      await act(async () => finishVerification())
      if (phase === 'setup' || nextOwner === 'owner-a') await screen.findByText(/Scanner signing key changed while verifying/)
      else await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' }).querySelector('.animate-spin')).toBeNull())
      expect((await loadUsableManifest(eventId)).digest).toBe(latest.digest)
      expect((await localScanState(eventId, ticket.ticket_id)).action_uuid).toBe(later.action_uuid)
      expect(await queueAdmission({ ...input, deviceId: replacementDevice.id, manifestVersion: 5 })).toBeNull()
    },
  )
})
