import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import PaymentReadinessReviewDialog from './PaymentReadinessReviewDialog'

vi.mock('../api/client', () => ({
  default: { post: vi.fn(), patch: vi.fn() },
}))

const controls = {
  guam_territory_confirmed: true,
  platform_entity_model_confirmed: true,
  organizer_onboarding_confirmed: true,
  charges_confirmed: true,
  payouts_confirmed: true,
  refunds_disputes_confirmed: true,
  bank_account_confirmed: true,
  fee_tax_schedule_approved: true,
  liability_schedule_approved: true,
}

describe('PaymentReadinessReviewDialog', () => {
  beforeEach(() => {
    apiClient.post.mockReset().mockResolvedValue({ data: {} })
    apiClient.patch.mockReset().mockResolvedValue({ data: {} })
  })

  it('requires every Gate B control before submitting digest-bound evidence', async () => {
    const onComplete = vi.fn()
    const user = userEvent.setup()
    render(<PaymentReadinessReviewDialog account={{
      id: 42,
      provider: 'paypal',
      requirements_due: ['independent_readiness_approval'],
    }} onComplete={onComplete} />)

    await user.click(screen.getByRole('button', { name: 'Submit Gate B evidence' }))
    const submit = screen.getByRole('button', { name: 'Submit evidence' })
    expect(submit).toBeDisabled()

    await user.type(screen.getByLabelText('Restricted evidence reference'), 'restricted/gate-b/paypal-42')
    await user.type(screen.getByLabelText('Provider or bank approval reference'), 'paypal-live-approval-42')
    await user.type(screen.getByLabelText('Approved fee and tax schedule'), 'finance/2026-07')
    await user.type(screen.getByLabelText('Approved liability schedule'), 'legal/2026-07')
    await user.type(screen.getByLabelText(/^Evidence SHA-256/), 'a'.repeat(64))
    for (const checkbox of screen.getAllByRole('checkbox')) await user.click(checkbox)

    expect(submit).toBeEnabled()
    await user.click(submit)

    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith(
      '/admin/connected_accounts/42/payment_readiness_reviews',
      expect.objectContaining({ evidence_digest: 'a'.repeat(64), controls }),
    ))
    expect(onComplete).toHaveBeenCalled()
  })

  it('shows the exact pending evidence and sends it for independent approval', async () => {
    const onComplete = vi.fn()
    const user = userEvent.setup()
    render(<PaymentReadinessReviewDialog account={{
      id: 42,
      provider: 'paypal',
      readiness_submission: {
        id: 91,
        actor_user_id: 7,
        evidence_reference: 'restricted/gate-b/paypal-42',
        evidence_digest: 'b'.repeat(64),
        provider_approval_reference: 'paypal-live-approval-42',
        merchant_of_record: 'organizer',
        fee_tax_schedule_reference: 'finance/2026-07',
        liability_schedule_reference: 'legal/2026-07',
        controls,
        effective_at: '2026-07-21T00:00:00Z',
        expires_at: '2027-01-21T00:00:00Z',
      },
    }} onComplete={onComplete} />)

    await user.click(screen.getByRole('button', { name: 'Review pending evidence' }))
    expect(screen.getByText(/Admin #7 submitted this snapshot/)).toBeInTheDocument()
    expect(screen.getByText('paypal-live-approval-42')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Approve exact evidence' }))

    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/payment_readiness_reviews/91/approve'))
    expect(onComplete).toHaveBeenCalled()
  })

  it('requires a reason before rejecting an incorrect snapshot', async () => {
    const onComplete = vi.fn()
    const user = userEvent.setup()
    const account = {
      id: 42,
      provider: 'paypal',
      readiness_submission: {
        id: 91,
        actor_user_id: 7,
        evidence_reference: 'restricted/gate-b/paypal-42',
        evidence_digest: 'b'.repeat(64),
        provider_approval_reference: 'paypal-live-approval-42',
        merchant_of_record: 'organizer',
        fee_tax_schedule_reference: 'finance/2026-07',
        liability_schedule_reference: 'legal/2026-07',
        controls,
        effective_at: '2026-07-21T00:00:00Z',
        expires_at: '2027-01-21T00:00:00Z',
      },
    }
    render(<PaymentReadinessReviewDialog account={account} onComplete={onComplete} />)

    await user.click(screen.getByRole('button', { name: 'Review pending evidence' }))
    const reject = screen.getByRole('button', { name: 'Reject evidence' })
    expect(reject).toBeDisabled()
    fireEvent.change(screen.getByLabelText('Rejection or correction reason'), {
      target: { value: 'Payout authority is missing' },
    })
    await user.click(screen.getByRole('button', { name: 'Reject evidence' }))

    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith(
      '/admin/payment_readiness_reviews/91/reject',
      { reason: 'Payout authority is missing' },
    ))
    expect(onComplete).toHaveBeenCalled()
  })

  it('offers a new immutable snapshot when the last approval is no longer active', async () => {
    const approval = {
      id: 92,
      actor_user_id: 8,
      evidence_reference: 'restricted/gate-b/expired',
      evidence_digest: 'c'.repeat(64),
      provider_approval_reference: 'paypal-expired',
      merchant_of_record: 'organizer',
      fee_tax_schedule_reference: 'finance/old',
      liability_schedule_reference: 'legal/old',
      controls,
      effective_at: '2026-01-01T00:00:00Z',
      expires_at: '2026-07-01T00:00:00Z',
    }
    const user = userEvent.setup()
    render(<PaymentReadinessReviewDialog account={{
      id: 42,
      provider: 'paypal',
      readiness_approval: approval,
      readiness_approval_active: false,
      payout_ready: false,
    }} onComplete={vi.fn()} />)

    await user.click(screen.getByRole('button', { name: 'Replace expired evidence' }))
    expect(screen.getByText(/previous approval is expired or revoked/i)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Submit evidence' })).toBeDisabled()
  })
})
