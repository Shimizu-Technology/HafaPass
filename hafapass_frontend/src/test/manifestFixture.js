import { canonicalJson, sha256Hex } from '../utils/admissionStore'

let signingKeys

export async function signedManifest(eventId, tickets = [], options = {}) {
  signingKeys ||= crypto.subtle.generateKey({ name: 'RSA-PSS', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify'])
  const keys = await signingKeys
  const payload = { event: { id: eventId, title: `Event ${eventId}` }, version: 1, expires_at: new Date(Date.now() + 600_000).toISOString(), tickets, ...options }
  const digest = await sha256Hex(canonicalJson(payload))
  const signature = await crypto.subtle.sign({ name: 'RSA-PSS', saltLength: 32 }, keys.privateKey, new TextEncoder().encode(digest))
  const publicKey = await crypto.subtle.exportKey('spki', keys.publicKey)
  const base64 = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes)))
  return { payload, digest, signature: base64(signature).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, ''), algorithm: 'PS256', key_id: await sha256Hex(publicKey), public_key_spki: base64(publicKey) }
}
