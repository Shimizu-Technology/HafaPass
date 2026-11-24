# Copa payout lifecycle: what works, what was missing, what was added

Checked November 24, 2026 on branch `feat/payout-statement` (from `main` `050b390c`), against the task test database `hafapass_w1_test`.

The promise to Marianas Open: **a bank transfer to the organizer within 2–3 business days after the event, holding about 10% for 30 days, then releasing it.** Buyers pay into Shimizu Technology's Stripe account. HåfaPass records the transfers that finance makes at the bank (#221, #223). Nothing in this change moves money.

## How it was walked

`hafapass_api/spec/requests/api/v1/admin/payout_schedule_lifecycle_spec.rb` drives the whole lifecycle through the real HTTP endpoints, with a fictional event ("Island Open Exhibition", Fictional Grappling League) that ends on **Saturday, January 30, 2027 at 6 p.m. Guam time**, like Copa:

- card sales on two ticket tiers (adult $17, child $12), with verified actual Stripe processing costs;
- a partial refund (two adult tickets, with their buyer fees);
- door cash ($51) recorded through the real box-office cash sale service;
- HåfaPass fees paid by buyers;
- an approved bank account (last four 4321) and the production-style manual payout gateway, which reserves the payout and leaves it `processing` until finance records the transfer.

The spec then moves the clock in Guam time: Jan 30 (sales open), Jan 31 (ended, not yet completed), Feb 2 (hold the reserve, finalize, request, record the transfer), Feb 15 (chargeback inside the window), Mar 1 (release). A second example sends the released reserve minus a smaller chargeback as a second transfer and closes the event as Final. A third covers early release and an open dispute.

## Step by step

| # | Step | Before this change | Now |
|---|---|---|---|
| 1 | Sales (card and cash), partial refund, platform fees recorded | **Works.** The settlement calculator splits card processing, excludes door cash from the payable, and nets refunds. | Unchanged. |
| 2 | Event ends; admin can see it is due and by when | **Gap.** Admin → Payouts listed only payouts that already existed. Nothing showed which events had ended without a transfer, or the 2–3 business day target. | **Added:** Admin → Payouts → **Due**. It lists each ended event, its end date, the earliest and latest transfer dates in Guam business days (weekends and bank holidays skipped), overdue days and the next step. Copa: ends Sat Jan 30, transfer due **Wed Feb 3, 2027**. |
| 3 | Event completed | **Works.** `CompletePastEventsJob` completes it 6 hours after the end. Admin can run it from Maintenance. | Due shows "Mark the event completed" until then. |
| 4 | Hold about 10% reserve | **Gap.** Finance had to work out 10% by hand and type a negative `reserve_hold` balance adjustment. No release date was recorded anywhere. | **Added:** **Hold reserve**. The server works out 10% of the platform-held net proceeds (organizer proceeds minus organizer-borne processing, chargebacks and door cash), rounded half up to the cent. It posts the ordinary `reserve_hold` adjustment and stores the agreed release date on it (`balance_adjustments.reserve_release_on`, immutable once posted), so editing the event later cannot move the release. Admin may enter another amount (audited as overridden). **Finalize without reserve** needs a written reason and records `payout_reserve.skipped` (who, why, which statement version), even when an identical statement was already finalized. It refuses a second hold, an unfinished event, zero proceeds, a non-admin, and any event with a payout already pending, processing, held or paid. Locks: organization then event, both `FOR NO KEY UPDATE`, so it serializes with payout creation and other reserve requests but cannot deadlock with an order completion's audit insert. Multi-connection specs cover both. |
| 5 | Finalize the statement | **Gap for admin.** Only the organizer's Owner or Finance role could finalize, through the organizer API. | **Added:** admin **Finalize statement** calls the same `Settlements::Finalizer`, with all its guards (refunds, disputes, reconciliation, unverified processing fees). |
| 6 | Request the payout (net minus reserve) | **Works, awkwardly.** The admin form needed a typed settlement ID. | Due row shows **Request payout $X**, capped by the organization-wide payout balance exactly as `PayoutCreator` caps it. The bank instruction shown afterwards uses the amount the created payout actually has, including any withholding, or says it is withholding only. It calls the unchanged `POST /admin/payouts` (`PayoutCreator`, idempotency key, withholding guard, payout-method review, locking). |
| 7 | Send at the bank and record the transfer | **Works.** `PayoutReconciler` requires a real transfer reference, a confirmation time and evidence, and rejects full account numbers. | Due row shows **Record transfer** and links to that event's payouts, where the existing dialog records it. |
| 8 | Organizer sees "paid, reserve held until …" | **Gap.** The event finance card showed accounting totals without a release date or a plain status. | **Added:** organizer **Payout statement** (below). Status "Paid — reserve held until Mar 1, 2027". |
| 9 | Chargeback inside the 30-day window | **Works.** A lost dispute is deducted from the event balance directly. Paid out minus reserve leaves the organizer at minus the chargeback until the reserve is released. | Statement and Due show it. "You owe" is decided with the held reserve counted: a refund or chargeback the reserve covers is shown as coming out of the reserve, and the statement shows the balance without the reserve and the reserve itself on separate lines. The statement's consistency check now also catches wording that contradicts the numbers. |
| 10 | Release the reserve after 30 days | **Gap.** Finance had to remember the date and type a positive `reserve_release`. Nothing stopped an early release. | **Added:** Due lists held reserves with their stored release date (30 days after the event's Guam end date when held). Copa: **Mon Mar 1, 2027**. **Release reserve** posts the full held reserve. Early release, decided from the reserve's own date, needs a reason of 10+ characters, which is audited. It refuses while a refund or dispute is open, and refuses tax identifiers in the reason. A midnight-in-Guam spec shows the Guam date decides, not UTC. |
| 11 | Send the remainder (reserve minus chargebacks) | **Works** once finalized again. | Due shows the remainder as a transfer due 3 business days after the day the reserve was actually released (that day is not day one). Released Mon Mar 1, 2027 (Guam History and Chamorro Heritage Day) → due **Thu Mar 4**; released Tue Mar 2 → due **Fri Mar 5**. If chargebacks exceeded the reserve, Due shows "Organizer owes a balance" and the statement says so in plain words. |
| 12 | Final statement | **Gap** (no organizer-readable statement). | **Added:** status **Final**, every line reconciling, plus CSV and print. |

No money bug was found in the existing services. The independent review of the first version (Codex Sol, head `c3d57b30`) found six material issues and two minor ones in the new code, all fixed with regression specs; see the PR comment. The second review (Gemini Neon, head `6b201ad8`) reproduced a deadlock between the statement finalizer or payout creation and an order lifecycle step on the same event. That organization-then-event lock pattern was older than this PR, but the Due screen made it easier to reach. The finalizer, payout reservation and held-payout release now use the same lock mode as the reserve, with two-connection specs (`payout_lock_order_spec.rb`). Every gap was missing visibility or a manual step. The existing guards are unchanged: withholding, payout-method review, the conflict and hold paths, idempotency, and the organization-first lock order.

## Organizer payout statement

`/dashboard/events/:id/statement` (and `?payout=<id>` for one transfer), linked from the event's finance card, the Finances page's event rows and each payout in the history.

- Status: **Sales open**, **Waiting for payout**, **Paid — reserve held until <date>**, **Final**.
- Lines: ticket sales by ticket, discounts, HåfaPass fees the organizer covered, refunds (their share, and what buyers got back), card processing (and what HåfaPass covered), door cash ("you already have this cash, so it is not part of the bank transfer"), chargebacks, other credits and debits, net proceeds, reserve held (amount, about %, release date), reserve released, transfers (date, account ending, bank reference), and balance remaining or "you owe". The key figures say what is still to come, including the held reserve.
- Every line is a regrouping of `Settlements::Calculator`'s own items, and every total is the calculator's. `reconciles` is checked on every response; the page shows a warning instead of hiding a mismatch. The specs call `expect_statement_to_reconcile` for each state.
- Only roles with `view_finance` (Owner, Manager, Finance) can see it. Marketer, Box office and Door scanner get 403, including staff assigned to the event. Another organization's event or another event's payout returns 404.
- CSV: `GET /organizer/events/:id/finance/payout_statement_export`, audited as `finance.exported` (`payout_statement`). Print: the browser's print gives one clean page with no navigation or buttons.

## Evidence

- Backend specs: lifecycle (3), statement math and worst cases (10), Guam business-day calendar (3), reserve rules and concurrency (7, two multi-connection), access (4), review regressions (10).
- Screenshots in this folder: statement with reserve held (390, 1280), refund covered by the reserve (390), final (1280), final with a balance owed (390), worst-case names and $1,000,000.00 (390), print preview (1280), admin Due (390, 1280), and the preview demo (statement 390, Due 1280).
- Chromium only. WebKit does not start on the Mac mini and was not run.

## Residuals

- The holiday list covers Federal Reserve holidays plus Guam's Chamorro Heritage Day, Good Friday, Liberation Day, All Souls' Day and Our Lady of Camarin Day, using the Federal Reserve rule for weekends: a Sunday holiday moves to Monday, and a Saturday holiday adds no day off. Finance should confirm the list against the bank's calendar.
- Stripe's separate dispute fee is not modelled; a lost dispute deducts the disputed amount. If finance passes the fee on, post it as a debit with evidence.
- "Due" is an operating view. It sends no reminders and does not page anyone.
