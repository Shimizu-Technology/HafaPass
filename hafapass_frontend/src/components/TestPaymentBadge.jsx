import { useTranslation } from 'react-i18next'
// Marks an order paid in Stripe test mode, so test orders are never mistaken
// for real money in order lists.
export default function TestPaymentBadge({ order, className = '' }) {
  const { t } = useTranslation()
  if (!order?.test_payment) return null
  return <span title={t('buyer.TestPaymentBadge.paidWithAStripeTestCardNoReal')} className={`ml-1.5 inline-flex items-center rounded bg-neutral-100 px-1.5 py-0.5 align-middle text-[11px] font-semibold uppercase tracking-wide text-neutral-700 ring-1 ring-neutral-300 ${className}`}>{t('buyer.TestPaymentBadge.test')}<span className="sr-only">{t('buyer.TestPaymentBadge.payment')}</span>
  </span>
}
