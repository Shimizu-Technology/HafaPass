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

  it('distinguishes same-name tickets and sends Undo for the selected admission only', async () => {
    const eventId = 94401
    const device = { id: 43, identifier: 'history-device', effective: true, last_sequence: 3,
      authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const ticket = { ticket_id: 14, state: 'admitted', credential_hash: 'c'.repeat(64), attendee_name: 'Guest' }
    const manifest = await signedManifest(eventId, [ticket, { ...ticket, ticket_id: 15 }])
    const synced = []
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/organizer/events'
      ? { events: [{ id: eventId, title: 'History event' }] }
      : url.endsWith('/manifest') ? manifest : { counts: {}, permissions: { can_reverse: true }, recent_actions: [
        { action_uuid: 'admission-a', ticket_id: 14, kind: 'admit', result: 'accepted', reversed: true, attendee: { attendee_name: 'José & Ana', code: 'HP-T14' } },
        { action_uuid: 'admission-b', ticket_id: 15, kind: 'admit', result: 'accepted', reversed: false, attendee: { attendee_name: 'José & Ana', code: 'HP-T15' } },
      ] } }))
    apiClient.post.mockImplementation((url, payload) => {
      if (!url.endsWith('/sync')) return Promise.resolve({ data: device })
      synced.push(...payload.actions)
      return Promise.resolve({ data: { device: { ...device, last_sequence: payload.actions.at(-1).sequence },
        results: payload.actions.map(action => ({ ...action, result: 'accepted', reason_code: 'reversed' })), summary: {} } })
    })
    render(<MemoryRouter initialEntries={[`/dashboard/scanner?event=${eventId}`]}><ScannerPage /></MemoryRouter>)
    expect(await screen.findByText('HP-T14')).toBeInTheDocument()
    expect(screen.getByText('HP-T15')).toBeInTheDocument()
    expect(screen.getAllByText('José & Ana')).toHaveLength(2)
    const reversed = screen.getByRole('button', { name: 'Reversed admission for HP-T14' })
    const undo = screen.getByRole('button', { name: 'Undo admission for HP-T15' })
    expect(reversed).toBeDisabled()
    expect(undo).toBeEnabled()
    await screen.findByText(/Manifest v1/)
    await userEvent.setup().click(reversed)
    expect(synced).toHaveLength(0)
    await userEvent.setup().click(undo)
    await waitFor(() => expect(synced).toHaveLength(1))
    expect(synced[0]).toMatchObject({ kind: 'reverse', reverses_action_uuid: 'admission-b', ticket_id: 15 })
  })

  it.each([['download', 'owner-b', false], ['download', 'owner-a', false], ['setup', 'owner-a', false],
    ['download', 'owner-b', true], ['download', 'owner-a', true], ['setup', 'owner-a', true],
    ['download', 'owner-a', true, true]])(
    'does not let a late %s callback invalidate the newer accepted guard for %s (bad signature: %s, same key: %s)', async (phase, nextOwner, badSignature, sameSigningKey) => {
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
      const corruptSignature = envelope => badSignature ? { ...envelope, signature: 'A'.repeat(envelope.signature.length) } : envelope
      let manifestResponse = phase === 'setup' ? corruptSignature(initial) : initial
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
        manifestResponse = corruptSignature(await signedManifest(eventId,
          [{ ...ticket, reversed_admission_action_uuids: [originalAction.action_uuid] }], { version: 3 }))
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
      const current = sameSigningKey ? await signedManifest(eventId, [ticket], { version: 4 })
        : await signWithKey({ ...initial.payload, version: 4, tickets: [ticket] }, keys)
      await saveVerifiedManifest(current)
      const later = await queueAdmission({ ...input, deviceId: replacementDevice.id, manifestVersion: 4 })
      await applySyncResults(eventId, replacementDevice, [{ action_uuid: later.action_uuid,
        ticket_id: ticket.ticket_id, kind: 'admit', result: 'accepted' }])
      const latest = sameSigningKey ? await signedManifest(eventId, [{ ...ticket, state: 'admitted' }], { version: 5 })
        : await signWithKey({ ...current.payload, version: 5, tickets: [{ ...ticket, state: 'admitted' }] }, keys)
      await saveVerifiedManifest(latest)
      await act(async () => finishVerification())
      if (sameSigningKey) await screen.findByText(/Scanner manifest changed while verifying/)
      else if (phase === 'setup' || nextOwner === 'owner-a') await screen.findByText(/Scanner signing key changed while verifying/)
      else await waitFor(() => expect(screen.getByRole('button', { name: 'Sync now' }).querySelector('.animate-spin')).toBeNull())
      expect((await loadUsableManifest(eventId)).digest).toBe(latest.digest)
      expect((await localScanState(eventId, ticket.ticket_id)).action_uuid).toBe(later.action_uuid)
      expect(await queueAdmission({ ...input, deviceId: replacementDevice.id, manifestVersion: 5 })).toBeNull()
    },
  )
})
