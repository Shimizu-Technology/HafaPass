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
