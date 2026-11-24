# Online door card acceptance

Chromium ran the staff journey at 390 and 1280 px with fictional API fixtures. The screen showed the all-in charge before checkout and kept the same key after a lost response and two reloads. The test cleared session storage to simulate a lost tab, recovered a pending QR from **Open card checkouts**, cancelled that sale, then reopened a paid order and requested its ticket email. The tests also covered staff-keyed checkout, a retryable decline, expiry, and the default-off event.

| State | 390 px | 1280 px |
| --- | --- | --- |
| All-in total before checkout | [Phone](fee-quote-390.png) | [Desktop](fee-quote-1280.png) |
| Open card checkouts after a lost tab | [Phone](open-checkouts-390.png) | [Desktop](open-checkouts-1280.png) |
| Waiting, pay on buyer’s phone | [Phone](waiting-phone-390.png) | [Desktop](waiting-phone-1280.png) |
| Paid, tickets ready | [Phone](paid-390.png) | [Desktop](paid-1280.png) |
| Failed, same checkout can retry | [Phone](failed-390.png) | [Desktop](failed-1280.png) |
| Expired | [Phone](expired-390.png) | [Desktop](expired-1280.png) |

The recovery list and paid fixture include unbroken characters, Japanese text, and emoji. The browser verified that every tested payment state and the recovery list fit the viewport horizontally. The payment-link email action was at least 48 px tall.

Rails used a dedicated test database, mocked Stripe transport, simulated email, and locally signed webhook fixtures. The backend tests covered last-ticket contention with public checkout, cancellation during Stripe setup, delayed confirmation on both sides of the expiry sweep, an exactly-once refund after a replacement sale, seller and manager permissions, and reconciliation of the series CSV channel rows to the combined totals.

Stripe’s hosted form, issuer authentication, physical phones, and WebKit were outside local verification. The deploy preview uses a fictional payment page and reaches paid after a delay. It sends no email or Stripe request.
