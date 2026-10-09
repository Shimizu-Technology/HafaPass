import { openDB } from 'idb'

const DB_NAME = 'hafapass-admissions'
const DB_VERSION = 2

export const currentScannerOwner = () => window.localStorage.getItem('hafapass_scanner_user_id') || (import.meta.env.PROD ? null : 'local-preview')

const database = () => openDB(DB_NAME, DB_VERSION, {
  upgrade(db, oldVersion, _newVersion, transaction) {
    if (oldVersion < 2) db.createObjectStore('journal_devices', { keyPath: ['owner_user_id', 'event_id'] })
    if (oldVersion === 1) {
      // Legacy caches had no verified account binding. Renew online before exposing attendee data.
      transaction.objectStore('devices').getAll().then(async devices => {
        for (const device of devices) {
          if (device.user?.id && device.identifier) await transaction.objectStore('journal_devices').put({
            owner_user_id: `legacy:${device.user.id}`, event_id: device.event_id,
            device_id: device.id, identifier: device.identifier,
          })
        }
        await transaction.objectStore('devices').clear()
      })
      transaction.objectStore('manifests').clear()
      transaction.objectStore('scan_states').clear()
    }
    if (oldVersion >= 1) return
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
  const expiry = new Date(envelope.payload.expires_at).getTime()
  if (!Number.isFinite(expiry) || expiry <= Date.now()) throw new Error('Scanner manifest has expired')

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
    owner_user_id: currentScannerOwner(),
  })
  await transaction.done
  return envelope
}

export async function loadUsableManifest(eventId) {
  const db = await database()
  const record = await db.get('manifests', Number(eventId))
  if (!record || record.owner_user_id !== currentScannerOwner()) return null
  const expiry = new Date(record.envelope?.payload?.expires_at).getTime()
  if (!Number.isFinite(expiry) || expiry <= Date.now()) {
    await purgeExpiredAdmissionAccess(eventId)
    return null
  }
  const trustedKey = await db.get('trusted_keys', Number(eventId))
  await verifyManifestEnvelope(record.envelope, trustedKey)
  return record.envelope
}

export async function saveDevice(eventId, device) {
  const db = await database()
  const owner = currentScannerOwner()
  if (!owner) throw new Error('Sign in before authorizing this scanner.')
  // Renewal and admission allocation share the same lock across every browser tab.
  const transaction = db.transaction(['devices', 'queue', 'journal_devices'], 'readwrite')
  const devices = transaction.objectStore('devices')
  const journal = transaction.objectStore('journal_devices')
  const previous = await devices.get(Number(eventId))
  const prior = previous?.owner_user_id === owner ? previous : null
  const pending = await transaction.objectStore('queue').index('event_device').getAll([Number(eventId), Number(device.id)])
  const legacy = device.user?.id ? await journal.get([`legacy:${device.user.id}`, Number(eventId)]) : null
  if (owner !== currentScannerOwner()) {
    transaction.abort()
    await transaction.done.catch(() => {})
    throw new Error('Scanner account changed. Reconnect with the original staff account.')
  }
  const ownedPending = pending.filter(action => action.owner_user_id === owner || (!action.owner_user_id && legacy?.device_id === device.id))
  for (const action of ownedPending.filter(action => !action.owner_user_id)) await transaction.objectStore('queue').put({ ...action, owner_user_id: owner })
  const serverSequence = Number(device.last_sequence || 0)
  await devices.put({
    ...prior,
    ...device,
    event_id: Number(eventId),
    owner_user_id: owner,
    next_sequence: Math.max(Number(prior?.next_sequence || 0), serverSequence, ...ownedPending.map(action => action.sequence)),
  })
  await journal.put({ owner_user_id: owner, event_id: Number(eventId), device_id: device.id, identifier: device.identifier })
  if (owner !== currentScannerOwner()) {
    transaction.abort()
    await transaction.done.catch(() => {})
    throw new Error('Scanner account changed. Reconnect with the original staff account.')
  }
  await transaction.done
}

export async function loadPendingDeviceIdentity(eventId, verifiedBackendUserId = null) {
  const owner = currentScannerOwner()
  if (!owner) return null
  const db = await database()
  const identity = await db.get('journal_devices', [owner, Number(eventId)])
  if (identity || !verifiedBackendUserId) return identity
  return db.get('journal_devices', [`legacy:${Number(verifiedBackendUserId)}`, Number(eventId)])
}

export async function loadDevice(eventId) {
  const device = await (await database()).get('devices', Number(eventId))
  return device?.owner_user_id === currentScannerOwner() ? device : null
}

export async function loadAuthorizedScanner(eventId) {
  if (!eventId) return null
  const device = await loadDevice(eventId)
  const expiry = new Date(device?.authorization_expires_at).getTime()
  if (!device?.effective || !Number.isFinite(expiry) || expiry <= Date.now()) {
    if (device) await purgeExpiredAdmissionAccess(eventId)
    return null
  }
  const manifest = await loadUsableManifest(eventId)
  return manifest ? { device, manifest } : null
}

// A failed verification removes cached admission access and attendee details, while keeping
// the pinned key and minimal journal so existing scans can sync before an explicit trust reset.
export async function invalidateManifestAccess(eventId) {
  const db = await database()
  const transaction = db.transaction(['devices', 'manifests', 'scan_states'], 'readwrite')
  const device = await transaction.objectStore('devices').get(Number(eventId))
  if (device?.owner_user_id === currentScannerOwner()) {
    await transaction.objectStore('manifests').delete(Number(eventId))
    const keys = await transaction.objectStore('scan_states').getAllKeys()
    for (const key of keys.filter(key => key[0] === Number(eventId))) await transaction.objectStore('scan_states').delete(key)
  }
  await transaction.done
}

// Expiry removes access and attendee data; unacknowledged actions are retained for renewal and sync.
export async function purgeExpiredAdmissionAccess(eventId) {
  const db = await database()
  const transaction = db.transaction(['manifests', 'devices', 'trusted_keys', 'scan_states'], 'readwrite')
  for (const name of ['manifests', 'devices', 'trusted_keys']) await transaction.objectStore(name).delete(Number(eventId))
  const states = await transaction.objectStore('scan_states').getAllKeys()
  for (const key of states.filter(key => key[0] === Number(eventId))) await transaction.objectStore('scan_states').delete(key)
  await transaction.done
}

// A shared door device must forget attendee data and authorization on account changes.
export async function clearAllAdmissionData() {
  const db = await database()
  const transaction = db.transaction(['manifests', 'devices', 'trusted_keys', 'scan_states'], 'readwrite')
  await Promise.all(Array.from(transaction.objectStoreNames).map(name => transaction.objectStore(name).clear()))
  await transaction.done
  window.localStorage.removeItem('hafapass_scanner_browser_id')
  window.localStorage.removeItem('hafapass_scanner_event_id')
}

export async function queueAdmission({ eventId, deviceId, manifestVersion, ticket, credentialHash, source, clientStatus = 'locally_accepted' }) {
  const db = await database()
  const transaction = db.transaction(['devices', 'queue', 'scan_states'], 'readwrite')
  const devices = transaction.objectStore('devices')
  const storedDevice = await devices.get(Number(eventId))
  if (!storedDevice || storedDevice.id !== deviceId || storedDevice.owner_user_id !== currentScannerOwner()) throw new Error('Scanner device is not registered')
  const authorizationExpiry = new Date(storedDevice.authorization_expires_at).getTime()
  if (!storedDevice.effective || !Number.isFinite(authorizationExpiry) || authorizationExpiry <= Date.now()) throw new Error('Scanner authorization has expired. Reconnect before scanning.')
  const scanStates = transaction.objectStore('scan_states')
  const prior = await scanStates.get([Number(eventId), Number(ticket.ticket_id)])
  const pending = await transaction.objectStore('queue').index('event_device').getAll([Number(eventId), Number(deviceId)])
  if (['pending', 'accepted', 'conflict', 'pending_reverse'].includes(prior?.status) || pending.some(action => Number(action.ticket_id) === Number(ticket.ticket_id) && action.kind === 'admit')) {
    await transaction.done
    return null
  }
  const sequence = Number(storedDevice.next_sequence || storedDevice.last_sequence || 0) + 1
  const action = {
    action_uuid: crypto.randomUUID(),
    event_id: Number(eventId),
    device_id: deviceId,
    owner_user_id: storedDevice.owner_user_id,
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
  await scanStates.put({
    event_id: Number(eventId),
    ticket_id: Number(ticket.ticket_id),
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
  if (!storedDevice || storedDevice.id !== deviceId || storedDevice.owner_user_id !== currentScannerOwner()) throw new Error('Scanner device is not registered')
  const authorizationExpiry = new Date(storedDevice.authorization_expires_at).getTime()
  if (!storedDevice.effective || !Number.isFinite(authorizationExpiry) || authorizationExpiry <= Date.now()) throw new Error('Scanner authorization has expired. Reconnect before scanning.')
  const sequence = Number(storedDevice.next_sequence || storedDevice.last_sequence || 0) + 1
  const action = {
    action_uuid: crypto.randomUUID(),
    event_id: Number(eventId),
    device_id: deviceId,
    owner_user_id: storedDevice.owner_user_id,
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
  return actions.filter(action => action.owner_user_id === currentScannerOwner()).sort((left, right) => left.sequence - right.sequence)
}

export async function localScanState(eventId, ticketId) {
  if (!(await loadDevice(eventId))) return null
  return (await database()).get('scan_states', [Number(eventId), Number(ticketId)])
}

export async function applySyncResults(eventId, device, results, owner = currentScannerOwner()) {
  if (!owner || owner !== currentScannerOwner()) return 0
  const db = await database()
  const transaction = db.transaction(['devices', 'queue', 'scan_states', 'journal_devices'], 'readwrite')
  const devices = transaction.objectStore('devices')
  const storedDevice = await devices.get(Number(eventId))
  const identity = await transaction.objectStore('journal_devices').get([owner, Number(eventId)])
  const hasAccess = storedDevice?.owner_user_id === owner && storedDevice.id === device.id
  // Expiry/sign-out can remove attendee access during a request. The original owner's
  // minimal journal still permits acknowledgement, without recreating admission access.
  if ((!hasAccess && identity?.device_id !== device.id) || owner !== currentScannerOwner()) {
    await transaction.done
    return 0
  }
  let acknowledged = 0
  for (const result of results) {
    if (!['accepted', 'conflict', 'rejected'].includes(result.result)) continue
    const queued = await transaction.objectStore('queue').get(result.action_uuid)
    if (!queued || queued.kind !== result.kind || queued.owner_user_id !== owner || queued.event_id !== Number(eventId) || queued.device_id !== device.id) continue
    if (owner !== currentScannerOwner()) {
      transaction.abort()
      await transaction.done.catch(() => {})
      return 0
    }
    await transaction.objectStore('queue').delete(result.action_uuid)
    acknowledged += 1
    if (!hasAccess || !result.ticket_id) continue
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
  if (owner !== currentScannerOwner()) {
    transaction.abort()
    await transaction.done.catch(() => {})
    return 0
  }
  if (hasAccess) await devices.put({
    ...storedDevice,
    ...device,
    event_id: Number(eventId),
    owner_user_id: owner,
    next_sequence: Math.max(Number(storedDevice.next_sequence || 0), Number(device.last_sequence || 0)),
  })
  await transaction.done
  return acknowledged
}

export async function clearEventAdmissionData(eventId, { requireEmptyQueue = false } = {}) {
  const db = await database()
  const transaction = db.transaction(['manifests', 'devices', 'trusted_keys', 'queue', 'scan_states', 'journal_devices'], 'readwrite')
  const queued = await transaction.objectStore('queue').index('event_device').getAll(
    IDBKeyRange.bound([Number(eventId), 0], [Number(eventId), Number.MAX_SAFE_INTEGER]),
  )
  const ownedActions = queued.filter(action => action.owner_user_id === currentScannerOwner())
  if (requireEmptyQueue && ownedActions.length) {
    transaction.abort()
    await transaction.done.catch(() => {})
    throw new Error('Sync every queued action before resetting this scanner.')
  }
  await transaction.objectStore('manifests').delete(Number(eventId))
  await transaction.objectStore('devices').delete(Number(eventId))
  await transaction.objectStore('trusted_keys').delete(Number(eventId))
  for (const action of ownedActions) await transaction.objectStore('queue').delete(action.action_uuid)
  if (currentScannerOwner()) await transaction.objectStore('journal_devices').delete([currentScannerOwner(), Number(eventId)])
  const states = await transaction.objectStore('scan_states').getAllKeys()
  for (const key of states.filter(key => key[0] === Number(eventId))) {
    await transaction.objectStore('scan_states').delete(key)
  }
  await transaction.done
}
