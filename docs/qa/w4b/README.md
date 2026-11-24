# Online door card acceptance

Chromium ran the staff journey at 390 and 1280 px with fictional API fixtures. The screen kept the same checkout key through a lost response and two reloads. It displayed the phone QR, queued the payment link once, offered the Stripe-hosted form in the keyed mode, showed only the payment QR while waiting, and displayed an admission QR after a paid response. The flow also checked a retryable decline, expiry, early cancellation, and the default-off event. The screenshots use demo data and fictional names.

| State | 390 px | 1280 px |
| --- | --- | --- |
| Waiting, pay on buyer’s phone | [Phone](waiting-phone-390.png) | [Desktop](waiting-phone-1280.png) |
| Waiting, staff keys the card | [Phone](waiting-keyed-390.png) | [Desktop](waiting-keyed-1280.png) |
| Paid, tickets ready | [Phone](paid-390.png) | [Desktop](paid-1280.png) |
| Failed, same checkout can retry | [Phone](failed-390.png) | [Desktop](failed-1280.png) |
| Expired | [Phone](expired-390.png) | [Desktop](expired-1280.png) |
| Cancelled | [Phone](cancelled-390.png) | [Desktop](cancelled-1280.png) |

The long tier name in the paid fixture includes unbroken characters, Japanese text, and emoji. The browser verified no horizontal overflow in each state and a 48 px email action.

Rails used a dedicated test database, mocked Stripe transport, simulated email, and locally signed test webhook fixtures. The concurrency spec held the last ticket while Stripe setup was blocked, then verified that an online buyer was refused and that concurrent same-key retries produced a single provider setup. The suite also covered expiry, late refunds, role and seller boundaries, duplicate and out-of-order webhooks, and settlement and export classification.

Stripe’s hosted form, issuer authentication, physical phones, and WebKit were outside local verification. The deploy preview uses a fictional payment page and reaches paid after a delay. It sends no email or Stripe request.
