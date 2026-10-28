import { organizerFeeExplanation } from '../utils/feeTerms'

// Organizer-facing explanation of the current fee policy, card-processing
// bearer and payout timing. Terms apply to new orders; existing orders keep
// the terms recorded when they were placed.
export default function FeeTermsNote({ feeTerms, feePolicy, buyerFeePercent, className = '' }) {
  if (feeTerms.status === 'loading') return <p role="status" className={`text-sm text-neutral-500 ${className}`}>Loading current fee terms…</p>
  if (feeTerms.status === 'error') return (
    // Informational, not urgent: the rest of the editor stays usable.
    <div role="status" className={`flex flex-wrap items-center gap-3 text-sm text-red-700 ${className}`}>
      <span>Current fee terms could not be loaded.</span>
      <button type="button" onClick={feeTerms.retry} className="btn-secondary min-h-11 px-4 py-2 text-sm">Retry fee terms</button>
    </div>
  )
  const { payoutScheduleText } = feeTerms.terms
  return (
    <div className={`rounded-xl bg-neutral-50 p-3 text-sm text-neutral-700 ${className}`} data-testid="fee-terms-note">
      <p>{organizerFeeExplanation(feeTerms.terms, feePolicy, buyerFeePercent)}</p>
      {payoutScheduleText && <p className="mt-1 text-neutral-500">Payouts by check {payoutScheduleText.replace(/[.\s]+$/, '')}.</p>}
      <p className="mt-1 text-xs text-neutral-500">Changes apply to new orders. Existing orders keep the terms they were placed with.</p>
    </div>
  )
}
