import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import AdminPayoutsPage from './AdminPayoutsPage'
import { dueFirst, dueRelease } from '../../demo/fixtures/payoutStatements'

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
    apiClient.post.mockResolvedValue({ data: { id: 5, status: 'processing', amount_cents: 805057, withheld_cents: 0, disbursement_cents: 805057 } })
    renderAt('/admin/payouts?view=due')
    await user.click(await screen.findByRole('button', { name: 'Request payout $8,050.57' }))
    expect(apiClient.post).toHaveBeenCalledWith('/admin/payouts', { settlement_id: 77 },
      expect.objectContaining({ headers: { 'Idempotency-Key': expect.any(String) } }))
    expect(await screen.findByText(/Send \$8,050\.57 to .* Then choose Record transfer/)).toBeInTheDocument()
  })

  it('shows a reserve due for release with the chargeback that reduces it', async () => {
    const user = userEvent.setup()
    respond(dueRelease)
    apiClient.post.mockResolvedValue({ data: {} })
    renderAt('/admin/payouts?view=due')
    const row = await screen.findByTestId(`due-row-${releaseRow.event.id}`)
    expect(row).toHaveTextContent('Due by Mar 1, 2027')
    expect(row).toHaveTextContent('Reserve $894.51')
    expect(row).toHaveTextContent('To send after release $825.51')
    expect(row).not.toHaveTextContent('Owes')
    expect(screen.getByText(/1 overdue/)).toBeInTheDocument()
    await user.click(within(row).getByRole('button', { name: 'Release reserve' }))
    const dialog = within(screen.getByRole('dialog'))
    expect(dialog.getByText('Chargebacks and changes since the payout').closest('div')).toHaveTextContent('-$69.00')
    expect(dialog.getByText('Left to send after release').closest('div')).toHaveTextContent('$825.51')
    await user.click(dialog.getByRole('button', { name: 'Release reserve' }))
    expect(apiClient.post).toHaveBeenCalledWith(`/admin/payout_schedule/${releaseRow.event.id}/release`, {}, expect.anything())
  })

  it('requires a reason before releasing a reserve early', async () => {
    const user = userEvent.setup()
    respond({ ...dueRelease, reserves: [{ ...releaseRow, due_state: 'upcoming', next_step: 'wait_for_reserve', reserve_release_due: false }] })
    renderAt('/admin/payouts?view=due')
    await user.click(await screen.findByRole('button', { name: 'Release early' }))
    const dialog = within(screen.getByRole('dialog'))
    await user.click(dialog.getByRole('button', { name: 'Release reserve' }))
    expect(dialog.getByRole('alert')).toHaveTextContent('at least 10 characters')
    expect(apiClient.post).not.toHaveBeenCalled()
  })

  // Review finding 1: the bank instruction comes from the payout the API created.
  it.each([
    [{ id: 51, status: 'processing', amount_cents: 80000, withheld_cents: 19200, disbursement_cents: 60800, currency: 'usd' },
      'Send $608.00 to Fictional Grappling League’s approved bank account for Island Open Exhibition ($800.00 gross, $192.00 withheld for taxes). Then choose Record transfer with the bank reference.'],
    [{ id: 52, status: 'processing', amount_cents: 80000, withheld_cents: 0, disbursement_cents: 80000, currency: 'usd' },
      'Send $800.00 to Fictional Grappling League’s approved bank account for Island Open Exhibition. Then choose Record transfer with the bank reference.'],
    [{ id: 53, status: 'processing', amount_cents: 5000, withheld_cents: 5000, disbursement_cents: 0, currency: 'usd' },
      'Payout #53 ($50.00) is withholding only: $50.00 withheld for taxes and nothing goes to the bank. Record it in Payouts with the withholding-only reference.'],
  ])('tells finance to send what the payout response says, not the statement amount (%#)', async (payout, notice) => {
    const user = userEvent.setup()
    const ready = { ...firstRow, next_step: 'send_transfer', actions: ['send_transfer'],
      settlement: { id: 77, version: 1, available_to_payout_cents: 805057, requestable_cents: 80000 } }
    respond({ ...dueFirst, transfers: [ready] })
    apiClient.post.mockResolvedValue({ data: payout })
    renderAt('/admin/payouts?view=due')
    await user.click(await screen.findByRole('button', { name: 'Request payout $800.00' }))
    expect(await screen.findByText(notice.replace('’', "'"))).toBeInTheDocument()
    expect(screen.queryByText(/\$8,050\.57/)).not.toBeInTheDocument()
  })

  it('does not offer a $0 payout when the organization balance is used up', async () => {
    const ready = { ...firstRow, next_step: 'send_transfer', actions: ['send_transfer'],
      settlement: { id: 77, version: 1, available_to_payout_cents: 805057, requestable_cents: 0 } }
    respond({ ...dueFirst, transfers: [ready] })
    renderAt('/admin/payouts?view=due')
    expect(await screen.findByRole('button', { name: 'Request payout $0.00' })).toBeDisabled()
    expect(screen.getByText(/Nothing can be paid right now: this organization's payout balance is \$0/)).toBeInTheDocument()
  })

  it('finalizes without a reserve only with a reason, sent as an explicit skip', async () => {
    const user = userEvent.setup()
    apiClient.post.mockResolvedValue({ data: { id: 9, version: 2, reserve_skipped: true } })
    renderAt('/admin/payouts?view=due')
    await user.click(await screen.findByRole('button', { name: 'Finalize without reserve' }))
    const dialog = within(screen.getByRole('dialog'))
    await user.click(dialog.getByRole('button', { name: 'Finalize without reserve' }))
    expect(dialog.getByRole('alert')).toHaveTextContent('at least 10 characters')
    expect(apiClient.post).not.toHaveBeenCalled()
    await user.type(dialog.getByLabelText('Why no reserve'), 'Trusted organizer, approved by Leon')
    await user.click(dialog.getByRole('button', { name: 'Finalize without reserve' }))
    expect(apiClient.post).toHaveBeenCalledWith(`/admin/payout_schedule/${firstRow.event.id}/finalize`,
      { skip_reserve: true, skip_reason: 'Trusted organizer, approved by Leon' }, expect.anything())
    expect(await screen.findByText(/finalized for Island Open Exhibition without a reserve/)).toBeInTheDocument()
  })

  it('asks for an early-release reason from the reserve date, even when the row itself is due', async () => {
    const user = userEvent.setup()
    respond({ ...dueRelease, reserves: [{ ...releaseRow, due_state: 'due', reserve_release_due: false }] })
    renderAt('/admin/payouts?view=due')
    await user.click(await screen.findByRole('button', { name: 'Release early' }))
    expect(within(screen.getByRole('dialog')).getByRole('heading')).toHaveTextContent('Release the reserve early?')
  })

  it('filters to items due now', async () => {
    const user = userEvent.setup()
    renderAt('/admin/payouts?view=due')
    await user.click(await screen.findByRole('checkbox', { name: 'Due now only' }))
    await waitFor(() => expect(apiClient.get).toHaveBeenCalledWith('/admin/payout_schedule', expect.objectContaining({ params: { filter: 'due_now' } })))
  })
})
