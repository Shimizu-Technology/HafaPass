# Waitlist, inventory, and email delivery invariants

This is the lock contract for code that changes a waitlist entry, reserves or releases inventory, or processes a waitlist delivery. The organization lock is taken first when needed. Paths that do not need it start at the event. A path may skip ranks, but never go back up a rank. Reacquiring a row already owned by the same transaction is harmless; new callers should avoid it. Keep network calls outside these transactions except the bounded campaign dispatch authorization boundary described below.

| Rank | Locks, in order within the rank |
| --- | --- |
| 1 | Organization row |
| 2 | Event row (`FOR NO KEY UPDATE` is enough for capacity serialization) |
| 3 | Order row, then its payment, holds, and related financial rows, sorted by ID where there are several |
| 4 | Waitlist advisory transaction lock keyed by entry ID, then offer, entry, and delivery rows |
| 5 | Ticket type rows, then pricing tier rows, then seat session and seat rows; sort each set by ID |

`WaitlistLocks.with` owns the rank 1 → 2 → 4 prefix for standalone waitlist operations. A caller with a claimed offer must acquire ranks 1 and 2 before rank 3, and call `WaitlistLocks.with` before taking any inventory lock. An ordinary order starts at rank 2. The advisory lock stabilizes the active-offer lookup before the offer and entry rows are locked. Its transaction scope prevents an unsubscribe, rejoin, receipt, or new alert round from slipping between lookup and mutation. The order lifecycle holds the claimed offer's rank 4 locks through conversion or release; it does not return to rank 4 after ticket types or the seat session.

## Path order

| Path | Lock order |
| --- | --- |
| Offer issuance | Organization → event → advisory → active offer → entry → ticket type → tier. |
| Checkout with offer | Checkout attempt (preflight owner, never reacquired later) → organization → event → advisory → offer → entry → ticket types → tiers → seat session. A new order and its payment/holds are created while those parent locks are held. |
| Checkout without offer | Checkout attempt → event → ticket types → tiers → seat session; new order and holds are created under the event lock. |
| Box office cash sale | Event → ticket types → tiers → seat session; completion stays under the event lock. |
| Completion, cancellation, failure, or expiry without a claimed offer | Event → order → payment and holds → ticket types, tiers, and seat session when needed. |
| Completion of a claimed order | Organization → event → order → payment and holds → advisory → offer → entry → ticket types → tiers → seat session. Offer conversion uses the already held rank 4 rows. |
| Cancel, fail, or expire a claimed order | Organization → event → order → payment (when supplied) → advisory → offer → entry → held inventory and seat session. Offer release uses the already held rank 4 rows. |
| Refund and refund webhook finalization | Organization → event → order → payment/refund/tickets → ticket types and tiers when inventory is reversed. A refund of a converted order does not reopen its waitlist offer. |
| Scanner registration/renewal and manifest download | Organization → event → scanner device. Download holds all three through manifest construction, current authorization/lease rechecks, device update and historical grant snapshot/audit watermark. Direct download updates take the parent locks before the scanner write; the snapshot callback only reacquires an owned organization lock. Never enter a download update holding only the scanner lock. |
| Unsubscribe and rejoin | Organization → event → advisory → active offer → entry. Each request commits before the next; the claimed offer of an existing order is left for that order's lifecycle. |
| Waitlist receipt, alert round, and delivery job | Organization → event → advisory → offer (if any) → entry → delivery. The receipt record is idempotency evidence; it never determines the order of waitlist row locks. |

The order is covered by latch-based PostgreSQL specs with a short `lock_timeout`. Each competing worker signals immediately before attempting its contested lock; a failed cycle raises instead of hanging. No timed sleep is used as a concurrency assertion.

## Delivery status

Provider receipts are always recorded in `message_provider_events`, including contradictory receipts. Only the transitions in `MessageProviderEventProcessor::ALLOWED_TRANSITIONS` may mutate a delivery; a newer timestamp alone never overrides a terminal failure. A receipt for a known message ID is marked processed even when its status transition is rejected. `last_event_at` describes the receipt that set the delivery status, not necessarily the last receipt received.

| Current status | Allowed next provider statuses | Additional rule |
| --- | --- | --- |
| queued | sent, delivered, delayed, failed, bounced, complained, suppressed | — |
| sent | delivered, delayed, failed, bounced, complained, suppressed | — |
| delayed | delivered, failed, bounced, complained, suppressed | — |
| failed | delivered, delayed, failed, bounced, complained, suppressed | Only if the prior failure was not an invalid address. |
| delivered | failed, bounced, complained, suppressed | `failed` only for an invalid address. Definitive failure can override an earlier success. |
| bounced | delivered, bounced, complained, suppressed | Only a transient bounce may move forward; a hard bounce is terminal. |
| complained, suppressed, cancelled | none | Terminal. |

Nonterminal receipts older than `last_event_at` are audit evidence only. Definitive failures (hard bounce, invalid address, complaint, provider or local suppression) take precedence even if their provider timestamp is older. A hard bounce or invalid address blocks **all** later templates to that recipient; a complaint blocks commercial templates. A transient failure or transient bounce does not create permanent address suppression. Local suppression is not confused with provider evidence when deciding future sends.

`MessageAddressFailure` classifies both synchronous Resend rejection errors and webhook `email.failed`/`email.bounced` payloads. It reads the documented webhook `failed.reason`, bounce subtype, and SMTP `diagnosticCode` values. It recognizes recipient/mailbox-not-found language, invalid-recipient reason codes, and address-specific SMTP 5.1.x codes, but excludes a `Transient` bounce. It does not treat quota or API-key failures as bad addresses. Both paths write `metadata.provider_address_invalid = true`; a webhook invalid-address `email.failed` becomes `suppressed`, matching a synchronous rejection. The metadata is durable evidence for suppression of a later refund notification even when the original delivery status is a bounce. Safe webhook payload storage retains only the bounce, failure reason, and error fields needed for classification and audit.

Resend documents [permanent and transient bounce types](https://resend.com/changelog/email-bounce-details), [the bounce payload shape](https://www.resend.com/changelog/webhook-event-visibility), and [`failed.reason` and `diagnosticCode` in its OpenAPI schema](https://github.com/resend/resend-openapi/blob/main/resend.yaml). Keep the classifier's code list aligned with provider evidence as new codes are observed; do not infer permanence from every `email.failed` event.


## Campaign authorization

Campaign queueing takes organization → campaign, rechecks the sender, and commits
all deliveries before enqueueing jobs. Team mutations use actor (`FOR NO KEY
UPDATE`, for invitation quotas) → organization → membership/assignment. Ownership
transfers and permission revocations share the organization lock. Event-staff
mutations use this same order and recheck `manage_staff` after waiting.

A campaign delivery commits its existing durable payload and lease before network
activity, then takes the organization lock and rechecks `requested_by` immediately
before provider dispatch. This one provider call holds the organization lock,
with the existing 30-second timeout, so revocation cannot complete between the
check and dispatch. It does not hold the delivery row during the network call.
Unauthorized deliveries are cancelled and any prior unknown-provider outcome is
preserved for reconciliation. Other templates keep their existing delivery rules.
