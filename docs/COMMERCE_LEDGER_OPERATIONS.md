# Commerce Ledger Migration and Operations

## Purpose

Phase 2 makes local commerce records authoritative and auditable. Orders remain buyer-facing aggregates, while immutable order items, fee components, payment events, webhook receipts, refund allocations, and inventory holds preserve the history needed to reconcile money and inventory.

## Deployment sequence

1. Take and verify a database backup before the migration window.
2. Put checkout and organizer refund writes into maintenance mode while the structural migration and backfill run.
   Before migrating, confirm `organizer_profiles.user_id` has no duplicates; the migration makes that ownership one-to-one.
3. Deploy the API migration. It adds new tables and constraints, then snapshots existing ticket-backed orders into ledger rows.
4. Review the migration output and run the reconciliation commands below before reopening writes.
5. Start exactly one `clock` process alongside `web` and `worker`. It enqueues hold expiry every minute; the expiry operation itself is idempotent.
6. Reopen checkout only after web, worker, clock, database, and Redis are healthy.
7. Keep the backup until the post-deploy reconciliation and pilot smoke matrix are signed off.

Do not roll the data back by deleting ledger rows. If application code must be rolled back, leave the additive tables in place and deploy a forward fix. Financial history uses compensating records, not destructive reversal.

## Backfill rules

- Existing tickets are grouped by order, ticket type, and historical pricing tier.
- Names, unit prices, quantities, discounts, fees, and organizer proceeds are copied into immutable order items.
- Existing Stripe intent and refund identifiers become payment/refund ledger rows.
- Existing promo discounts become finalized, reserved, or released redemption rows based on order state.
- Pending legacy tickets become active ten-minute holds and are removed from sold counters so inventory is not counted twice.
- Orders without enough legacy detail are not guessed during webhook processing; they produce an open reconciliation exception for manual review.

## Reconciliation checks

Run these after migration and after any payment incident:

```bash
bundle exec rails runner 'puts({orders: Order.count, itemized_orders: Order.joins(:order_items).distinct.count, open_reconciliation: ReconciliationException.open.count}.to_json)'
bundle exec rails runner 'puts Commerce::LedgerTotals.call(Order.where(status: [:completed, :partially_refunded, :refunded])).to_json'
bundle exec rails runner 'puts({active_holds: InventoryHold.current.sum(:quantity), expired_holds: InventoryHold.due.count}.to_json)'
```

The release gate is zero unexplained reconciliation exceptions, no negative database-constrained money or inventory values, and exact agreement between Stripe test activity and the admin ledger.

## Operational behavior

- A checkout hold lasts ten minutes.
- `ExpireInventoryHoldsJob` releases inventory and promo reservations idempotently.
- A provider success with the wrong amount/currency, after cancellation, or after expiry opens reconciliation and does not issue tickets.
- Duplicate webhook IDs return the previously stored receipt and do not repeat fulfillment.
- All provider calls use stable idempotency keys.
- Multiple refunds append records and allocations; aggregate compatibility columns are derived forward for existing UI/email consumers.
- Organizer refund requests require a stable `Idempotency-Key` header. Reuse the same key when retrying an uncertain request; generate a new key only for a genuinely new refund.
- Active Job defers record-dependent messages until the surrounding database transaction commits, preventing workers from racing uncommitted orders and tickets.

Alert immediately when the clock or worker is absent, hold-expiry lag exceeds two minutes, webhook failures repeat, or an open reconciliation exception is created.
