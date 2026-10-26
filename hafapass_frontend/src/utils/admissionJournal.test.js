import { describe, expect, it } from 'vitest'
import { journalExport, parseJournal } from './admissionJournal'

describe('retained admission journal interchange', () => {
  it('exports minimal actions without attendee data or browser auth, preserving retry identity', () => {
    const actions = [{ action_uuid: 'scan-a', sequence: 8, kind: 'admit', source: 'offline', ticket_id: 12,
      manifest_version: 2, credential_hash: 'a'.repeat(64), occurred_at: '2026-10-26T00:00:00Z',
      attendee_name: 'Private attendee', owner_user_id: 'private-owner', token: 'private-token' }]
    const data = journalExport(123, { device_id: 456, identifier: 'private-browser' }, actions)
    expect(parseJournal(JSON.stringify(data), '123')).toMatchObject({ device_id: 456, actions: [{ action_uuid: 'scan-a', sequence: 8 }] })
    expect(JSON.stringify(data)).not.toMatch(/private|Private/)
    expect(actions).toHaveLength(1)
  })
  it('refuses empty, excessive or cross-event imports while preserving the original data', () => {
    expect(() => journalExport(1, { device_id: 2 }, [])).toThrow(/No saved scans/)
    const data = { schema: 'hafapass-admission-journal-v1', event_id: 1, device_id: 2, actions: [{}] }
    expect(() => parseJournal(JSON.stringify(data), 3)).toThrow(/this event/)
    expect(() => parseJournal(JSON.stringify({ ...data, actions: Array(501).fill({}) }), 1)).toThrow(/1–500/)
  })
})
