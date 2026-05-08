# HafaPass MVP Manual Test Plan

This is the simple human walkthrough for validating the MVP before trusting it with a pilot event.

## Before You Start

Run the app locally:

```bash
cd hafapass_api
rbenv exec bundle exec rails server -p 3000
```

```bash
cd hafapass_frontend
npm run dev
```

Use the test values from `.env` through the app, not by reading the file directly:

- `TEST_BASE_URL` should point to the frontend, usually `http://localhost:5173`.
- `TEST_USER_EMAIL` and `TEST_USER_PASSWORD` should sign into Clerk.

Recommended setup:

- Use Stripe `simulate` mode for the first pass.
- Use Stripe `test` mode for the payment/webhook pass.
- Create at least one published future event with at least two ticket types.

## 1. Public Event Discovery

Expected result: a guest can find and understand an event.

Steps:

1. Open the homepage.
2. Click `Events`.
3. Confirm published upcoming events appear.
4. Use search by event title or venue name.
5. Use category filters.
6. Open an event detail page.
7. Confirm date, time, venue, description, age restriction, and ticket types are readable on desktop and mobile size.

## 2. Guest Checkout in Simulate Mode

Expected result: a guest can buy tickets without signing in, receive completed tickets, and see QR links.

Steps:

1. Open a published event as a signed-out visitor.
2. Select one or more tickets.
3. Continue to checkout.
4. Enter buyer name and email.
5. Apply a valid promo code if one exists.
6. Place the order in simulate mode.
7. Confirm the order confirmation page says tickets are confirmed.
8. Open each ticket link.
9. Confirm each ticket page shows a QR code and correct event/ticket details.

## 3. Signed-In Buyer Flow

Expected result: a signed-in buyer can purchase and later find tickets in `My Tickets`.

Steps:

1. Sign in with Clerk test credentials.
2. Buy tickets for a published event.
3. Open `My Tickets`.
4. Confirm the new tickets appear.
5. Open a ticket from `My Tickets`.
6. Confirm it shows as valid before check-in.

## 4. Stripe Test Payment Flow

Expected result: paid orders do not expose QR codes until payment completes.

Steps:

1. As admin, switch payment mode to `test`.
2. Start checkout for a paid ticket.
3. Confirm the app moves to Stripe payment UI.
4. Complete payment with Stripe test card `4242 4242 4242 4242`.
5. Confirm the immediate confirmation page does not show usable QR tickets if the order is still pending.
6. Confirm the Stripe webhook completes the order.
7. Refresh or revisit the order/ticket area.
8. Confirm QR tickets are available only after completion.

## 5. Organizer Event Management

Expected result: an organizer can manage their own event but not another organizer's event.

Steps:

1. Sign in as an organizer or create an organizer profile.
2. Create a draft event.
3. Add ticket types.
4. Publish the event.
5. Edit event details.
6. Confirm the public event page reflects the changes.
7. Confirm direct URLs to another organizer's event management pages return not found or forbidden.

## 6. Ticket Sale Windows and Inventory

Expected result: backend rules enforce what buyers can purchase.

Steps:

1. Create a ticket type with a future sales start date.
2. Try to buy it from the frontend or direct API path.
3. Confirm purchase is rejected.
4. Create a ticket type with an expired sales end date.
5. Confirm purchase is rejected.
6. Set low inventory, such as one available ticket.
7. Buy the available ticket.
8. Confirm additional purchase attempts fail when sold out.

## 7. Check-In Scanner

Expected result: only the owning organizer or admin can check in tickets.

Steps:

1. Sign in as the organizer who owns the event.
2. Open the scanner page.
3. Scan or manually enter a valid QR code for that organizer's event.
4. Confirm check-in succeeds.
5. Scan the same ticket again.
6. Confirm the app reports already checked in.
7. Sign in as a different organizer.
8. Try the same QR code.
9. Confirm access is rejected.
10. Try to check in a pending/unpaid ticket if available.
11. Confirm it is rejected.

## 8. Promo Codes

Expected result: organizers can create usable promo codes and usage limits are respected.

Steps:

1. Create a percentage promo code.
2. Apply it during checkout.
3. Confirm the discount appears in the order summary.
4. Complete checkout.
5. Confirm usage count increments.
6. Create a code with max uses of one.
7. Use it once.
8. Confirm a second attempt is rejected.

## 9. Guest List

Expected result: organizers can create and redeem comp tickets.

Steps:

1. Open an event's guest list page.
2. Add a guest list entry with name, email, quantity, and ticket type.
3. Redeem the guest entry.
4. Confirm a zero-cost completed order is created.
5. Confirm comp tickets have QR codes.
6. Confirm redeemed guest list entries cannot be edited/deleted unexpectedly.

## 10. Refunds

Expected result: organizers can refund their own completed orders and refunded tickets cannot be used.

Steps:

1. Open an event's refunds page.
2. Select a completed order.
3. Process a partial refund if supported by the current order/payment mode.
4. Process a full refund.
5. Confirm fully refunded tickets are cancelled.
6. Try checking in a cancelled ticket.
7. Confirm check-in is rejected.

## 11. Admin Settings

Expected result: only admins can manage payment mode.

Steps:

1. Sign in as admin.
2. Open dashboard settings.
3. Switch between `simulate` and `test` if keys are configured.
4. Confirm live mode requires live keys and explicit confirmation.
5. Sign in as non-admin.
6. Confirm settings are inaccessible.

## 12. Mobile Smoke Test

Expected result: the critical buyer and scanner flows work on a phone-sized viewport.

Steps:

1. Open homepage on mobile viewport.
2. Browse events.
3. Buy a ticket.
4. View the ticket QR page.
5. Open scanner page on a real mobile browser if possible.
6. Confirm camera permission and manual entry fallback both work.

## Automated Checks

Run these before merging major MVP changes:

```bash
cd hafapass_api
rbenv exec bundle exec rspec
```

```bash
cd hafapass_frontend
npm run lint
npm run build
```

Current expected status after the security hardening work:

- Backend: `163 examples, 0 failures`.
- Frontend lint: no errors or warnings.
- Frontend build: successful.
