import 'fake-indexeddb/auto'
import { act, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { clearAllAdmissionData, clearEventAdmissionData, pendingDeviceIdentities, queueAdmission, queuedActions, saveDevice, saveVerifiedManifest } from '../../utils/admissionStore'
import { signedManifest } from '../../test/manifestFixture'
import * as interchange from '../../utils/admissionJournal'
import SavedJournalExports from './SavedJournalExports'

describe('journal export after event access is lost', () => {
  beforeEach(async () => { localStorage.clear(); localStorage.setItem('hafapass_scanner_user_id', 'original-staff'); await clearEventAdmissionData(98201) })
  afterEach(async () => { vi.restoreAllMocks(); localStorage.setItem('hafapass_scanner_user_id', 'original-staff'); await clearEventAdmissionData(98201); localStorage.clear() })
  it('exports the retained journal even with no selected event, manifest, or authorized device', async () => {
    await saveDevice(98201, { id: 88201, identifier: 'lost-access', effective: true, authorization_expires_at: new Date(Date.now() + 60_000).toISOString() })
    const ticket = { ticket_id: 1, state: 'valid', credential_hash: 'a'.repeat(64) }
    await saveVerifiedManifest(await signedManifest(98201, [ticket]))
    await queueAdmission({ eventId: 98201, deviceId: 88201, manifestVersion: 1, ticket, credentialHash: ticket.credential_hash, source: 'offline' })
    await clearAllAdmissionData()
    const download = vi.spyOn(interchange, 'downloadJournalFile').mockImplementation(() => {})
    render(<SavedJournalExports owner="original-staff" eventId="" pendingCount={0} recovery />)
    await userEvent.click(await screen.findByRole('button', { name: 'Export saved scans for event 98201' }))
    expect(screen.getByText(/Saved scans still need reconciliation/)).toBeVisible()
    expect(download).toHaveBeenCalledWith(expect.objectContaining({ event_id: 98201, device_id: 88201,
      actions: [expect.objectContaining({ sequence: 1 })] }), expect.any(String))
    expect(await queuedActions(98201, 88201)).toHaveLength(1)
  })
  it('does not enumerate a previous account journal', async () => {
    await saveDevice(98201, { id: 88201, identifier: 'private-old-owner', effective: true, authorization_expires_at: new Date(Date.now() + 60_000).toISOString() })
    const ticket = { ticket_id: 1, state: 'valid', credential_hash: 'a'.repeat(64) }
    await saveVerifiedManifest(await signedManifest(98201, [ticket]))
    await queueAdmission({ eventId: 98201, deviceId: 88201, manifestVersion: 1, ticket, credentialHash: ticket.credential_hash, source: 'offline' })
    await clearAllAdmissionData()
    localStorage.setItem('hafapass_scanner_user_id', 'different-staff')
    render(<SavedJournalExports owner="different-staff" eventId="" pendingCount={0} recovery />)
    await act(async () => expect(await pendingDeviceIdentities()).toEqual([]))
    expect(screen.queryByRole('button', { name: 'Export saved scans for event 98201' })).not.toBeInTheDocument()
    expect(screen.queryByText(/Saved scans still need reconciliation/)).not.toBeInTheDocument()
    localStorage.setItem('hafapass_scanner_user_id', 'original-staff')
    expect(await queuedActions(98201, 88201)).toHaveLength(1)
  })
})
