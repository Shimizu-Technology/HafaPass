// The export is evidence for a manager, never proof of the client scan clock.
export function journalExport(eventId, identity, actions) {
  if (!identity || !actions.length) throw new Error('No saved scans are available for export.')
  return {
    schema: 'hafapass-admission-journal-v1', event_id: Number(eventId), device_id: identity.device_id,
    exported_at: new Date().toISOString(),
    actions: actions.map(({ action_uuid, kind, source, sequence, manifest_version, occurred_at,
      ticket_id, credential_hash, client_status, reverses_action_uuid }) => ({
      action_uuid, kind, source, sequence, manifest_version, occurred_at,
      ticket_id, credential_hash, client_status, reverses_action_uuid,
    })),
  }
}

export function parseJournal(text, eventId) {
  if (text.length > 2_000_000) throw new Error('Journal is too large. Ask support to split it without changing action IDs.')
  const data = JSON.parse(text)
  if (data.schema !== 'hafapass-admission-journal-v1' || data.event_id !== Number(eventId)
    || !Number.isSafeInteger(data.device_id) || data.device_id <= 0 || !Array.isArray(data.actions)
    || !data.actions.length || data.actions.length > 500) {
    throw new Error('Choose a journal for this event with 1–500 saved scans. Keep larger originals for support.')
  }
  return data
}

export function downloadJournalFile(data, name) {
  const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' }))
  const link = document.createElement('a')
  link.href = url
  link.download = name
  link.click()
  URL.revokeObjectURL(url)
}
