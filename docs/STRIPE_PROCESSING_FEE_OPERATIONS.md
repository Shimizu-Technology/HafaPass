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

The per-payment `StripeProcessingFeeJob` retries transient errors. Run `SweepPendingStripeFeesJob` periodically, at least every five minutes, to recover lost queue entries, expired job retries, or imported captures without an evidence row. The sweep queues work from durable database state; it makes no provider request itself.

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

## Delayed payment methods remain a launch blocker

HafaPass currently has a ten-minute inventory hold and enables Stripe's dynamic payment methods. Some methods can settle days later. Before exposing them, approve a method configuration and prove its timing, or implement a documented processing reservation, expiry, late capture, and refund policy. This fee reconciler does not reserve inventory while a delayed payment processes. See [Stripe's PaymentIntent lifecycle](https://docs.stripe.com/payments/paymentintents/lifecycle).
