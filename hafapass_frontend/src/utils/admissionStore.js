import { openDB } from 'idb'

const DB_NAME = 'hafapass-admissions'
const DB_VERSION = 1

const database = () => openDB(DB_NAME, DB_VERSION, {
  upgrade(db) {
    db.createObjectStore('manifests', { keyPath: 'event_id' })
    db.createObjectStore('devices', { keyPath: 'event_id' })
    db.createObjectStore('trusted_keys', { keyPath: 'event_id' })
    const queue = db.createObjectStore('queue', { keyPath: 'action_uuid' })
    queue.createIndex('event_device', ['event_id', 'device_id'])
    db.createObjectStore('scan_states', { keyPath: ['event_id', 'ticket_id'] })
  },
})

export function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`
  if (value !== null && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`
  }
  return JSON.stringify(value)
}

export async function sha256Hex(value) {
  const bytes = typeof value === 'string' ? new TextEncoder().encode(value) : value
  const digest = await crypto.subtle.digest('SHA-256', bytes)
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('')
}

function base64Bytes(value, urlSafe = false) {
  let normalized = urlSafe ? value.replace(/-/g, '+').replace(/_/g, '/') : value
  normalized += '='.repeat((4 - (normalized.length % 4)) % 4)
  return Uint8Array.from(atob(normalized), character => character.charCodeAt(0))
}

export async function verifyManifestEnvelope(envelope, trustedKey = null) {
  if (envelope?.algorithm !== 'PS256' || !envelope.payload || !envelope.public_key_spki) {
    throw new Error('Scanner manifest envelope is incomplete')
  }
  if (new Date(envelope.payload.expires_at).getTime() <= Date.now()) throw new Error('Scanner manifest has expired')

  const publicKeyBytes = base64Bytes(envelope.public_key_spki)
  const computedKeyId = await sha256Hex(publicKeyBytes)
  if (computedKeyId !== envelope.key_id) throw new Error('Scanner signing key identity is invalid')
  if (trustedKey && (trustedKey.key_id !== envelope.key_id || trustedKey.public_key_spki !== envelope.public_key_spki)) {
    throw new Error('Scanner signing key changed; reset this device while online before continuing')
  }

  const computedDigest = await sha256Hex(canonicalJson(envelope.payload))
  if (computedDigest !== envelope.digest) throw new Error('Scanner manifest digest is invalid')
  const key = await crypto.subtle.importKey(
    'spki',
    publicKeyBytes,
    { name: 'RSA-PSS', hash: 'SHA-256' },
    false,
    ['verify'],
  )
  const valid = await crypto.subtle.verify(
    { name: 'RSA-PSS', saltLength: 32 },
    key,
    base64Bytes(envelope.signature, true),
    new TextEncoder().encode(envelope.digest),
  )
  if (!valid) throw new Error('Scanner manifest signature is invalid')
  return true
}

export async function saveVerifiedManifest(envelope) {
  const eventId = Number(envelope?.payload?.event?.id)
  if (!eventId) throw new Error('Scanner manifest event is invalid')
  const db = await database()
  const trustedKey = await db.get('trusted_keys', eventId)
  await verifyManifestEnvelope(envelope, trustedKey)
  const transaction = db.transaction(['manifests', 'trusted_keys'], 'readwrite')
  await transaction.objectStore('trusted_keys').put({
    event_id: eventId,
    key_id: envelope.key_id,
    public_key_spki: envelope.public_key_spki,
  })
  await transaction.objectStore('manifests').put({
    event_id: eventId,
    envelope,
    downloaded_at: new Date().toISOString(),
  })
  await transaction.done
  return envelope
}

export async function loadUsableManifest(eventId) {
  const db = await database()
  const record = await db.get('manifests', Number(eventId))
  if (!record) return null
  if (new Date(record.envelope.payload.expires_at).getTime() <= Date.now()) {
    await db.delete('manifests', Number(eventId))
    return null
  }
  const trustedKey = await db.get('trusted_keys', Number(eventId))
  await verifyManifestEnvelope(record.envelope, trustedKey)
  return record.envelope
}

export async function saveDevice(eventId, device) {
  const db = await database()
  const prior = await db.get('devices', Number(eventId))
  const serverSequence = Number(device.last_sequence || 0)
  await db.put('devices', {
    ...prior,
    ...device,
    event_id: Number(eventId),
    next_sequence: Math.max(Number(prior?.next_sequence || 0), serverSequence),
  })
}

export async function loadDevice(eventId) {
  return (await database()).get('devices', Number(eventId))
}

export async function queueAdmission({ eventId, deviceId, manifestVersion, ticket, credentialHash, source, clientStatus = 'locally_accepted' }) {
  const db = await database()
  const transaction = db.transaction(['devices', 'queue', 'scan_states'], 'readwrite')
  const devices = transaction.objectStore('devices')
  const storedDevice = await devices.get(Number(eventId))
  if (!storedDevice || storedDevice.id !== deviceId) throw new Error('Scanner device is not registered')
  const sequence = Number(storedDevice.next_sequence || storedDevice.last_sequence || 0) + 1
  const action = {
    action_uuid: crypto.randomUUID(),
    event_id: Number(eventId),
    device_id: deviceId,
    kind: 'admit',
    source,
    sequence,
    manifest_version: manifestVersion,
    occurred_at: new Date().toISOString(),
    ticket_id: ticket.ticket_id,
    credential_hash: credentialHash,
    client_status: clientStatus,
  }
  storedDevice.next_sequence = sequence
  await devices.put(storedDevice)
  await transaction.objectStore('queue').put(action)
  await transaction.objectStore('scan_states').put({
    event_id: Number(eventId),
    ticket_id: ticket.ticket_id,
    status: 'pending',
    action_uuid: action.action_uuid,
    attendee_name: ticket.attendee_name,
    ticket_type: ticket.ticket_type,
    occurred_at: action.occurred_at,
  })
  await transaction.done
  return action
}

export async function queueReversal({ eventId, deviceId, manifestVersion, ticketId, reversesActionUuid, source = 'online' }) {
  const db = await database()
  const transaction = db.transaction(['devices', 'queue', 'scan_states'], 'readwrite')
  const devices = transaction.objectStore('devices')
  const storedDevice = await devices.get(Number(eventId))
  if (!storedDevice || storedDevice.id !== deviceId) throw new Error('Scanner device is not registered')
  const sequence = Number(storedDevice.next_sequence || storedDevice.last_sequence || 0) + 1
  const action = {
    action_uuid: crypto.randomUUID(),
    event_id: Number(eventId),
    device_id: deviceId,
    kind: 'reverse',
    source,
    sequence,
    manifest_version: manifestVersion,
    occurred_at: new Date().toISOString(),
    reverses_action_uuid: reversesActionUuid,
  }
  storedDevice.next_sequence = sequence
  await devices.put(storedDevice)
  await transaction.objectStore('queue').put(action)
  const state = await transaction.objectStore('scan_states').get([Number(eventId), Number(ticketId)])
  await transaction.objectStore('scan_states').put({
    ...state,
    event_id: Number(eventId),
    ticket_id: Number(ticketId),
    status: 'pending_reverse',
    reversal_action_uuid: action.action_uuid,
  })
  await transaction.done
  return action
}

export async function queuedActions(eventId, deviceId) {
  const actions = await (await database()).getAllFromIndex('queue', 'event_device', [Number(eventId), Number(deviceId)])
  return actions.sort((left, right) => left.sequence - right.sequence)
}

export async function localScanState(eventId, ticketId) {
  return (await database()).get('scan_states', [Number(eventId), Number(ticketId)])
}

export async function applySyncResults(eventId, device, results) {
  const db = await database()
  const transaction = db.transaction(['devices', 'queue', 'scan_states'], 'readwrite')
  for (const result of results) {
    await transaction.objectStore('queue').delete(result.action_uuid)
    if (!result.ticket_id) continue
    const key = [Number(eventId), Number(result.ticket_id)]
    const state = await transaction.objectStore('scan_states').get(key)
    if (result.kind === 'reverse' && result.result === 'accepted') {
      await transaction.objectStore('scan_states').delete(key)
    } else {
      await transaction.objectStore('scan_states').put({
        ...state,
        event_id: key[0],
        ticket_id: key[1],
        status: result.result,
        reason_code: result.reason_code,
        action_uuid: result.action_uuid,
        occurred_at: result.occurred_at,
      })
    }
  }
  const storedDevice = await transaction.objectStore('devices').get(Number(eventId))
  await transaction.objectStore('devices').put({
    ...storedDevice,
    ...device,
    event_id: Number(eventId),
    next_sequence: Math.max(Number(storedDevice?.next_sequence || 0), Number(device.last_sequence || 0)),
  })
  await transaction.done
}

export async function clearEventAdmissionData(eventId) {
  const db = await database()
  const transaction = db.transaction(['manifests', 'devices', 'trusted_keys', 'queue', 'scan_states'], 'readwrite')
  await transaction.objectStore('manifests').delete(Number(eventId))
  await transaction.objectStore('devices').delete(Number(eventId))
  await transaction.objectStore('trusted_keys').delete(Number(eventId))
  const queued = await transaction.objectStore('queue').index('event_device').getAllKeys(
    IDBKeyRange.bound([Number(eventId), 0], [Number(eventId), Number.MAX_SAFE_INTEGER]),
  )
  for (const key of queued) await transaction.objectStore('queue').delete(key)
  const states = await transaction.objectStore('scan_states').getAllKeys()
  for (const key of states.filter(key => key[0] === Number(eventId))) {
    await transaction.objectStore('scan_states').delete(key)
  }
  await transaction.done
}
