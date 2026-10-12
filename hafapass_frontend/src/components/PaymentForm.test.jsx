import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import PaymentForm from './PaymentForm'

const confirmPayment = vi.fn()
const paymentElementOptions = vi.hoisted(() => vi.fn())

vi.mock('@stripe/react-stripe-js', () => ({
  PaymentElement: ({ options }) => { paymentElementOptions(options); return <div>Payment fields</div> },
  useElements: () => ({ ready: true }),
  useStripe: () => ({ confirmPayment }),
}))

describe('PaymentForm', () => {
  beforeEach(() => {
    confirmPayment.mockReset()
    paymentElementOptions.mockClear()
  })

  it('keeps Link disabled at the Stripe boundary before payment and after a declined attempt', async () => {
    confirmPayment.mockResolvedValue({ error: { type: 'card_error', message: 'Your card was declined.' } })
    render(<PaymentForm totalCents={1250} returnUrl="https://example.test/confirmation"
      onSuccess={vi.fn()} submitting={false} setSubmitting={vi.fn()} />)
    const walletPolicy = { applePay: 'auto', googlePay: 'auto', link: 'never' }
    expect(paymentElementOptions).toHaveBeenLastCalledWith(expect.objectContaining({ wallets: walletPolicy }))
    await userEvent.click(screen.getByRole('button', { name: 'Pay $12.50' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Your card was declined.')
    expect(paymentElementOptions).toHaveBeenLastCalledWith(expect.objectContaining({ wallets: walletPolicy }))
    expect(screen.getByRole('button', { name: 'Pay $12.50' })).toBeEnabled()
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

  it('announces a declined payment and retains the payment action for recovery', async () => {
    const onSuccess = vi.fn()
    const onError = vi.fn()
    const setSubmitting = vi.fn()
    const error = { type: 'card_error', message: 'Your card was declined.' }
    confirmPayment.mockResolvedValue({ error })
    render(<PaymentForm totalCents={1250} returnUrl="https://example.test/confirmation"
      onSuccess={onSuccess} onError={onError} submitting={false} setSubmitting={setSubmitting} />)
    await userEvent.click(screen.getByRole('button', { name: 'Pay $12.50' }))
    expect(await screen.findByRole('alert')).toHaveTextContent(error.message)
    expect(screen.getByRole('button', { name: 'Pay $12.50' })).toBeEnabled()
    expect(onSuccess).not.toHaveBeenCalled()
    expect(onError).toHaveBeenCalledWith(error)
    expect(setSubmitting).toHaveBeenLastCalledWith(false)
  })

  it('announces an unknown payment response without inventing a success', async () => {
    const onSuccess = vi.fn()
    confirmPayment.mockResolvedValue({})
    render(<PaymentForm totalCents={1250} returnUrl="https://example.test/confirmation"
      onSuccess={onSuccess} submitting={false} setSubmitting={vi.fn()} />)
    await userEvent.click(screen.getByRole('button', { name: 'Pay $12.50' }))
    expect(await screen.findByRole('status')).toHaveTextContent('Please refresh before trying again')
    expect(onSuccess).not.toHaveBeenCalled()
  })
})
