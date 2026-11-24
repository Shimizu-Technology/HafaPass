# Email classification and send controls

Reviewed on 2026-10-22 against `EmailService.prepare_delivery_payload`, its email templates, `MessageDeliveryJob`, and the organizer campaign sender. `ApplicationMailer` is an unused stub; delivery goes through Resend. Classification follows the message's primary purpose, not its job or template name. The [FTC CAN-SPAM guide](https://www.ftc.gov/business-guidance/resources/can-spam-act-compliance-guide-business) distinguishes commercial content from purchase and relationship notices.

`MessageDelivery::EMAIL_TEMPLATE_CLASSIFICATION` is the shared send-time classification. A spec checks every row below against that source. Marketing unsubscribe and spam complaints block commercial templates only. Hard bounces and provider-level invalid-address suppression block every template.

| Template | Classification | Primary purpose |
| --- | --- | --- |
| `order_confirmation` | Transactional | Confirms a completed order and provides receipt/ticket access. |
| `fulfillment_resend` | Transactional | Resends the requested order confirmation. |
| `ticket_delivery` | Transactional | Delivers an issued ticket. |
| `order_recovery` | Transactional | Restores access to an existing order. |
| `event_change` | Transactional | Reports a material change to a purchased event. |
| `pass_event_change` | Transactional | Notifies multi-night pass holders of a schedule, venue, or cancellation change to an included night. |
| `refund_notification` | Transactional | Reports an actual refund. |
| `refund_reconciliation_digest` | Transactional/relationship | Gives platform staff a refund operations digest. |
| `guest_list` | Transactional/relationship | Confirms a specific guest-list admission. |
| `ticket_transfer` | Transactional | Gives the named recipient access to a transferred ticket. |
| `event_reminder` | Transactional/relationship | Sends a reminder the user specifically requested. |
| `verification_request` | Transactional/relationship | Notifies staff of an organizer's verification request. |
| `payout_method_decision` | Transactional/relationship | Notifies the owner of payout approval or a change request, including the admin note. |
| `verification_decision` | Transactional/relationship | Tells the organizer when a review verifies, rejects, or suspends the account. |
| `organization_invitation` | Transactional/relationship | Invites a named person to a specific organization role. |
| `platform_invitation` | Transactional/relationship | Invites a named person to a specific platform role. |
| `fee_change_notice` | Transactional/relationship | Notifies an organizer owner of a specific scheduled fee change. |
| `waitlist_notification` | Commercial | Alerts a waitlist member that tickets are available and invites a new purchase. |
| `waitlist_offer` | Commercial | Offers reserved inventory and invites a new purchase. |
| `platform_confirmation` | Transactional | Confirms an explicit platform signup; no promotional content. |
| `audience_mailing` | Commercial | Consent-filtered platform or organizer mailing. |
| `audience_test` | Commercial | Verified sender-only TEST, excluded from campaign statistics. |
| `communication_campaign` | Commercial | Organizer-authored promotional content sent to opted-in buyers. |

The FTC describes the transactional/relationship categories narrowly. A waitlist request is not a completed or agreed purchase, so both messages are treated as commercial even though the recipient requested event-specific availability. They use the same organizer identity, certified address, visible unsubscribe, and one-click headers as campaigns. Joining a waitlist records a dated, event-specific request with the buyer address, event, source IP, and user agent. A request made after an earlier organizer marketing opt-out authorizes alerts and offers for that event only. A later organizer opt-out stops them. Provider suppression still applies immediately.

## Commercial campaign controls

- **Sender and subject:** `From` displays `Organizer via HåfaPass` with the configured, verified platform mailbox. Campaign subjects are organizer-authored and have CR/LF removed; waitlist subjects name the specific event. The campaign editor tells organizers to describe the message honestly. Truthfulness of free-form wording needs human review; software cannot verify an event claim.
- **Postal address:** Only the organization owner or platform admin can save and certify its public commercial-email address. The API validates a plausible address with a postal code, and the campaign sender refuses to queue campaigns without current certification. Waitlist alerts and offers cannot queue without current certification. The delivery job reads the certified address when sending, so an address added after an earlier failed attempt can support a new send. A withdrawn address suppresses queued mail; the entry returns to waiting and any unsent offer releases its inventory. Certification and syntax do not independently prove deliverability; the owner must maintain the real address.
- **Unsubscribe:** Every commercial body has a visible unsubscribe link. Waitlist links offer two choices: stop alerts for that event, or stop all marketing from the organizer. One-click waitlist headers stop that event's alerts. A signed, unexpired token identifies the organization and recipient; the public POST stores the opt-out immediately. Tests exercise a link after 31 days and queued campaign/waitlist sends after opt-out. Commercial messages include `List-Unsubscribe` and `List-Unsubscribe-Post: List-Unsubscribe=One-Click` per [RFC 8058](https://www.rfc-editor.org/rfc/rfc8058.html) and [Gmail's sender guidelines](https://support.google.com/mail/answer/81126). Resend/DKIM configuration still needs production-header verification; RFC 8058 requires those headers in a valid DKIM signature.
- **Consent and suppression:** Campaigns select the latest completed affirmative checkout choice for that organizer. Waitlist recipients requested event-specific notices, so those messages do not depend on a campaign opt-in. The request time determines whether it follows an earlier organizer opt-out. Queue processing rechecks the relevant request, later organizer opt-out, and provider bounce/complaint suppression immediately before transport. A new affirmative checkout can restore campaign consent only after completion and only if it is later than the opt-out.

Transactional templates contain order, admission, account, invitation, event-change, or requested-reminder information and no unrelated campaign text. Keep promotional copy out of them. Review this table and the rendered email payloads when adding a template or changing shared email content.

**Rollout:** Existing organizations have no certified address after migration. Their campaigns and waitlist sends cannot queue until the owner saves and certifies an address. Operations should contact organizers with active waitlists before relying on those notifications.

**Counsel question:** Confirm classification of explicitly requested event waitlist alerts and offers as commercial messages and the event-specific request/opt-out model.

## Platform audience and preferences (2026-11-24)

`PlatformSubscriber` is separate from accounts and organizer follows. Only confirmed addresses are eligible. Signup records source, optional name/interests/villages, and an append-only `EmailConsent` ledger with wording version `event-alerts-v1`, time, IP and user agent. The wording is “Subscribe to HåfaPass event alerts. Unsubscribe or change preferences anytime.” Checkout uses its own unchecked choice. Following does not imply email consent; an explicit follower choice records the same version and timestamp.

`EMAIL_DOUBLE_OPT_IN` defaults to `true`; only the literal `false` disables it. Signed confirmation links expire after two days and rotate on resubscription/opt-out. Duplicate public submissions return the same generic response and cannot modify existing preferences. Confirmation resend is limited to once per address per hour, with an additional public IP throttle. The signed preference link proves address ownership and can restore a subscription explicitly; it expires after 90 days. Account access verifies the address with Clerk. Unsubscribe-only tokens do not expire and cannot change other preferences.

Preferences control platform alerts and each related organizer. “Unsubscribe from all marketing” persists an address-wide block and individual organizer blocks so enabling one scope cannot reactivate others. Receipts, tickets and refunds are unaffected. Requested waitlist messages retain their existing event-specific opt-out and commercial classification/address/complaint safeguards; the global marketing toggle does not cancel a requested waitlist offer.

Platform admins use `/dashboard/email?scope=platform`; organizers use `/dashboard/email`. Lists expose search, scoped exports, filtered eligible counts, and send history. Platform filters include status, source, interest and date; consent details remain admin-only. CSV cells neutralize spreadsheet formulas; exports and admin unsubscribe are audit-logged. Organizer waitlist marketing requires separate buyer or follower consent. The existing event waitlist screen still manages specifically requested inventory alerts.

Compose plain text, inspect escaped rendered HTML at desktop/mobile widths, send a labelled TEST to your own Clerk-verified address, then send now or schedule. Tests never enter campaign statistics. All sends include identity, postal address, preferences and correctly scoped RFC 8058 unsubscribe headers. Platform sends fail closed without `HAFAPASS_POSTAL_ADDRESS`; organizer sends require the existing owner-certified address. No address is supplied by this code.

The dispatcher creates/enqueues at most 100 deliveries per batch from a consent-filtered snapshot, retaining unique per-recipient provider keys. Delivery rechecks consent, suppressions, postal address and actor authority. PostgreSQL serializes provider request slots across workers. `EMAIL_REQUESTS_PER_SECOND` defaults to 1 and is bounded to 0.1–2; Resend currently documents 10 requests/second per team at https://resend.com/docs/api-reference/introduction#rate-limit. A bulk-send 429 pauses marketing reservations for 30 seconds; durable job retries use polynomial backoff and the original frozen wire payload/idempotency key. Other applications sharing the Resend team must leave headroom. Audience snapshot/count queries currently load eligible email addresses in memory; large-list SQL pagination is a follow-up.

Before launch Leon must configure verified sending-domain DNS (SPF/DKIM/DMARC), `RESEND_API_KEY`, `MAILER_FROM_EMAIL`, `RESEND_WEBHOOK_SECRET`, public API/frontend URLs and `HAFAPASS_POSTAL_ADDRESS`. Subscribe the verified webhook to delivered, bounced, complained, delayed, failed and suppressed events. Confirm the consent wording and keep double opt-in on unless an explicit policy decision changes it. English copy uses frontend i18n keys with existing English fallback; reviewed translations remain a follow-up. Real mailbox, DKIM and provider acceptance were not exercised; local evidence uses captured simulated mail only.


### Priority delivery and rollback

Only audience blasts and communication campaigns use the single-threaded marketing lane. Self-tests and platform confirmations use `emails`; checkout subscription capture uses `default`. Priority-mail 429s use delayed Active Job retries without acquiring the marketing slot or sleeping on the queue thread.

Marketing reserves a future slot in a short transaction, commits, and waits before acquiring domain locks or starting its send lease. The campaign authorization transaction commits before HTTP. Revocation after the final permission check cannot withdraw an in-flight request; its acceptance is recorded with the existing recipient idempotency key and lease, including when permission changes during HTTP. No organizer, delivery or rate-slot row lock spans the wait or provider call.

Before rolling back migration `20261124140200`, reconcile deliveries that have only an `audience_mailing_id` or `platform_subscriber_id` subject. The migration refuses with a clear error before changing schema if any delivery lacks all six legacy subjects (order, ticket, event, organization membership, platform invitation, privacy request). Do not bypass this guard with `NOT VALID`: PostgreSQL still checks later updates, including webhooks and privacy redaction. Choose a retention/hold-aware reconciliation for those records before retrying rollback; the migration never deletes or fabricates their subject links.
