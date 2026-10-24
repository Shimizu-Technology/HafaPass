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
