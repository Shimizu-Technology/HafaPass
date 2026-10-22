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
