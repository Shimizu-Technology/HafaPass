import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../../api/client'
import { saveBlob } from '../../utils/download'
import { inProgressDetail, statusSummary } from '../../utils/payoutStatement'
import PayoutStatementPage from './PayoutStatementPage'
import { coveredRefund, finalNegative, payoutReceipt, reserveHeld, salesOpen, waitingForPayout } from '../../demo/fixtures/payoutStatements'

vi.mock('../../api/client', async original => ({ ...(await original()), default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('../../utils/download', () => ({ saveBlob: vi.fn() }))

let clearAuth
function mount(path = '/dashboard/events/12/statement') {
  return render(<MemoryRouter initialEntries={[path]}><Routes><Route path="/dashboard/events/:id/statement" element={<PayoutStatementPage />} /></Routes></MemoryRouter>)
}
const respondWith = data => apiClient.get.mockImplementation(url => Promise.resolve({ data: url.includes('payout_statement_export') ? new Blob(['csv']) : data }))

beforeEach(() => {
  vi.clearAllMocks(); apiClient.get.mockReset(); window.localStorage.clear()
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '')
  window.localStorage.setItem('hafapass_scanner_user_id', 'actor-a'); window.localStorage.setItem('hafapass_organization_id', '1')
  clearAuth = setAuthTokenGetter(() => Promise.resolve('synthetic-token'), { userId: 'actor-a', sessionId: 'session-a', ready: true })
})
afterEach(() => { clearAuth?.(); vi.unstubAllEnvs(); vi.restoreAllMocks() })

describe('PayoutStatementPage', () => {
  it('explains a paid event with its reserve, every line and the bank transfer', async () => {
    respondWith(reserveHeld)
    mount()
    expect(await screen.findByTestId('statement-status')).toHaveTextContent('Paid — reserve held until Mar 1, 2027')
    expect(screen.getByText(/We sent \$8,050\.57 to your bank account\. \$894\.51 is held until Mar 1, 2027/)).toBeInTheDocument()
    expect(apiClient.get).toHaveBeenCalledWith('/organizer/events/12/finance/payout_statement', expect.anything())
    const lines = screen.getByRole('region', { name: 'How your payout adds up' })
    expect(within(lines).getByText('Door cash you collected').closest('div')).toHaveTextContent('−$51.00')
    expect(within(lines).getByText('You already have this cash, so it is not part of the bank transfer.')).toBeInTheDocument()
    expect(within(lines).getByText('Reserve held').closest('div')).toHaveTextContent('−$894.51')
    expect(within(lines).getByText('Bank transfer to account ending 4321').closest('div')).toHaveTextContent('Ref TRF-20270201-07')
    expect(screen.getByText('Balance after transfers, not counting the reserve').closest('div')).toHaveTextContent('$0.00')
    expect(screen.getByTestId('balance-remaining')).toHaveTextContent('Still to come$894.51')
    expect(screen.getAllByText('Still to come')[0].closest('div')).toHaveTextContent('$894.51Includes the $894.51 reserve, due Mar 1, 2027')
    const sales = screen.getByRole('region', { name: 'Sales by ticket' })
    expect(within(sales).getByText('Adult spectator').closest('tr')).toHaveTextContent('415$7,055.00')
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('prints and downloads the CSV for the same statement', async () => {
    respondWith(reserveHeld)
    const print = vi.spyOn(window, 'print').mockImplementation(() => {})
    mount()
    await screen.findByTestId('statement-status')
    await userEvent.click(screen.getByRole('button', { name: 'Print' }))
    expect(print).toHaveBeenCalled()
    await userEvent.click(screen.getByRole('button', { name: 'Download CSV' }))
    expect(apiClient.get).toHaveBeenCalledWith('/organizer/events/12/finance/payout_statement_export', expect.objectContaining({ responseType: 'blob' }))
    expect(saveBlob).toHaveBeenCalledWith(expect.any(Blob), 'island-open-exhibition-payout-statement.csv')
  })

  it('shows one transfer with the version it was paid from', async () => {
    respondWith(payoutReceipt)
    mount(`/dashboard/events/12/statement?payout=${payoutReceipt.payout.id}`)
    const receipt = await screen.findByTestId('payout-receipt')
    expect(apiClient.get).toHaveBeenCalledWith(`/organizer/events/12/finance/payout_statement?payout_id=${payoutReceipt.payout.id}`, expect.anything())
    expect(receipt).toHaveTextContent('$8,050.57')
    expect(receipt).toHaveTextContent('To account ending4321')
    expect(receipt).toHaveTextContent('Paid from statement version 1')
  })

  it('says plainly when the organizer owes money after chargebacks', async () => {
    respondWith(finalNegative)
    mount()
    expect(await screen.findByTestId('statement-status')).toHaveTextContent('Final')
    expect(screen.getByText('This event is closed. You owe $62.16, which comes out of your next payout.')).toBeInTheDocument()
    expect(screen.getByTestId('balance-remaining')).toHaveTextContent('You owe−$62.16')
    expect(screen.getByText('Chargebacks').closest('div')).toHaveTextContent('−$72.00')
  })

  // Review finding 5: a refund after the payout that the reserve covers is not a debt.
  it('does not say the organizer owes money the held reserve covers', async () => {
    respondWith(coveredRefund)
    mount()
    await screen.findByTestId('statement-status')
    expect(screen.queryByText(/you owe/i)).not.toBeInTheDocument()
    expect(screen.getByText('Reserve still held').closest('div')).toHaveTextContent('$894.51')
    expect(screen.getByText('Balance after transfers, not counting the reserve').closest('div')).toHaveTextContent('−$17.00')
    expect(screen.getByTestId('balance-remaining')).toHaveTextContent('Still to come$877.51')
    expect(screen.getByText(/Later refunds or chargebacks come out of it, so \$877\.51 will be sent to you/)).toBeInTheDocument()
    // Round 2: the headline card must not claim the $877.51 "includes" the whole $894.51 reserve.
    expect(screen.queryByText(/Includes the \$894\.51 reserve/)).not.toBeInTheDocument()
    expect(screen.getByText('What is left of the $894.51 reserve after later refunds or chargebacks ($17.00), due Mar 1, 2027')).toBeInTheDocument()
  })

  it('names a wording contradiction without claiming the statement is off by $0.00', async () => {
    respondWith({ ...reserveHeld, reconciles: false, difference_cents: 0, contradictions: ['owe_note_mismatch'] })
    mount()
    const alert = await screen.findByRole('alert')
    expect(alert).toHaveTextContent('Some wording on this statement does not match its numbers. Please contact HåfaPass before relying on it.')
    expect(alert).not.toHaveTextContent('$0.00')
  })

  it('describes sales-open and waiting states', () => {
    expect(statusSummary(salesOpen)).toBe('Sales are still open, so these numbers will change until the event ends.')
    expect(statusSummary(waitingForPayout)).toBe('The event has ended. HåfaPass sends your bank transfer within 2–3 business days, by Feb 3, 2027.')
  })

  it('says a transfer is on its way only once it has actually been sent', () => {
    const transfer = { id: 1, status: 'processing', status_label: 'Approved, not sent yet', dispatched: false, amount_cents: 2000 }
    const waiting = { ...waitingForPayout, totals: { ...waitingForPayout.totals, in_progress_cents: 2000 }, transfers: [transfer] }
    expect(statusSummary(waiting)).toBe('HåfaPass is preparing a transfer of $20.00 to your bank account. It has not been sent yet.')
    expect(inProgressDetail(waiting)).toBe('$20.00 being prepared, not sent yet')
    const held = { ...waiting, transfers: [{ ...transfer, status: 'held', status_label: 'On hold' }] }
    expect(statusSummary(held)).toBe('A transfer of $20.00 is on hold. HåfaPass has not sent it.')
    const sent = { ...waiting, transfers: [{ ...transfer, status_label: 'Being sent', dispatched: true }] }
    expect(statusSummary(sent)).toBe('A transfer of $20.00 is on its way to your bank account.')
    expect(inProgressDetail(sent)).toBe('$20.00 on the way')
    expect(inProgressDetail(waitingForPayout)).toBeNull()
  })

  it('tells door staff that finances are not part of their role', async () => {
    apiClient.get.mockRejectedValue({ response: { status: 403 } })
    mount()
    expect(await screen.findByText('Finances aren’t part of your role')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Download CSV' })).not.toBeInTheDocument()
  })

  it('warns instead of hiding a statement that does not add up', async () => {
    respondWith({ ...reserveHeld, reconciles: false, difference_cents: 1 })
    mount()
    expect(await screen.findByRole('alert')).toHaveTextContent('off by $0.01')
  })
})
