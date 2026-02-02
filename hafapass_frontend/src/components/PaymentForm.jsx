import { useState } from 'react'
import { Loader2 } from 'lucide-react'
import {
  PaymentElement,
  useStripe,
  useElements,
} from '@stripe/react-stripe-js'

export default function PaymentForm({ totalCents, onSuccess, onError, submitting, setSubmitting }) {
  const stripe = useStripe()
  const elements = useElements()
  const [paymentError, setPaymentError] = useState(null)
  const [statusMessage, setStatusMessage] = useState(null)

  const formatPrice = (cents) => `$${(cents / 100).toFixed(2)}`

  const handleSubmit = async (e) => {
    e.preventDefault()

    if (!stripe || !elements) {
      return // Stripe.js hasn't loaded yet
    }

    setSubmitting(true)
    setPaymentError(null)
    setStatusMessage(null)

    const { error, paymentIntent } = await stripe.confirmPayment({
      elements,
      confirmParams: {
        return_url: window.location.origin + '/orders/confirmation',
      },
      redirect: 'if_required',
    })

    if (error) {
      if (error.type === 'card_error' || error.type === 'validation_error') {
        setPaymentError(error.message)
      } else {
        setPaymentError('An unexpected error occurred. Please try again.')
      }
      setSubmitting(false)
      if (onError) onError(error)
    } else if (paymentIntent && paymentIntent.status === 'succeeded') {
      if (onSuccess) onSuccess(paymentIntent)
    } else {
      // Payment requires additional action or is processing
      setStatusMessage('Payment is processing. You will receive confirmation shortly.')
      setSubmitting(false)
    }
  }

  return (
    <form onSubmit={handleSubmit}>
      {paymentError && (
        <div className="bg-red-50 border border-red-200 rounded-xl p-3 mb-4">
          <p className="text-red-700 text-sm">{paymentError}</p>
        </div>
      )}
      {statusMessage && (
        <div className="bg-blue-50 border border-blue-200 rounded-xl p-3 mb-4">
          <p className="text-blue-700 text-sm">{statusMessage}</p>
        </div>
      )}

      <div className="mb-4">
        <PaymentElement
          options={{
            layout: 'tabs',
            wallets: {
              applePay: 'auto',
              googlePay: 'auto',
            },
          }}
        />
      </div>

      <button
        type="submit"
        disabled={!stripe || !elements || submitting}
        className="w-full bg-accent-500 hover:bg-accent-600 disabled:opacity-50 disabled:cursor-not-allowed text-white font-bold py-4 px-6 rounded-xl text-lg transition-colors duration-200"
      >
        {submitting ? (
          <span className="flex items-center justify-center gap-2">
            <Loader2 className="animate-spin h-5 w-5" />
            Processing Payment...
          </span>
        ) : (
          `Pay ${formatPrice(totalCents)}`
        )}
      </button>

      <div className="mt-3 flex items-center justify-center gap-2 text-xs text-neutral-400">
        <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z" />
        </svg>
        <span>Secured by Stripe. Your payment info never touches our servers.</span>
      </div>
    </form>
  )
}
