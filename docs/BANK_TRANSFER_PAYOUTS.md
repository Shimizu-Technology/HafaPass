# Bank-transfer payouts and reserves

This is the finance workflow for Copa and FD under Leon's November 24
decision. Shimizu collects ticket payments into its Stripe account. Finance
executes transfers outside HåfaPass through Shimizu's bank. HåfaPass reserves
the payable amount, records confirmed transfers and shows the statements.

1. The organizer chooses **Bank transfer** in **Settings → Payouts**. Saving
   the destination selects it. For an organizer switching from an approved
   check, set up and approve the bank account before their next sales window.
   Finance verifies the recipient and details through the approved secure
   process and approves the payout method with the certified W-9. An approved
   check can still be selected.
2. After the event or finals, complete the event and resolve refunds, disputes
   and pending reconciliation. Compare seller cash, proceeds and platform-held
   funds in the event's **Finances** statement. Round the approximately 10%
   reserve to whole cents against the payable amount. In **Admin → Payouts →
   Balance adjustments**, post one negative `reserve_hold` for the event with
   a private evidence reference. Finalize a statement that shows the reserve.
3. Request the available payout against that statement. Within 2–3 business
   days, send the net disbursement to the approved account and confirm it
   against the bank record. Reconcile the payout as **Paid** with the actual
   transfer reference, confirmation time and evidence. Keep the bank receipt
   and full account details in restricted storage. The payout's processing
   status by itself is a ledger reservation.
4. After 30 days, compare the original hold and every adjustment with open
   liabilities and the bank records. Verify the amount and log prior releases
   before posting a positive `reserve_release` for the event. Re-finalize
   the statement, transfer the available remainder and record it using a
   distinct bank reference. Investigate a negative balance before sending
   money. Download the ledger statement and payout history for the organizer.

If a transfer confirmation is ambiguous, look up the existing bank reference
and HåfaPass payout before changing its status or sending any further money.
Updates to bank details require a new approval, and an in-progress payout
blocks edits or destination changes until reconciled.

## Admin → Payouts → Due

The **Due** tab lists every ended event that still needs its transfer, and every held reserve, with due dates in the event's calendar (Guam by default). Business days skip weekends and bank holidays (`PayoutCalendar`). Each row offers the next step:

1. **Hold reserve** posts the standard `reserve_hold`: 10% of the platform-held net proceeds, rounded half up, with the release date (30 days after the event) stored on the hold; later edits to the event do not move it. You can enter another amount, or choose **Finalize without reserve** with a written reason (audited as `payout_reserve.skipped`). A reserve cannot be held once any payout for the event is pending, processing, held or paid.
2. **Finalize statement** runs the same finalizer as the organizer screen.
3. **Request payout** creates the payout from the current version (`POST /api/v1/admin/payouts`), capped by the organization-wide balance. Send exactly the amount the confirmation shows (it accounts for withholding; a withholding-only payout sends nothing), then **Record transfer** in the event's payouts with the bank reference.
4. On the release date, **Release reserve** posts the full held reserve. Before that date it needs a written reason. It is refused while a refund or dispute is open. A chargeback in the window has already reduced the balance, so finalize and send what remains (due 3 business days after the day you release it). If chargebacks exceeded the reserve, the row shows the amount the organizer owes.

The organizer sees the same numbers on **Payout statement** (event finances → View payout statement), which can be printed or downloaded as CSV. See [the lifecycle check](./qa/payout-statement/lifecycle.md).

