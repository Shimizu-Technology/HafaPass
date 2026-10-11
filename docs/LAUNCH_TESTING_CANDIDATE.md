# General-admission testing candidate

This release prepares HafaPass for bounded organizer and attendee rehearsals. Production paid sales remain behind the existing provider, policy, validation, live-money, device and pilot approvals. A passing test suite or an administrator changing a setting does not grant those approvals.

## Supported rehearsal

Use synthetic information in an isolated environment. The first release supports general-admission events, free registration or explicitly simulated payments, guest order recovery, ticket PDFs, staff admission scanning, support lookup, and refund/settlement accounting tests. Production and staging default to `HAFAPASS_LAUNCH_SCOPE=general_admission`.

Assigned seating, recurring-event generation, catalog/registration/waiver sales tools, ticket transfers, and door card payments are disabled in this scope. Pricing and ticket quantities remain available. Historical read and recovery operations remain available where needed. API guards enforce the same scope as the interface.

For a shared testing site, follow [Private testing staging](PRIVATE_TESTING_STAGING.md). It requires an isolated database, Clerk test accounts, HTTPS origins, a selected durable runtime and persistent application and manifest signing secrets. The initial embedded SQL profile needs no Redis or separate worker/clock. Verify those resources belong to staging before injecting credentials. Staging runs production loading with simulation by default; controlled provider rehearsal requires the explicit test-mode configuration and allowlists in that guide. Production money and payouts remain disabled. Do not copy production attendee information or approval records.

## Rehearsal sequence

1. Sign in as the organizer and complete the profile and organizer agreement test fixtures. Create a future event, enter Guam times, venue details and capacity, then add a ticket name, price and quantity. Check preview before publishing. Required fields and launch review appear together on the publishing checklist.
2. Sign out and register as a guest. Confirm the order remains open after reloading. Open the ticket and download its PDF. Test tickets identify the rehearsal environment; confirmation states whether email is simulated, queued, accepted, delivered or failed. Test Resend using the existing secure order access. No simulated delivery counts as inbox proof.
3. Sign in as assigned staff and prepare the scanner online. Confirm the event, manifest expiry and authorized device. Disconnect the API, reload, admit a test ticket and try its duplicate. Confirm the saved count persists after reload. Reconnect and verify the server outcome and journal count. An offline admission is provisional until reconciliation; different offline devices cannot see each other's saved scans.
4. Repeat with authentication unavailable while the API remains healthy. Only previously verified, unexpired device access bound to the original account may open. Confirmed sign-out or an account switch removes old access and attendee data; pending actions stay available only to their original staff account.
5. Test device expiry, revocation and a signing-key change. Stop new admissions when trust fails. Retain the pending journal, reconcile it through the original server-authorized device, then explicitly reset trust once no actions remain. Never clear a pending journal to make the interface look clean.
6. Search support by event, attendee, order reference and printed ticket number (`HP-T123`). Verify ticket results appear without admission/display credentials. Check role denial with an attendee account.
7. Run financial scenarios in simulation: partial and complete refunds, provider timeouts, reversed webhook delivery, failed/cancelled outcomes, multiple captures and disputes. Verify retries reuse their operation, unresolved results block closeout/payouts, and a finalized settlement's historical amounts remain unchanged while current liabilities affect payout availability.

## Deployment and rollback

Run `scripts/gate.sh` with the repository's Ruby/Node versions, an isolated test database, and `HAFAPASS_LAUNCH_SCOPE=full` for the broader regression suite. Frontend unit tests, browser recovery/accessibility smoke tests, security scans and required GitHub checks are release requirements.

Migration `20261009051000` retains historical refund-ticket reservations and enforces uniqueness only for active reservations. Deploy the migration before the API change. Its rollback deliberately refuses to discard repeated history; use a forward repair when those records exist. Keep web and worker revisions/configuration aligned. Set `GIT_SHA` or `COMMIT_REF` to the deployed revision; production rejects pilot approval without a valid release identity.

Also run migration `20261009090000` for durable image-upload receipts. Configure production `CLERK_AUTHORIZED_PARTIES` with the exact trusted frontend origins before rollout; production authentication requires it independently of CORS settings.

Migration `20261009110000` adds durable cash-sale identity and request digests. Run it before deploying the cash retry API. A saved box-office request recovers its original order and tickets; a changed request using that reference is rejected. Preserve these receipts during rollback and recovery, and roll application code forward when needed.

Review required status checks on the exact PR head before merging. Verify both the API and frontend after deployment. A frontend deploy preview connected to an older backend is not a staging rehearsal environment.

## External evidence still required

The software does not establish Guam payment-provider approval or direct organizer settlement. Cash/Clover automated refund adapters and a production organizer payout rail remain unavailable until their approved contracts and implementations exist. Hosted staging, optional S3 uploads, real inbox delivery, approved live charge/refund/settlement/bank proof, backups, alerts, load, and physical phone/venue rehearsal must be verified separately. Follow the existing gate documents; do not replace those checks with synthetic approval records.

Compatible development dependency fixes remove production dependency advisories. The remaining Tailwind 3 development chain requires a deliberate Tailwind 4 migration rather than a forced launch upgrade. Keep builds restricted to trusted repository inputs while that migration is pending.
