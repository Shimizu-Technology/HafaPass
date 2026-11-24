import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import AdminPayoutsPage from './AdminPayoutsPage'
import { dueFirst, dueRelease } from '../../test/fixtures/payoutStatementFixtures'

vi.mock('../../api/client', async importOriginal => ({ ...await importOriginal(), default: { get: vi.fn(), patch: vi.fn(), post: vi.fn(), delete: vi.fn() } }))
vi.mock('./AdminLayout', () => ({ default: ({ children }) => <div>{children}</div> }))

const meta = { page: 1, total_pages: 1, total_count: 0 }
function respond(due) {
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path === '/admin/payout_schedule' ? due
    : { payouts: [], meta, status_counts: {}, context: null } }))
}
const renderAt = path => render(<MemoryRouter initialEntries={[path]}><AdminPayoutsPage /></MemoryRouter>)
const firstRow = dueFirst.transfers[0]
const releaseRow = dueRelease.reserves[0]

describe('Admin payouts Due view', () => {
  beforeEach(() => { vi.clearAllMocks(); respond(dueFirst) })

  it('lists events due for their bank transfer with the Guam business-day due date and next step', async () => {
    renderAt('/admin/payouts?view=due')
    const row = await screen.findByTestId(`due-row-${firstRow.event.id}`)
    expect(screen.getByRole('link', { name: 'Due' })).toHaveAttribute('aria-current', 'page')
    expect(row).toHaveTextContent('Ended Jan 30, 2027')
    expect(row).toHaveTextContent('Due by Feb 3, 2027')
    expect(row).toHaveTextContent('Hold the reserve')
    expect(screen.getByText(/bank transfer within 2–3 business days after the event \(Guam time\), 10% reserve released after 30 days/)).toBeInTheDocument()
    expect(within(row).getByRole('button', { name: /Hold \$894\.51 reserve/ })).toBeInTheDocument()
    expect(within(row).getByRole('button', { name: 'Finalize without reserve' })).toBeInTheDocument()
  })

  it('holds the suggested reserve without sending a client-side amount, then reloads', async () => {
    const user = userEvent.setup()
    apiClient.post.mockResolvedValue({ data: { id: 1 } })
    renderAt('/admin/payouts?view=due')
    await user.click(await screen.findByRole('button', { name: /Hold \$894\.51 reserve/ }))
    const dialog = within(screen.getByRole('dialog'))
    expect(dialog.getByText('Release date').closest('div')).toHaveTextContent('Mar 1, 2027')
    await user.click(dialog.getByRole('button', { name: 'Hold reserve' }))
    expect(apiClient.post).toHaveBeenCalledWith(`/admin/payout_schedule/${firstRow.event.id}/reserve`, {}, expect.anything())
    expect(await screen.findByText(/Reserve of \$894\.51 held/)).toBeInTheDocument()
  })

  it('finalizes and then requests the payout with an idempotency key', async () => {
    const user = userEvent.setup()
    const ready = { ...firstRow, next_step: 'send_transfer', next_step_label: 'Request the payout and send the bank transfer', actions: ['send_transfer'],
      settlement: { id: 77, version: 1, available_to_payout_cents: 805057 } }
    respond({ ...dueFirst, transfers: [ready] })
    apiClient.post.mockResolvedValue({ data: { id: 5 } })
    renderAt('/admin/payouts?view=due')
    await user.click(await screen.findByRole('button', { name: 'Request payout $8,050.57' }))
    expect(apiClient.post).toHaveBeenCalledWith('/admin/payouts', { settlement_id: 77 },
      expect.objectContaining({ headers: { 'Idempotency-Key': expect.any(String) } }))
    expect(await screen.findByText(/Send the bank transfer, then choose Record transfer/)).toBeInTheDocument()
  })

  it('shows a reserve due for release with the chargeback that reduces it', async () => {
    const user = userEvent.setup()
    respond(dueRelease)
    apiClient.post.mockResolvedValue({ data: {} })
    renderAt('/admin/payouts?view=due')
    const row = await screen.findByTestId(`due-row-${releaseRow.event.id}`)
    expect(row).toHaveTextContent('Due by Mar 1, 2027')
    expect(row).toHaveTextContent('Reserve $894.51')
    expect(row).toHaveTextContent('To send after release $842.51')
    expect(row).not.toHaveTextContent('Owes')
    expect(screen.getByText(/1 overdue/)).toBeInTheDocument()
    await user.click(within(row).getByRole('button', { name: 'Release reserve' }))
    const dialog = within(screen.getByRole('dialog'))
    expect(dialog.getByText('Chargebacks and changes since the payout').closest('div')).toHaveTextContent('-$52.00')
    expect(dialog.getByText('Left to send after release').closest('div')).toHaveTextContent('$842.51')
    await user.click(dialog.getByRole('button', { name: 'Release reserve' }))
    expect(apiClient.post).toHaveBeenCalledWith(`/admin/payout_schedule/${releaseRow.event.id}/release`, {}, expect.anything())
  })

  it('requires a reason before releasing a reserve early', async () => {
    const user = userEvent.setup()
    respond({ ...dueRelease, reserves: [{ ...releaseRow, due_state: 'upcoming', next_step: 'wait_for_reserve' }] })
    renderAt('/admin/payouts?view=due')
    await user.click(await screen.findByRole('button', { name: 'Release early' }))
    const dialog = within(screen.getByRole('dialog'))
    await user.click(dialog.getByRole('button', { name: 'Release reserve' }))
    expect(dialog.getByRole('alert')).toHaveTextContent('at least 10 characters')
    expect(apiClient.post).not.toHaveBeenCalled()
  })

  it('filters to items due now', async () => {
    const user = userEvent.setup()
    renderAt('/admin/payouts?view=due')
    await user.click(await screen.findByRole('checkbox', { name: 'Due now only' }))
    await waitFor(() => expect(apiClient.get).toHaveBeenCalledWith('/admin/payout_schedule', expect.objectContaining({ params: { filter: 'due_now' } })))
  })
})
