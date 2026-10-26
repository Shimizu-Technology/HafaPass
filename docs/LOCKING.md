# Waitlist, inventory, and email delivery invariants

This is the lock contract for code that changes admissions, staff authority, waitlist entries, inventory or deliveries. Event-staff mutations, invitation acceptance/quotas and admission reconciliation take the actor row before organization, event or scanner locks. Other paths start at organization when needed, or event. A path may skip ranks, but never go back up a rank. Reacquiring a row already owned by the same transaction is harmless; new callers should avoid it. Keep network calls outside these transactions except the bounded campaign dispatch authorization boundary described below.

| Rank | Locks, in order within the rank |
| --- | --- |
| 0 | Actor/user row (`FOR NO KEY UPDATE` for admission authority, invitations and export quotas) |
| 1 | Organization row |
| 2 | Event row (`FOR NO KEY UPDATE` is enough for capacity serialization) |
| 2a | Scanner device, then actor's organization memberships ordered by ID, then event assignments ordered by ID, when reconciling admissions |
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
| Scanner registration/renewal, manifest download and audited device changes | Organization → event → scanner device. Download holds all three through manifest construction, current authorization/lease rechecks, device update and historical grant snapshot/audit watermark. Rename, lease, revoke and direct download updates take the parent locks before the scanner write; their audit/snapshot callback only reacquires an owned organization lock. Never enter an audited device change holding only the scanner lock. |
| Admission sync and manager journal recovery | Actor (`FOR NO KEY UPDATE`) → organization → event → scanner → actor memberships → actor event assignments → order → ticket. Recovery owns this prefix in its outer transaction before validating historical evidence, and holds it through every action, device sequence and required recovery audit. Each ordinary sync action owns the same prefix and rechecks current authority after lock waits. The final timestamp/sequence-only device update acquires no later parent/grant locks and triggers no operational audit. |
| Staff assignment mutation and invitation quota | Actor (`FOR NO KEY UPDATE`) → organization → membership/assignment. Recheck current permission under the organization lock. Invitation acceptance takes its accepting user first, then organization and membership/assignments; its derived user label update reuses the owned user lock. |
| Membership revocation and role/ownership changes | Organization → membership/assignments. Revocation and required audits commit together. Revocation's derived user-label refresh runs only after the outermost commit, then locks/reloads user (`FOR NO KEY UPDATE`) and reads current memberships. It acquires no organization/grant lock. Rollback discards the refresh; a successful request returns after it completes. |
| Sales and activity export quota | Actor (`FOR NO KEY UPDATE`) → quota count and required export audit. The audit needs an organization FK key share. The actor lock serializes competing requests while allowing manifest/registration/campaign FK references to that user. |
| Unsubscribe and rejoin | Organization → event → advisory → active offer → entry. Each request commits before the next; the claimed offer of an existing order is left for that order's lifecycle. |
| Waitlist receipt, alert round, and delivery job | Organization → event → advisory → offer (if any) → entry → delivery. The receipt record is idempotency evidence; it never determines the order of waitlist row locks. |

The order is covered by latch-based PostgreSQL specs with a short `lock_timeout`. Each competing worker signals immediately before attempting its contested lock; a failed cycle raises instead of hanging. No timed sleep is used as a concurrency assertion.

### Admission counterpaths and foreign keys

Include implicit row locks in this order. Admission actions reference organization, event, device and actor; manifests reference organization, event and their generating user; operational audits reference organization. A device-first admission or audited device update can therefore wait for a manifest's organization/event lock even without an explicit parent `lock!`. Admission reconciliation takes the parent prefix before the device or authorization rows to prevent that inversion. Financial finalization keeps organization/event before order/ticket and never acquires a scanner or a strong actor lock afterward.

`FOR NO KEY UPDATE` conflicts with another `FOR NO KEY UPDATE`; it serializes same-user scanning, staff mutation and invitation/export quotas. Its compatibility is with FK `KEY SHARE`, not with another actor lock. Downloads, registration and campaign authoring/queueing/dispatch can hold organization while referencing a user, but do not then request a strong user lock. Export quotas must likewise use `FOR NO KEY UPDATE`, rather than `FOR UPDATE`, or a new manifest's generating-user FK can cycle with the export audit's organization FK.

Do not update a target user's derived member label while owning organization or grant rows. Revocation defers that update until commit; acceptance already owns its accepting user before organization. A delayed refresh takes the user lock before deriving the label, so later committed membership changes determine the result. Permission checks continue to use memberships, assignments and the user's real platform role; the derived organizer label grants no authority.

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
all deliveries before enqueueing jobs. Invitation quotas and event-staff mutations use actor (`FOR NO KEY UPDATE`) →
organization → membership/assignment. Membership changes and ownership transfers
share the organization lock. Event-staff mutations recheck `manage_staff` after
waiting. Derived user-label refreshes follow the commit boundary above.

A campaign delivery commits its existing durable payload and lease before network
activity, then takes the organization lock and rechecks `requested_by` immediately
before provider dispatch. This one provider call holds the organization lock,
with the existing 30-second timeout, so revocation cannot complete between the
check and dispatch. It does not hold the delivery row during the network call.
Unauthorized deliveries are cancelled and any prior unknown-provider outcome is
preserved for reconciliation. Other templates keep their existing delivery rules.
