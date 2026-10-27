import { useEffect, useState } from 'react'
import { getApiAuthContext } from '../../api/client'
import { captureScannerBindingContext, scannerBindingContextCurrent } from '../../utils/scannerAccountBinding'
import { currentScannerOwner, pendingDeviceIdentities, queuedActions, verifyLegacyJournalOwner } from '../../utils/admissionStore'
import { downloadJournalFile, journalExport } from '../../utils/admissionJournal'

export default function SavedJournalExports({ owner, pendingCount, eventId, recovery = false }) {
  const [journals, setJournals] = useState([])
  const [message, setMessage] = useState('')
  useEffect(() => {
    let active = true
    const auth = getApiAuthContext()
    const binding = captureScannerBindingContext()
    const current = () => active && owner === currentScannerOwner() && auth === getApiAuthContext() && scannerBindingContextCurrent(binding)
    setJournals([])
    setMessage('')
    const load = async () => {
      await verifyLegacyJournalOwner({ isCurrent: current })
      const identities = await pendingDeviceIdentities()
      const entries = await Promise.all(identities.map(async identity => ({ identity,
        count: (await queuedActions(identity.event_id, identity.device_id)).length })))
      if (current()) setJournals(entries.filter(item => item.count))
    }
    load().catch(() => { if (current()) setMessage('Saved journals could not be listed. Keep this browser data and ask a manager for help.') })
    return () => { active = false }
  }, [owner, pendingCount, eventId])

  async function exportJournal(identity) {
    const auth = getApiAuthContext()
    const binding = captureScannerBindingContext()
    try {
      if (identity.legacy_owner_user_id) await verifyLegacyJournalOwner({ force: true, isCurrent: () => owner === currentScannerOwner()
        && auth === getApiAuthContext() && scannerBindingContextCurrent(binding) })
      const actions = await queuedActions(identity.event_id, identity.device_id)
      if (owner !== currentScannerOwner() || auth !== getApiAuthContext() || !scannerBindingContextCurrent(binding)) return
      downloadJournalFile(journalExport(identity.event_id, identity, actions), `hafapass-journal-${identity.event_id}-${identity.device_id}.json`)
      setMessage('Journal exported. Original scans remain on this browser. Share the file privately with the event manager; do not admit guests again.')
    } catch {
      if (owner === currentScannerOwner() && auth === getApiAuthContext() && scannerBindingContextCurrent(binding)) {
        setMessage('Export failed. Keep this browser data, sign in while connected, and ask a manager for help.')
      }
    }
  }

  const ownedJournals = journals.filter(({ identity }) => identity.owner_user_id === owner && owner === currentScannerOwner())
  if (recovery && !ownedJournals.length && !message) return null

  return <div className={recovery ? 'max-w-2xl space-y-2 rounded-xl border border-amber-200 bg-amber-50 p-4 text-amber-950' : 'mt-3 space-y-2'}>
    {recovery && ownedJournals.length > 0 && <p className="text-sm">Saved scans still need reconciliation. Keep this browser data and use the original staff account. Export the scans and share the file privately with the event manager; do not admit these guests again.</p>}
    {ownedJournals.map(({ identity, count }) => <div key={`${identity.event_id}:${identity.device_id}`}>
      <p className="text-sm">Event {identity.event_id} · {count} saved scans awaiting reconciliation</p>
      <button className="btn-secondary mt-1 min-h-11" onClick={() => exportJournal(identity)}>Export saved scans for event {identity.event_id}</button>
    </div>)}
    {message && <p role="status" className="text-sm">{message}</p>}
  </div>
}
