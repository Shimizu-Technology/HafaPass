import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import FeeTermsNote from './FeeTermsNote'

describe('FeeTermsNote', () => {
  it('offers a retry instead of guessing when fee terms fail to load', async () => {
    const retry = vi.fn()
    render(<FeeTermsNote feeTerms={{ status: 'error', terms: null, retry }} feePolicy="buyer_pays" />)
    expect(screen.getByRole('alert')).toHaveTextContent('Current fee terms could not be loaded.')
    await userEvent.click(screen.getByRole('button', { name: 'Retry fee terms' }))
    expect(retry).toHaveBeenCalledTimes(1)
  })

  it('shows the organizer bearer copy and trims a trailing period from payout timing', () => {
    render(<FeeTermsNote feeTerms={{ status: 'ready', retry: () => {}, terms: { percent: 5, flatCents: 100, bearer: 'organizer', payoutScheduleText: 'within 7 days.' } }} feePolicy="buyer_pays" />)
    expect(screen.getByText(/Card processing costs are deducted from your proceeds\./)).toBeInTheDocument()
    expect(screen.getByText('Payout timing: within 7 days.')).toBeInTheDocument()
  })
})
