# External email receipts

HåfaPass shares a Resend account with other applications. A verified callback
proves its provider signature, not that HåfaPass sent the email. Unknown receipts
remain actionable until an exact saved delivery reconciles them or reviewed
evidence establishes that they belong to another application.

## Reviewed correction

An authorized operator can call `ExternalMessageReceipts.call` from Rails with
a persisted platform admin, one to four exact receipt identities, and a bounded
evidence reference. This is a server-side operator operation; there is no bulk
dismiss button or writable receipt endpoint.

```ruby
ExternalMessageReceipts.call(
  actor: verified_admin,
  receipts: reviewed_identities,
  proof_reference: "receipt-origin:2026-10-26/review-reference"
)
```

Each identity must contain exactly `id` (integer), `provider`,
`provider_event_id`, `provider_message_id`, and `event_type` (strings). Supply
independently reviewed expected values. Do not generate expected identities by
querying arbitrary IDs immediately before the call: that defeats the precondition.
The evidence reference is an internal locator, not freeform notes, a URL, or
provider content. Its grammar is enforced by `PROOF_REFERENCE` in the service.
Keep the underlying source evidence private.

The operation reloads and locks the current admin, requires a benign Resend
sent/delivered receipt with no link, processed marker, processing error, or exact
saved delivery, and records one immutable admin-only audit decision per receipt.
All rows succeed or roll back together, including when an enclosing caller
rescues a rejection. It never changes receipt fields, creates a delivery, queues
work, or calls a provider. A repeat with identical identity/evidence returns the
same audit; a conflicting decision rejects. The immutable deduplication key
contains a digest of identity/evidence, so retries remain comparable after audit
payload redaction. Do not edit/delete the audit or use `processed_at` to dismiss
receipts. Reopening decisions is not implemented.

The transaction takes a short `SHARE NOWAIT` lock on `message_deliveries` before
locking the explicit receipt rows in ascending order. Row locks alone cannot
prevent insertion or saving of a matching provider ID. This table lock closes
that validation gap without adding a new lock contract to every existing sender.
It conflicts with delivery writes across the table, so keep the batch bounded
and run outside long-lived caller transactions. The service requires read-committed
isolation: a previously established repeatable-read snapshot could miss an ID
saved before the table lock was acquired. Admin and receipt locks also
use `NOWAIT`: a sender/processor may hold those locks in another order. Busy
state raises `ActiveRecord::LockWaitTimeout` and rolls back; recheck state and
retry the exact evidence. No lock error is treated as a successful decision.
Ordinary sending/processing/recovery code and its lock order remain unchanged.

The existing audit integrity policy is reused: no new tables, foreign keys,
trigger exceptions, shared fail-open policy, or receipt state are introduced.
Both actions are registered as admin-only. An inherited fail-open context is
locally disabled, and a missing audit is an error. The action and subject are
the durable classification; redactable metadata is not used to hide receipts.

## Counts and history

Dashboard/readiness warnings and the operational drilldown share the same
actionable scope. Only explicitly classified, still-unmatched, benign, unprocessed,
error-free receipts are excluded. A new exact saved delivery, link, or processing
error immediately removes that exclusion. Normal reconciliation can still link
and process the original receipt. Processed receipts follow ordinary processor
semantics and are not outstanding review work.

The admin Operational review screen has a separate **Confirmed external email
receipts** category and count. It shows local receipt numbers, fixed provider/event
vocabulary, timestamps, and the disposition; it does not expose addresses,
subjects, bodies, provider IDs, proof references, or error content. History counts
are separate from actionable signals. An original decision remains in the audit
trail after a later match/error removes a receipt from the resolved category.

## Future provenance

New HåfaPass payload preparation adds `application=hafapass` alongside the existing
category. Already frozen payloads/wire bytes/idempotency keys are sent unchanged.
The synchronous privacy-challenge path receives the same application marker.

After raw-byte signature verification and normal exact-ID processing, the Resend
controller may classify a still-unmatched benign receipt whose saved provenance
contains exactly the known `csg_learn` application marker. Only that known foreign
application is accepted. Strict hash tags or a single application entry in a
valid tag array are supported. Missing, malformed, duplicate, conflicting,
unregistered and HåfaPass markers remain ordinary unresolved receipts. Only the
bounded known marker is retained as provenance; arbitrary tag values are not copied.
Calling the ordinary processor directly does not classify provenance.

An exact saved HåfaPass provider ID always wins, including with a contradictory
foreign tag. Errors, already processed records, adverse and unsupported event
types are never classified by the provenance path. Classification is per receipt,
not per account/message: a new unknown or adverse event stays actionable. Replays
use the saved receipt's identity/provenance and cannot rewrite legacy evidence.

## Acceptance and ownership

Source orientation: base `aed8cdf211c2c2389544c346dd80cb8dfcb2fab2`, 26 October
2026; `README.md`, `docs/PRODUCTION_CUTOVER.md`, current messaging/audit source,
and the private source design review supplied by the parent. Users affected are
platform admins reviewing operational warnings; buyer, organizer and door flows
continue through the existing delivery processor. The parent independently proved
the four legacy receipts belong to CSG Learn; this implementation did not access
production or providers.

Automated acceptance covers preserved receipt bytes, identity/admin/evidence
guards, atomic audit failure, nested transactions, deterministic retry,
concurrency with provider-ID writes, safe counts/history, later reconciliation,
signed provenance, unknown/adverse events, and new/legacy transport contracts.
The UI follows the existing operational page patterns, preserves category/page
URLs, and adds no motion or mutation controls. Parent-owned runtime acceptance
must check dashboard → actionable list → external history → refresh/back on
desktop keyboard and a narrow viewport, plus error/retry and saved-state agreement.
Automated UI tests and Impeccable do not establish those actual GUI journeys.
The parent owns independent review, GUI acceptance, PR/release and any guarded
production application. This worker's scope excludes those actions.
