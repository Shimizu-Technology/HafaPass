import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import PaymentForm from './PaymentForm'

const confirmPayment = vi.fn()

vi.mock('@stripe/react-stripe-js', () => ({
  PaymentElement: () => <div>Payment fields</div>,
  useElements: () => ({ ready: true }),
  useStripe: () => ({ confirmPayment }),
}))

describe('PaymentForm', () => {
  beforeEach(() => {
    confirmPayment.mockReset()
  })

  it('hands a processing payment to the authoritative confirmation flow', async () => {
    const onSuccess = vi.fn()
    const setSubmitting = vi.fn()
    const paymentIntent = { id: 'pi_processing', status: 'processing' }
    confirmPayment.mockResolvedValue({ paymentIntent })

    render(
      <PaymentForm
        totalCents={2500}
        returnUrl="https://example.test/orders/1/confirmation"
        onSuccess={onSuccess}
        submitting={false}
        setSubmitting={setSubmitting}
      />,
    )

    await userEvent.click(screen.getByRole('button', { name: /pay \$25\.00/i }))

    expect(confirmPayment).toHaveBeenCalledWith(expect.objectContaining({
      confirmParams: { return_url: 'https://example.test/orders/1/confirmation' },
      redirect: 'if_required',
    }))
    expect(onSuccess).toHaveBeenCalledWith(paymentIntent)
  })
})
