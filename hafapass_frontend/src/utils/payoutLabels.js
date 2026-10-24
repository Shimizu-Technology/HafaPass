const PROVIDERS = { check: 'Check', manual: 'Bank transfer', legacy_manual: 'Bank transfer', paypal: 'PayPal', stripe: 'Stripe' }
const STATUSES = { pending: 'Review needed', onboarding: 'Setup in progress', requirements_due: 'Review needed', ready: 'Approved', restricted: 'Restricted', disabled: 'Disabled' }
const REQUIREMENTS = {
  business_verification: 'organization verification',
  payee_details_review: 'payee details review',
  payout_agreement: 'payout terms confirmation',
  bank_account_review: 'bank details review',
  independent_readiness_approval: 'finance approval',
  partner_approval: 'PayPal marketplace approval',
  seller_onboarding: 'PayPal seller setup',
  payout_method: 'PayPal payout method',
  guam_eligibility_review: 'Stripe Guam eligibility review',
  provider_onboarding: 'Stripe setup',
}

export const payoutProviderLabel = provider => PROVIDERS[provider] || 'Payout method'
export const payoutRequirementLabel = code => REQUIREMENTS[code] || 'payout details review'
export const payoutAccountLabel = account => `${payoutProviderLabel(account.provider)} · ${account.payout_ready ? 'Approved' : account.status === 'ready' ? 'Review needed' : STATUSES[account.status] || 'Review needed'}`
export const paidPayoutExplanation = provider => provider === 'check'
  ? 'Recorded as paid with the date on the check. This does not confirm the check has cleared.'
  : 'Recorded as paid after bank or provider payment confirmation.'

export const payoutReviewLabel = account => ({
  waiting: 'Waiting for HåfaPass review', approved: 'Payout method approved',
  changes_requested: 'Changes requested', incomplete: 'Setup incomplete',
})[account.payout_review?.status] || (account.payout_ready ? 'Payout method approved' : 'Waiting for HåfaPass review')
