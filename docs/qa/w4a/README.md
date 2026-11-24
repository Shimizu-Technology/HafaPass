# Box office ticket delivery

Chromium checked the sale, reload, full-screen QR, print, and email flow with fictional API fixtures. Rails request specs exercised the actual cash sale, pass issuance, permissions, order reload, and fulfillment queue using a local test database. Delivery was simulated.

| View | 390 px | 1280 px |
| --- | --- | --- |
| Completed sale | [Demo data · all names fictional](finish-390.png) | [Demo data · all names fictional](finish-1280.png) |
| Full-screen QR | [Three-night pass, long Japanese and emoji name](qr-390.png) | [Walk-in order with 20 admissions and no buyer details](qr-1280.png) |
| Browser print output, first page | [3-page PDF](print-390.png) | [20-page PDF](print-1280.png) |

Chromium generated Letter PDFs with exactly one page per admission. The browser test verified the print action and that print media shows the tickets without the dashboard. The images show Chromium's printed output. Physical iOS share-sheet printing and printer output remain unverified.
