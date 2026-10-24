import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { MemoryRouter } from 'react-router-dom'
import BankPayoutDetails from './BankPayoutDetails'
import PayoutMethodSection from './PayoutMethodSection'

vi.mock('../../hooks/usePlatformFeeTerms', () => ({ default: () => ({ terms: {} }) }))
const account = { id: 4, provider: 'manual', payout_details: { bank_name: 'Island Bank', account_holder_name: 'Island Events LLC', masked_account: '••••1234', account_number: 'NEVER_RENDER_FULL_BANK' }, payout_review: { manual: true, status: 'changes_requested', missing: ['Confirm the account holder.'], note: 'Please use your legal business name.' } }

describe('organizer bank payout details', () => {
  it('validates new details, preserves a rejected draft and clears the secret after saving', async () => {
    const save = vi.fn().mockResolvedValueOnce(false).mockResolvedValueOnce(true)
    const user = userEvent.setup(); render(<BankPayoutDetails onSave={save} />)
    await user.click(screen.getByRole('button', { name: 'Save bank details' }))
    expect(save).not.toHaveBeenCalled()
    expect(screen.getByText('Enter the bank account number.')).toBeVisible()
    await user.type(screen.getByLabelText('Bank name'), 'Island Bank')
    await user.type(screen.getByLabelText('Account holder name'), 'Island Events LLC')
    await user.type(screen.getByLabelText('Account number'), '123456789')
    expect(screen.getByLabelText('Account number')).toHaveAttribute('type', 'password')
    await user.click(screen.getByRole('button', { name: 'Save bank details' }))
    expect(screen.getByLabelText('Account number')).toHaveValue('123456789')
    await user.click(screen.getByRole('button', { name: 'Save bank details' }))
    expect(save).toHaveBeenLastCalledWith({ provider: 'manual', accountId: undefined, payout_details: { bank_name: 'Island Bank', account_holder_name: 'Island Events LLC', account_number: '123456789' } })
    expect(screen.queryByLabelText('Account number')).not.toBeInTheDocument()
    expect(document.body).not.toHaveTextContent('123456789')
  })
  it('uses only masked saved values and omits the number to retain it on update', async () => {
    const save = vi.fn().mockResolvedValue(true); const user = userEvent.setup()
    render(<BankPayoutDetails account={account} onSave={save} />)
    expect(screen.getByText('••••1234')).toBeVisible()
    expect(document.body).not.toHaveTextContent('NEVER_RENDER_FULL_BANK')
    await user.click(screen.getByRole('button', { name: 'Change bank details' }))
    expect(screen.getByLabelText(/Account number/)).toHaveValue('')
    await user.clear(screen.getByLabelText('Bank name')); await user.type(screen.getByLabelText('Bank name'), 'New Bank')
    await user.click(screen.getByRole('button', { name: 'Save bank details' }))
    expect(save).toHaveBeenCalledWith({ provider: 'manual', accountId: 4, payout_details: { bank_name: 'New Bank', account_holder_name: 'Island Events LLC' } })
  })
  it('shows the organizer the review status, missing items and note without internal codes', () => {
    render(<MemoryRouter><PayoutMethodSection accounts={[account]} onSave={vi.fn()} /></MemoryRouter>)
    const section = within(screen.getByRole('region', { name: 'How you get paid' }))
    expect(section.getByText('Changes requested')).toBeVisible()
    expect(section.getByText('Confirm the account holder.')).toBeVisible()
    expect(section.getByText('Review note: Please use your legal business name.')).toBeVisible()
    expect(document.body).not.toHaveTextContent('Gate B')
  })
})
