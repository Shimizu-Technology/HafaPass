import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import JournalRecovery from './JournalRecovery'

vi.mock('../../api/client', () => ({ default: { post: vi.fn() } }))
const journal = { schema: 'hafapass-admission-journal-v1', event_id: 123, device_id: 456,
  actions: [{ action_uuid: 'preserved-action', kind: 'admit', source: 'offline', sequence: 1 }] }
async function upload(data = journal) {
  const file = new File([JSON.stringify(data)], 'saved-scans.json', { type: 'application/json' })
  file.text = async () => JSON.stringify(data)
  await userEvent.upload(screen.getByLabelText('Saved journal file'), file)
}

describe('manager journal review', () => {
  beforeEach(() => vi.resetAllMocks())
  it('requires explicit review, submits preserved IDs, and reports conflicts without removing the journal', async () => {
    const onRecovered = vi.fn()
    apiClient.post.mockResolvedValue({ data: { results: [{ action_uuid: 'preserved-action', result: 'conflict' }], summary: { conflicts: 1 } } })
    render(<JournalRecovery eventId="123" onRecovered={onRecovered} />)
    await userEvent.click(screen.getByText('Manager: recover an offline journal'))
    expect(screen.getByText(/A client timestamp alone/)).toBeInTheDocument()
    await upload()
    expect(screen.getByRole('button', { name: 'Recover reviewed admissions' })).toBeDisabled()
    await userEvent.type(screen.getByLabelText('Reviewed start (ISO 8601 with timezone)'), '2026-10-26T00:00:00Z')
    await userEvent.type(screen.getByLabelText('Reviewed end, exclusive (ISO 8601 with timezone)'), '2026-10-26T01:00:00Z')
    await userEvent.type(screen.getByLabelText('Gate evidence and reason'), 'Checked paper gate tally with the original operator')
    await userEvent.click(screen.getByRole('checkbox'))
    await userEvent.click(screen.getByRole('button', { name: 'Recover reviewed admissions' }))
    expect(await screen.findByText(/0 accepted, 1 conflicts, 0 rejected/)).toBeInTheDocument()
    expect(apiClient.post).toHaveBeenCalledWith('/organizer/events/123/scanner_devices/456/recover', expect.objectContaining({ actions: journal.actions }), expect.any(Object))
    expect(onRecovered).toHaveBeenCalledWith({ conflicts: 1 })
    expect(screen.getByRole('button', { name: 'Save recovery receipt' })).toBeEnabled()
    expect(screen.getByText(/Original saved scans are retained/)).toBeInTheDocument()
  })
  it('refuses a journal from another event before submitting any recovery', async () => {
    render(<JournalRecovery eventId="789" />)
    await userEvent.click(screen.getByText('Manager: recover an offline journal'))
    await upload()
    expect(await screen.findByText(/Choose a journal for this event/)).toBeInTheDocument()
    expect(apiClient.post).not.toHaveBeenCalled()
  })
})
