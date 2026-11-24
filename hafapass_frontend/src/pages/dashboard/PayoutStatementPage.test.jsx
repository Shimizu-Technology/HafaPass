import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../../api/client'
import { saveBlob } from '../../utils/download'
import { statusSummary } from '../../utils/payoutStatement'
import PayoutStatementPage from './PayoutStatementPage'
import { finalNegative, payoutReceipt, reserveHeld, salesOpen, waitingForPayout } from '../../test/fixtures/payoutStatementFixtures'

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
    expect(screen.getByTestId('balance-remaining')).toHaveTextContent('$0.00')
    expect(screen.getByText('Still to come').closest('div')).toHaveTextContent('$894.51Includes the $894.51 reserve, due Mar 1, 2027')
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

  it('describes sales-open and waiting states', () => {
    expect(statusSummary(salesOpen)).toBe('Sales are still open, so these numbers will change until the event ends.')
    expect(statusSummary(waitingForPayout)).toBe('The event has ended. HåfaPass sends your bank transfer within 2–3 business days, by Feb 3, 2027.')
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
