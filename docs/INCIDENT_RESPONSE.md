# HåfaPass incident response

**Operations draft, 22 October 2026. Guam counsel must review before use.** This runbook covers suspected exposure of buyer, organizer, payment, tax, ticket, scanner, or account data. Keep an incident record separate from routine application logs and do not put personal data into chat or issue titles.

## First response

1. Record discovery time, reporter, affected systems, and what is known. Assign an incident lead and a separate evidence keeper. Preserve logs, audit trails, access events, provider notices and relevant configuration before changing them.
2. Contain the path: revoke exposed credentials, block malicious access, isolate affected workers or storage, and coordinate with Clerk, Stripe, AWS, Neon, Render, Netlify, Resend or Sentry as relevant. Record each change and its time. Do not delete evidence.
3. Determine whether data was accessed **and acquired**, whether it was unencrypted and unredacted, whether names were linked to a Social Security number, Guam or driver ID number, or financial account/card number with an access code, and whether identity theft or fraud has occurred or is reasonably expected for Guam residents. Include encryption-key compromise in the assessment.
4. Have Guam counsel decide notification duties, other jurisdictions, regulator/provider duties, and the content/channel of notice. Keep the assessment, contrary evidence, and decision in the incident record.
5. Restore and monitor safely. Check for continued access, unintended ticket or payout changes, and repeat compromise. Close only after the incident lead signs off on containment, notices, and follow-up work.

## Guam notice decision and timing

[9 GCA Chapter 48 §§48.20 and 48.30](https://col.guamcourts.gov/sites/default/files/9gc048.pdf) define a covered breach as unauthorized access **and acquisition** of unencrypted, unredacted computerized personal information in a multi-person database that causes, or is reasonably believed to cause or likely cause, identity theft or other fraud to a Guam resident. The statute's defined personal information is a name or first initial and last name linked to specified government IDs or financial credentials; ordinary email exposure alone is not automatically within that definition. A good-faith employee acquisition for a lawful purpose is excluded if there is no misuse or further unauthorized disclosure. These distinctions require evidence and counsel review, not a quick assumption.

If HåfaPass owns or licenses covered data, notify affected Guam residents **without unreasonable delay** after discovery or notice, allowing time needed to determine scope and restore reasonable system integrity. The chapter sets no fixed general number of days. Encrypted data may still trigger notice if acquired in unencrypted form or if a person with key access is involved and fraud is reasonably expected. If HåfaPass maintains covered data for another owner or licensee, notify that owner or licensee **as soon as practicable** after discovery when unauthorized access and acquisition occurred or is reasonably believed. A law-enforcement delay requires the agency's determination and advice; resume notice without unreasonable delay when the agency says it no longer impedes the investigation or security. See [§48.30(a)–(d)](https://col.guamcourts.gov/sites/default/files/9gc048.pdf).

Permitted notice methods are postal writing, telephone, or electronic notice. Substitute notice is available only when statutory cost, class size, or contact/consent conditions are met, and requires any two of email, conspicuous website posting, or major Guam media. Counsel should approve the channel and text. See [§48.20(g)](https://col.guamcourts.gov/sites/default/files/9gc048.pdf).

## Monitoring alerts: what they mean and the first three actions

These are operational alerts, not data-exposure incidents. If any step shows buyer, organizer, payment or ticket data was exposed, switch to **First response** above. Setup and tests are in [Monitoring setup](MONITORING_SETUP.md). Never put buyer details in chat while you work an alert.

| Alert (Sentry tag) | What it means | First three actions |
|---|---|---|
| **Stripe webhooks silent** (`operational_signal:stripe_webhooks_silent`) | The app has evidence a webhook should have arrived: a payment recorded as paid with no success webhook after 30 minutes, or 10 or more payments started in 30 minutes with no webhook of any kind (live mode in production). Buyers may have paid and not received tickets. | 1. In Stripe, open the live webhook destination and look at **Failed deliveries** and whether the endpoint is disabled; confirm its URL is the API. 2. Check Render for the API: a deploy in progress, a crash loop, or `/api/v1/readiness` not ready. 3. Do **not** replay anything blind. After the endpoint is fixed, resend the missed events from Stripe, then compare with Admin → Monitoring (the "Paid, no webhook yet" count should reach 0) and Admin → Reconciliation. |
| **Unverified Stripe deliveries rejected while real ones look missing** (`operational_signal:stripe_unverified_deliveries`) | 3+ deliveries in 15 minutes failed signature verification (or arrived with no signing secret configured), **and** no verified receipt has arrived for 30 minutes while payments were started or a paid payment is still waiting for its success webhook. Rejected senders can't be identified, and the URL is public, so rejections alone never page; this pattern is what a rotated or wrong signing secret looks like, and buyers may be paying without confirmation. | 1. In Stripe, open the live webhook destination and check its failed deliveries and which signing secret it uses (reveal only in Stripe; don't paste it anywhere). 2. Compare with `STRIPE_LIVE_WEBHOOK_SECRET` on the API service in Render (set, not printed) and fix any mismatch; redeploy or restart. 3. Resend the failed events from Stripe, then confirm Admin → Monitoring shows unverified rejections stop and "Paid, no webhook yet" falls to 0. If Stripe shows no failed deliveries, the rejections are probably noise: leave it. |
| **Stripe webhooks failing** (`stripe_webhook_failures`) | 3 or more receipts failed or hung in the last 15 minutes. Stripe retries, but orders may be stuck pending. | 1. Open the Sentry event tagged `integration:stripe_webhook` for the exception and release. 2. If it began with a deploy, roll back the API. 3. Compare the failed receipts with Stripe's event before any replay (Admin → Operational review → Failed payment updates); resolve reconciliation exceptions with a note. |
| **Stripe webhook processing exception** (`integration:stripe_webhook`, `operation:webhook_processing`) | One webhook raised an error while processing. | Same as failing, starting at step 1. A signature rejection returns 400 before this point; check Stripe's failed deliveries for those. |
| **Failed payment updates** (`failed_payment_webhooks`) | Standing count of failed receipts. | Compare each with Stripe before replay; never edit the database to close one. |
| **Open reconciliation exceptions** | A payment or refund disagrees with Stripe. Payouts for the organization are held while it is open. | Open Admin → Reconciliation, read the code, resolve with a note. Don't release a payout first. |
| **Failed background jobs** (`failed_background_jobs`) | Solid Queue jobs failed in the last hour. | 1. Read the job class and error in the Sentry issue. 2. Check `/api/v1/readiness` for worker and clock. 3. Retry only jobs known to be safe to repeat; see [Operations runbook](OPERATIONS_RUNBOOK.md). |
| **Exhausted email deliveries** | Emails failed 5 or more times. | Check Resend status, then use **Resend failed messages** in the support console. |
| **Error on checkout, webhook, scanner or box office** (`area:*`) | A new or returning error on a money or door path. | 1. Check whether sales or scanning are actually failing (try a test purchase or scan). 2. Match the Sentry release to the last deploy. 3. If it began with a deploy, roll back; on event day, switch scanners to the offline manifest per [Event-day operations](EVENT_DAY_OPERATIONS.md). |
| **Recovered** (`operational_state:recovered`) | The thing that opened the incident was put right: the incident's failed receipts or waiting payments were resolved after it opened (an unrelated webhook doesn't count). | Confirm in Admin → Monitoring. |
| **Note: unverified rejected deliveries** (`operational_state:note`) | Rejected deliveries with no sign real ones are missing. Information only. | Nothing unless Stripe's dashboard shows failed deliveries. |
| **Quiet, not confirmed recovered** (`operational_state:quiet`) | The evidence aged out of the alert window but the cause was not confirmed fixed (for example a paid payment is still waiting for its success webhook). It is **not** all clear. If the message says `paged: false`, a short blip cleared before it could be paged. | Read the unresolved-row count in the message, then check Admin → Monitoring and Stripe's recent deliveries. |

A `[TEST]` event is a drill sent by an admin from Admin → Monitoring & alerts. It is safe to ignore; resolve it.

## Contacts and ownership

| Role | Contact path | Action |
|---|---|---|
| Incident lead | Shimizu Technology owner / HåfaPass operations roster | Start the incident record, containment, assignments, status updates and closeout. |
| Guam counsel | Current counsel engagement contact; if none, owner retains counsel immediately | Decide Guam and other legal notice obligations, law-enforcement coordination, and notice wording. |
| CPA | Current accounting engagement contact | Assess tax/TIN and payout evidence, financial reconciliation and record preservation. |
| Security and infrastructure owners | Provider security/support consoles for Clerk, Stripe, AWS, Neon, Render, Netlify, Resend and Sentry | Contain provider access and obtain written incident evidence. |
| Event organizer | Verified organization owner/contact in HåfaPass | Coordinate event attendee data and their separate use of it. Counsel decides which party sends each notice. |
| Guam Office of the Attorney General | [Guam OAG official site](https://oagguam.org/) | Counsel determines whether and when to contact; the statute gives the OAG enforcement authority, not an automatic notice requirement in every case. |
| Affected people | Verified buyer or organizer contact channels | Send approved notice when required and keep delivery evidence. |

Do not delay a legally required notice waiting for perfect attribution or a completed root-cause report. Keep a dated timeline of the discovery, legal assessment, recipient list, notices, provider replies, restoration and corrective work.
