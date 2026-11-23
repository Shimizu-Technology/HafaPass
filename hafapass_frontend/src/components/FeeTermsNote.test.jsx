import { MemoryRouter } from 'react-router-dom'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import FeeTermsNote from './FeeTermsNote'

describe('FeeTermsNote', () => {
  it('offers a retry instead of guessing when fee terms fail to load', async () => {
    const retry = vi.fn()
    render(<FeeTermsNote feeTerms={{ status: 'error', terms: null, retry }} feePolicy="buyer_pays" />)
    expect(screen.getByRole('status')).toHaveTextContent('Current fee terms could not be loaded.')
    await userEvent.click(screen.getByRole('button', { name: 'Retry fee terms' }))
    expect(retry).toHaveBeenCalledTimes(1)
  })

  it.each([
    [null, /Payouts are made by check on the schedule in your Organizer Agreement/],
    ['bank_transfer_with_reserve', /Standard payout target: bank transfer within 7 days\. .*eligible proceeds.*reserve 30 days after your event/],
  ])('reflects the effective payout terms (%s)', (organizerPayoutTerms, copy) => {
    render(<MemoryRouter><FeeTermsNote feeTerms={{ status: 'ready', retry: () => {}, terms: { percent: 5, flatCents: 100, bearer: 'organizer', payoutScheduleText: 'within 7 days.', organizerPayoutTerms } }} feePolicy="buyer_pays" /></MemoryRouter>)
    expect(screen.getByText(/Card processing costs are deducted from your proceeds\./)).toBeInTheDocument()
    expect(screen.getByText(copy)).toBeInTheDocument()
    if (!organizerPayoutTerms) expect(screen.queryByText(/bank transfer|reserve/i)).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: /current Organizer Agreement/ })).toHaveAttribute('href', '/policies/organizer-agreement')
  })
})
