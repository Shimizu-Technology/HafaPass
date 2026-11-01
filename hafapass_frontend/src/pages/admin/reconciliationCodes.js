import { adminLabel } from './adminLabels'

// Plain-language names and next steps for ReconciliationException codes.
// Unknown codes fall back to a readable code name and the generic guidance.
const LATE_CAPTURE = 'The card payment succeeded after HåfaPass had released the order, so the buyer has no tickets and is owed the full payment. The automatic refund normally finishes within minutes. If it has not, use Refund buyer.'
const PROVIDER_ORPHAN = 'Stripe sent an update for a payment HåfaPass has no order for. Check in Stripe whether it belongs to another integration or a deleted test, and record what you found.'
const REFUND_DISAGREES = 'HåfaPass refund records and Stripe disagree. Compare the refund in Stripe with the refunds on the order before resolving. Do not issue another refund until the difference is explained.'
const FEE_PENDING = 'The actual Stripe processing fee is not verified yet. The fee sweep retries automatically. Resolving this does not add fee evidence; the statement still needs verified fees before it can be finalized.'

const CODES = {
  late_payment_success_after_inventory_release: { label: 'Paid after the order was released', guidance: LATE_CAPTURE },
  late_payment_success_after_hold_expiry: { label: 'Paid after the hold expired', guidance: LATE_CAPTURE },
  early_fraud_warning: { label: 'Stripe early fraud warning', guidance: 'The card issuer reported likely fraud. Review the order. If you agree, open it in Orders and use Cancel tickets and refund as fraud. If you decide not to refund, confirm that you reviewed it and resolve with the reason.' },
  payment_amount_mismatch: { label: 'Charged amount differs from the order', guidance: 'Compare the Stripe charge with the order total. Correct or refund the difference before resolving.' },
  payment_currency_mismatch: { label: 'Charged currency differs from the order', guidance: 'Compare the Stripe charge currency with the order before resolving.' },
  payment_context_mismatch: { label: 'Payment details differ from checkout', guidance: 'The Stripe payment does not match the checkout it was created for. Compare both records before resolving.' },
  payment_method_policy_mismatch: { label: 'Payment method not allowed for this checkout', guidance: 'Stripe reported a payment method this checkout does not accept. Check the charge in Stripe and refund if needed.' },
  payment_not_found: { label: 'Stripe payment with no HåfaPass order', guidance: PROVIDER_ORPHAN },
  refunded_payment_not_found: { label: 'Stripe refund for an unknown payment', guidance: PROVIDER_ORPHAN },
  disputed_payment_not_found: { label: 'Stripe dispute for an unknown payment', guidance: PROVIDER_ORPHAN },
  provider_payment_orphaned: { label: 'Stripe payment left without an order', guidance: PROVIDER_ORPHAN },
  provider_payment_cancel_failed: { label: 'Unpaid hold could not be cancelled in Stripe', guidance: 'Check in Stripe that the payment was cancelled and never charged. If it was charged, the buyer must be refunded.' },
  refund_operation_not_found: { label: 'External Stripe refund needs verification', guidance: 'A refund was made outside HåfaPass (for example in the Stripe Dashboard). Verify it from Refund issues so the order reflects it.' },
  refund_aggregate_requires_reconciliation: { label: 'External Stripe refunds need verification', guidance: 'Stripe shows more refunded than HåfaPass recorded. Verify the refunds from Refund issues so the order reflects them.' },
  refund_operation_mismatch: { label: 'Refund record disagrees with Stripe', guidance: REFUND_DISAGREES },
  refund_terminal_status_conflict: { label: 'Conflicting refund results from Stripe', guidance: REFUND_DISAGREES },
  provider_refund_total_decreased: { label: 'Stripe refund total went down', guidance: REFUND_DISAGREES },
  refund_missing_order_item_ledger: { label: 'Refund without ticket line details', guidance: REFUND_DISAGREES },
  card_present_result_unknown: { label: 'In-person card result unknown', guidance: 'Check the original card reader transaction before taking another payment. An unknown result is not a failed charge.' },
  admitted_inventory_retained: { label: 'Refunded ticket was already scanned', guidance: 'The ticket was refunded or lost to a dispute after the guest was admitted, so its inventory stays held. Resolve after the door count is reconciled.' },
  stripe_processing_fee_pending: { label: 'Stripe processing fee not verified yet', guidance: FEE_PENDING },
  stripe_processing_fee_review_required: { label: 'Stripe processing fee needs review', guidance: FEE_PENDING },
  stripe_fee_adjustment_review_required: { label: 'Stripe fee adjustment needs review', guidance: FEE_PENDING },
}

const GENERIC = 'Compare the Stripe record with the HåfaPass order and keep the evidence before resolving.'

export function reconciliationCodeLabel(code) {
  return CODES[code]?.label || adminLabel(code)
}

export function reconciliationCodeGuidance(code) {
  return CODES[code]?.guidance || GENERIC
}
