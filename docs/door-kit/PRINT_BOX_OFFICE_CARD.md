# Copa de Marianas 2027 — Box Office Card (1-Sheet Print)

**Saturday, Jan 30, 2027 · UOG Calvo Field House** *(Print 1 double-sided copy per box-office station)*  
*Screens from the Nov 24 builds (PRs #236, #240, #242) — refresh before printing.*

---

## FRONT — Ticket Tiers & Cash Sales

### Contacts (fill in before doors open)

- **Door lead:** `[Door lead name / phone]`
- **Backup lead:** `[Backup door lead / phone]`
- **HåfaPass on-call:** `[HåfaPass on-call]`
- **Venue contact:** `[Venue contact]` · **Medical:** `[Medical]`

### Spectator Ticket Tiers

- **Adult Spectator:** **$17**
- **Child / Youth Spectator:** **$12** *(confirm exact age cutoff with organizer before doors)*
- **Child Under 5:** **$0.00 (Free)** — **always add a free Under-5 ticket** (`+`) so arena capacity and door counts stay accurate.

### Cash Sale (PR #236)

1. Open **Dashboard → Copa de Marianas → Box office**.
2. Tap **`+` / `−`** for Adult, Child, and Under 5 tickets. *(Optional: enter buyer name & email.)*
3. **Collect and count the cash first.**
4. Select **Cash** → tap **Process sale · $XX.XX**.
5. On the green **Sale complete!** card, give the buyer their tickets:
   - **Show QR:** Full-screen QR per ticket (`Ticket 1 of N`) for the buyer to photograph.
   - **Print tickets:** Prints **one QR per page** from the browser.
   - **Email tickets:** Enter/confirm buyer email → tap **Send tickets**.
6. *Reloaded by mistake?* Refreshing the **same tab** brings back the last completed cash sale.

### Important Cash Rules

- **Never record a card payment as Cash.**
- If the network drops mid-cash-sale and you see **"A saved sale needs confirmation"**, tap **Retry saved sale** — do **not** ring up a second sale.

---

<div style="page-break-before: always;"></div>

## BACK — Stripe Card Sales, Recovery & End of Night

### Stripe Card Sale (PR #240 — only when enabled for the event)

1. Select tickets and show the buyer the **all-in total** displayed under **Payment method** (includes online service fee).
2. Pick one payment option:
   - **Pay on buyer’s phone** *(preferred)*: Tap **Prepare Stripe checkout** → let buyer scan **Scan to pay** QR (or tap **Email payment link** if email entered).
   - **Enter card on this device** *(staff-keyed)*: Tap **Prepare Stripe checkout** → tap **Open Stripe checkout** → enter card on Stripe → return to HåfaPass.
3. Tickets are held for **35 minutes**. Tap **Cancel sale** right away if the buyer walks away before paying.
4. Wait for **Paid — tickets ready**, then show the ticket QR(s) (or tap **Email tickets**) and tap **Start next sale**.

### Card Recovery Rules — READ CAREFULLY

| Situation | What to do |
| --- | --- |
| **Tab closed / buyer walked aside** | Tap **Open card checkouts** at the top of Box office → reopen the buyer's order (`Show payment QR`, `Open checkout`, or `Show tickets`). **Never start a duplicate sale.** |
| **Paid — waiting for confirmation** | **STOP. Do NOT charge again and do NOT enter Cash.** Wait a few seconds and tap **Check payment status** until **Paid — tickets ready** appears. Call **Door lead / HåfaPass on-call** if stuck > 2 min. |
| **Failed (declined)** | Buyer can retry on the **same checkout**, or tap **Cancel sale**. |
| **Expired** | Tap **Check payment status** first to verify Stripe did not capture late before collecting another payment. |

### 10-Minute Pre-Doors Check

- [ ] Starting cash float counted and verified with Door lead; small bills ready.
- [ ] Signed into your own HåfaPass account; **Box office** open on Copa event.
- [ ] Checked whether Stripe card options (`Pay on buyer’s phone` / `Enter card on this device`) are live.
- [ ] Printer paper/battery tested (if printing tickets).

### End-of-Night Cash & Card Count (Two People)

- [ ] Open **Open card checkouts** — verify **zero** orders stuck in `Waiting for payment…` or `Paid — waiting for confirmation`.
- [ ] Count physical cash minus starting float: **`$__________`**
- [ ] Copy totals from **Box office → Door sales summary**:
  - **Cash:** `$__________` *(variance, if any: `$______`)*
  - **Card (Clover, if used):** `$__________`
  - **Phone checkout (Stripe QR):** `$__________`
  - **Staff-keyed checkout (Stripe):** `$__________`
  - **Total revenue:** `$__________`
- [ ] Hand cash, variance note, and any paper logs to Door lead; plug tablet/phone/printer in to charge.

*Full visual phone guide with screenshots:* `docs/door-kit/VOLUNTEER_QUICK_GUIDE.md`
