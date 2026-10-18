# Stripe processing fee evidence

HafaPass records the original capture's actual provider cost after Stripe supplies its balance transaction. This does not approve a charge architecture, assign fee liability, authorize a payout, or prove a bank deposit. Those decisions and proofs remain required before live sales.

## Capture reconciliation

`StripeProcessingFees` retrieves the original PaymentIntent with `latest_charge.balance_transaction` expanded. `StripeService` checks the saved test/live environment, platform account, and connected-account scope before the request. The reconciler checks the intent and captured charge against the payment's identity, amount, currency, and mode, then checks the balance transaction's charge source, amount, currency, fee breakdown, and `net = amount - fee`.

A verified capture creates one append-only processing `FeeComponent` and one `StripeFeeEvidence` record. The component contains the balance transaction reference, charge reference, payment ID, and provider context digest. Exact repeats reuse the component. A later contradictory monetary snapshot preserves the original component and places the evidence in review. Balance availability may change from pending to available without creating another fee.

Stripe can create balance transactions asynchronously after capture. The job retains a pending database record, next retry time, and an open reconciliation item until the evidence arrives. `charge.updated` requests another reconciliation. See [Stripe's fee expansion guide](https://docs.stripe.com/expand/use-cases) and [balance transaction fields](https://docs.stripe.com/api/balance_transactions/object).

Finalization, organization payout availability, and Gate J independently require verified fee evidence for every captured external Stripe payment. This check also applies when no queue entry or reconciliation item exists. Resolving an exception alone cannot bypass missing evidence.

Cash and simulated captures do not create Stripe fee evidence and do not prove live processing costs. Test evidence remains test evidence; it cannot grant production admission or replace Gate H.

## Worker operation

Deploy migration `20261010040000` before starting the new code. Subscribe the Stripe webhook to `charge.updated` as well as the existing payment, refund, and dispute events.

The per-payment `StripeProcessingFeeJob` retries transient errors. The existing singleton commerce clock queues `SweepPendingStripeFeesJob` immediately on start and every five minutes to recover lost queue entries, expired job retries, or imported captures without an evidence row. Keep that clock supervised alongside the worker; do not add a second cron or scheduler for this sweep. A delayed tick schedules one recovery sweep, and a restart may safely schedule another because the job reconciles durable evidence. The sweep queues work from database state; it makes no provider request itself.

```ruby
SweepPendingStripeFeesJob.perform_later
```

Monitor pending age, attempts, `last_error_code`, and open fee reconciliation items. Restricted Stripe credentials require read access to the current platform account, PaymentIntents, charges, and balance transactions. A changed account, incorrect key mode, or unknown legacy context requires finance review.

## Cases requiring finance review

- Foreign charge/transaction identities, amount or currency differences, and contradictory later costs.
- Currency conversion. The current ledger does not invent an exchange rate or settlement-currency allocation.
- Application-fee or unsupported fee mixes. The charge architecture and ownership of each cost must be approved first.
- Missing fee details, including IC+ pricing. Stripe documents that IC+ costs require a Payment fees report; an empty breakdown does not prove zero cost.
- Existing manually entered processing costs. The reconciler does not append a duplicate or guess which payment they belong to. Map them through an audited finance repair using the original provider evidence.

Refunds preserve the original capture cost. Successful external refunds and closed disputes create a separate `stripe_fee_adjustment_review_required` item. Finance must reconcile the exact provider adjustment, including any fee credit or dispute fee, record any required append-only balance adjustment with its source reference, and resolve the item with evidence. This implementation does not assume processing fees are returned, prorate them, or invent dispute costs. Automated refund/dispute fee ingestion remains a separate integration task.

## Card payment scope

New ticket PaymentIntents explicitly use `allowed_payment_method_types: ["card"]`. HafaPass's ten-minute inventory hold does not support bank methods that can settle days later. The API allowlist prevents a later Dashboard setting from exposing those methods without a corresponding reservation policy. Stripe introduced this parameter on July 29, 2026; it is mutually exclusive with `automatic_payment_methods`, `payment_method_types`, `excluded_payment_method_types`, and `payment_method_configuration`. The locked Ruby SDK 20 uses API version `2026-09-30.endive`, which supports it. See [Stripe's parameter changelog](https://docs.stripe.com/changelog/dahlia/2026-07-29/allowed-payment-method-types-parameter).

Eligible card-funded wallets can still use card payments, subject to actual account, registered domain, device and browser support. This code does not prove Apple Pay or Google Pay availability. Cards can also require authentication or remain processing; test 3DS, expiry, delayed callbacks, late captures and recovery before launch. Fulfillment still depends on verified provider success. See [card payment methods](https://docs.stripe.com/payments/cards) and [PaymentIntent lifecycle](https://docs.stripe.com/payments/paymentintents/lifecycle).

Adding other methods requires a reviewed processing reservation, expiry, late capture, refund and reconciliation policy plus actual provider tests. This fee reconciler does not reserve inventory while a delayed payment processes. Existing intents retain their original provider configuration and must be audited before enabling sales on a migrated environment.


Creation and resumption validate both the returned `allowed_payment_method_types` and compatible `payment_method_types` as exactly `card`. A legacy automatic intent is not assumed safe just because it currently displays cards. A conflicting create response retains the original provider identity and inventory reservation, opens a policy reconciliation item, and withholds its client secret. Retrying the saved checkout cannot create another reservation or provider operation.

The resume route withholds confirmation secrets for unconfirmed bank or unknown method configurations. It does not rewrite or blindly cancel an operation already processing or succeeded. Legacy bank operations already in flight still require the existing expiry, capture, refund, and finance reconciliation process; this card policy is not an automated migration or resolution of those operations.


## Legacy payment inventory and controlled repair

Before deploying against an existing database, an authorized operator must inventory Stripe payments missing frozen context and legacy orders without a payment row. An empty staging database does not establish that production is clear. Never infer historical ownership or mode from current environment variables.

Use the authorized environment's Rails console for this read-only inventory. Record its release and counts without exporting buyer data:

```ruby
legacy = Payment.where(provider: "stripe").where.not(provider_payment_id: nil)
  .where("LEFT(provider_payment_id, 4) <> 'sim_'")
  .where("provider_environment IS NULL OR provider_platform_account_id IS NULL")
legacy.group(:status).count
Order.where.not(stripe_payment_intent_id: nil).left_joins(:payments)
  .where(payments: { id: nil }).count
```

For each affected record:

1. Retrieve the exact original PaymentIntent from its original Stripe account. Verify its provider ID, test/live mode, platform and connected-account scope, amount, currency and payment state. Historical webhook `livemode` alone does not prove platform ownership; unsigned development fixtures are not evidence.
2. Record the controlled evidence reference and obtain authorization for those exact historical records. If facts cannot be verified, retain the financial hold and withhold production admission.
3. Prepare and test a narrowly scoped maintenance transaction on isolated synthetic fixtures. Lock the payment and recheck unchanged identity/state before filling only its missing readonly context through the approved maintenance path. Preserve original order/payment/provider IDs, idempotency key, amounts and financial history. Append the operator, evidence reference and before/after context to the audit log in the same transaction. Normal application updates must not rewrite frozen context.
4. Reconcile any unverified fee-evidence row created from missing context through an audited finance repair. Preserve verified evidence and original costs; map existing manual costs explicitly. Reconcile the capture through the normal fee service and close only the supported exception with its evidence reference.
5. Repeat the inventory and verify fulfillment, admission and settlement eligibility. Report unresolved rows as deployment blockers.

This required operator procedure is not an automatic migration or evidence that production was inspected or repaired. The legacy webhook path deliberately leaves unproved context unresolved. No callback, credential rotation or migration may manufacture historical ownership. Keep the existing API suspended until inventory and any authorized repair are complete.
