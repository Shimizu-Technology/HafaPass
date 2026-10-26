import { useEffect, useState } from 'react'
import { currentScannerOwner, pendingDeviceIdentities, queuedActions } from '../../utils/admissionStore'
import { downloadJournalFile, journalExport } from '../../utils/admissionJournal'

export default function SavedJournalExports({ owner, pendingCount, eventId }) {
  const [journals, setJournals] = useState([])
  const [message, setMessage] = useState('')
  useEffect(() => {
    let active = true
    setMessage('')
    const load = async () => {
      const identities = await pendingDeviceIdentities()
      const entries = await Promise.all(identities.map(async identity => ({ identity,
        count: (await queuedActions(identity.event_id, identity.device_id)).length })))
      if (active && owner === currentScannerOwner()) setJournals(entries.filter(item => item.count))
    }
    load().catch(() => { if (active) setMessage('Saved journals could not be listed. Keep this browser data and ask a manager for help.') })
    return () => { active = false }
  }, [owner, pendingCount, eventId])

  async function exportJournal(identity) {
    try {
      const actions = await queuedActions(identity.event_id, identity.device_id)
      if (owner !== currentScannerOwner()) return
      downloadJournalFile(journalExport(identity.event_id, identity, actions), `hafapass-journal-${identity.event_id}-${identity.device_id}.json`)
      setMessage('Journal exported. Original scans remain on this browser. Share the file privately with the event manager; do not admit guests again.')
    } catch (error) { setMessage(error.message || 'Export failed. Keep this browser data and ask a manager for help.') }
  }

  return <div className="mt-3 space-y-2">
    {journals.filter(({ identity }) => identity.owner_user_id === owner && owner === currentScannerOwner()).map(({ identity, count }) => <div key={`${identity.event_id}:${identity.device_id}`}>
      <p className="text-sm">Event {identity.event_id} · {count} saved scans awaiting reconciliation</p>
      <button className="btn-secondary mt-1 min-h-11" onClick={() => exportJournal(identity)}>Export saved scans for event {identity.event_id}</button>
    </div>)}
    {message && <p role="status" className="text-sm">{message}</p>}
  </div>
}
