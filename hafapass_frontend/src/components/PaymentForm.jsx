import { formatMoneyCents } from '../utils/money'
import { useTranslation } from 'react-i18next'
import { useEffect, useRef, useState } from 'react'
import { Loader2 } from 'lucide-react'
import {
  PaymentElement,
  useStripe,
  useElements,
} from '@stripe/react-stripe-js'

export default function PaymentForm({ totalCents, returnUrl, onSuccess, onError, submitting, setSubmitting }) {
  const { t } = useTranslation()
  const stripe = useStripe()
  const elements = useElements()
  const [paymentError, setPaymentError] = useState(null)
  const [statusUnknown, setStatusUnknown] = useState(false)
  const errorRef = useRef(null)

  useEffect(() => { if (paymentError) errorRef.current?.focus() }, [paymentError])

  const formatPrice = (cents) => formatMoneyCents(cents)

  const handleSubmit = async (e) => {
    e.preventDefault()

    if (!stripe || !elements) {
      return // Stripe.js hasn't loaded yet
    }

    setSubmitting(true)
    setPaymentError(null)
    setStatusUnknown(false)

    const { error, paymentIntent } = await stripe.confirmPayment({
      elements,
      confirmParams: {
        return_url: returnUrl,
      },
      redirect: 'if_required',
    }).catch(() => ({ error: { type: 'connection_error' } }))

    if (error) {
      if (error.type === 'card_error' || error.type === 'validation_error') {
        setPaymentError(error.message)
      } else {
        setPaymentError(t('buyer.PaymentForm.anUnexpectedErrorOccurredPleaseTryAgain'))
        setStatusUnknown(true)
      }
      setSubmitting(false)
      if (onError) onError(error)
    } else if (paymentIntent) {
      // Stripe may return a processing intent while the webhook is still
      // authoritative. Move the buyer to the confirmation page so it can poll
      // the order instead of leaving them on a form they might submit twice.
      if (onSuccess) onSuccess(paymentIntent)
    } else {
      setPaymentError(t('buyer.PaymentForm.weCouldNotConfirmThePaymentStatusPlease'))
      setStatusUnknown(true)
      setSubmitting(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} aria-busy={submitting}>
      {paymentError && (
        <div ref={errorRef} tabIndex={-1} role="alert" className="bg-red-50 border border-red-200 rounded-xl p-3 mb-4 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus">
          <p className="text-red-700 text-sm">{paymentError}</p>
        </div>
      )}
      {statusUnknown && returnUrl && <a href={returnUrl} className="btn-secondary mb-4 w-full">{t('buyer.PaymentForm.checkOrderStatus')}</a>}

      <div className="mb-4" role="group" aria-label={t('checkout.payment')}>
        <PaymentElement
          options={{
            layout: 'tabs',
            wallets: {
              applePay: 'auto',
              googlePay: 'auto',
              // Disable Link only in this form; it can offer non-card funding.
              link: 'never',
            },
          }}
        />
      </div>

      <button
        type="submit"
        disabled={!stripe || !elements || submitting || statusUnknown}
        className="btn-primary w-full py-4 text-lg font-bold"
      >
        {submitting ? (
          <span className="flex items-center justify-center gap-2">
            <Loader2 aria-hidden="true" className="animate-spin motion-reduce:animate-none h-5 w-5" />{t('buyer.PaymentForm.processingPayment')}</span>
        ) : (
          t('buyer.PaymentForm.pay', { value1: formatPrice(totalCents) })
        )}
      </button>

      <div className="mt-3 flex items-start justify-center gap-2 text-xs text-content-muted">
        <svg aria-hidden="true" className="w-4 h-4 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z" />
        </svg>
        <span>{t('buyer.PaymentForm.securedByStripeYourPaymentInfoNeverTouches')}</span>
      </div>
    </form>
  )
}
