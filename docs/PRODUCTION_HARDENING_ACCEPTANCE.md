# Production hardening acceptance

Work started October 26, 2026 against `4637080b7debb87c27b2dc63f40cdf99d8098eda`.
The scope is safe financial recovery, dependable admission recovery, privacy boundaries,
and the existing mobile web experience. Engineering delivery and an accepted real event
are separate outcomes.

## Product and scope

HåfaPass serves Guam ticket buyers, organizers, and door staff. Buyers need usable tickets
and reliable repayment; organizers need accurate inventory, scoped staff access, and a
financial closeout. Door staff need fresh credentials and recoverable admission records.
Rails/PostgreSQL owns money and admission state; the React PWA keeps a signed admission
manifest and a durable local journal. A disconnected device cannot learn another gate's
offline admissions until synchronization.

The current launch scope is general admission and ticket transfers. Assigned seating,
recurring automation, advanced sales tools, Google Wallet, and onsite card acceptance
remain separately gated. These fixes do not enable those capabilities or establish a
native app release. Payout recording does not itself issue a check or bank transfer.

## Engineering acceptance

- A selected-ticket refund keeps its selection through a retry. Pending blocks that
  ticket; success cancels only that ticket and releases its inventory once.
- A late captured cancelled/expired order can be repaid and reconciled without issuing
  tickets, consuming released capacity, or repeatedly failing signed callbacks.
- Concurrent payment recovery and webhook completion use consistent lock ordering and
  fulfill once without a deadlock. Unknown external refunds have a verified recovery path.
- An online scanner checks a fresh manifest before declaring an unfamiliar credential
  invalid. New and transferred credentials work without a manual-refresh workaround.
- A current manager can recover supported historical scans from a revoked device using
  original evidence and an audit trail, without restoring that device's scanning rights.
- Admission labels distinguish issued tickets, eligible entry, and confirmed check-ins.
  Shared-network limits preserve both legitimate scanner traffic and abuse protection.
- Organizer exports contain buyer registration answers, never internal support-note
  bodies. The legacy export column key remains compatible; its label describes answers.
- Confirmed account changes withdraw saved guest-order capabilities. Unchanged guests
  retain their links, and uncertain checkout identities remain available for safe recovery.
- Installation help respects the buyer's choice and describes offline limits. Form inputs
  remain readable on touch devices without disabling zoom.

Regression tests must check desired behavior and persisted outcomes. An observational
test that confirms a defect is not a passed acceptance case. Re-run under locked
dependencies, then execute affected UI journeys and the complete repository gate.

## Release and event evidence

The release record must identify final tested commits, current-head independent and
CodeRabbit reviews, required CI, merge commits, and actual API/web deployed revisions.
Monitoring must receive a sanitized release-bound test error and reach an attended alert
path. Real email delivery, stale-event investigation, backup restoration, provider
permission, and actual check reconciliation need their own evidence.

A real event remains unaccepted until a named operator rehearses supported phones and
at least three gates, including duplicates, a new purchase, transfer/refund, disconnected
operation, shared IP, revoked-device recovery, cash sales, and final totals. Physical
camera behavior, installed cold starts, wallet delivery/updates, and background/resume
cannot be certified by desktop browser resizing or provider mocks.

Keep private fixtures, provider references, and the detailed case ledger outside Git.
Record `passed`, `failed`, `blocked`, and `not_run` honestly, with source/device limits.
Current owner-approved policy records are distinct from independent provider approval;
optional historical launch reviews do not become requirements merely through this file.
