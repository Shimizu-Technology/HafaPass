# Copa de Marianas 2027 — Box Office Card (1 Double-Sided Letter Sheet)

**Saturday, Jan 30, 2027 · UOG Calvo Field House** *(Print [PRINT_BOX_OFFICE_CARD.html](PRINT_BOX_OFFICE_CARD.html) double-sided on Letter paper — 1 copy per station)*  
*Screens from the Nov 24 builds — refresh before printing.*

---

## FRONT (Page 1) — Ticket Tiers & Cash Sales

### Contacts (fill in before doors open)

- **Door lead:** `[Door lead name / phone]` · **Backup lead:** `[Backup door lead / phone]`
- **HåfaPass on-call:** `[HåfaPass on-call]` · **Venue:** `[Venue contact]` · **Medical:** `[Medical]`

### Spectator Ticket Tiers

- **Adult Spectator:** **$17**
- **Child / Youth Spectator:** **$12**
- **Child Under 5:** **$0.00 (Free)** — **always tap `+` to issue a free Under-5 ticket** so arena capacity and door counts stay accurate.
- **Child / Under 5 age: ask the Door lead, don't guess.**

### Payment Methods at Copa

> **Card at Door is OFF — use Cash or the two pay-by-card options below.**  
> Greyed-out **Card at Door** is for a separate card reader that is not active. Do not use it, and **never** record a card payment by hand or as Cash.

### Cash Sale

1. Open **Dashboard → Copa de Marianas → Box office**.
2. Tap **`+` / `−`** for Adult, Child, and Under 5 tickets. *(Optional: enter buyer name & email.)*
3. **Collect and count the cash first.**
4. Select **Cash** → tap **Process sale · $XX.XX**.
5. On the green **Sale complete!** card, deliver the tickets:
   - **Show QR:** Full-screen QR per ticket (`Ticket 1 of N`) for the buyer to photograph.
   - **Print tickets:** Prints **one QR per page** from the browser.
   - **Email tickets:** Enter/confirm buyer email → tap **Send tickets**.
6. *Reloaded by mistake?* Refreshing the **same tab** brings back the last completed cash sale.
7. *Network dropped mid-sale?* If you see **"A saved sale needs confirmation"**, tap **Retry saved sale** — never ring up a second sale.

---

## BACK (Page 2) — Pay by Card, Recovery & End of Night

### Pay by Card (only when enabled for Copa)

1. Select tickets and check the total shown under **Payment method** (includes the online service fee).
2. Choose one option:
   - **Pay on buyer’s phone** *(default)*: Tap **Prepare Stripe checkout** → let buyer scan **Scan to pay** QR (or tap **Email payment link** if email entered).
   - **Enter card on this device** *(**Door lead only / last resort** when buyer cannot pay on their own phone; **never write down a card number or repeat it aloud**)*: Tap **Prepare Stripe checkout** → **Open Stripe checkout** → enter card on Stripe's payment page → return to HåfaPass.
3. Tickets hold for **35 minutes**. Tap **Cancel sale** right away if the buyer walks away before paying.
4. Wait for **Paid — tickets ready**, show the ticket QR(s) (or tap **Email tickets**), then tap **Start next sale**.

### Card Recovery Rules

| Situation | What to do |
| --- | --- |
| **Tab closed / buyer stepped aside** | Tap **Open card checkouts** at the top of Box office → reopen that order (`Show payment QR`, `Open checkout`, or `Show tickets`). **Never start a duplicate sale.** |
| **Paid — waiting for confirmation** | **Tell the buyer:** *"Your payment went through; your tickets will appear in a moment."* **STOP — do NOT charge again and do NOT enter Cash.** Tap **Check payment status** until **Paid — tickets ready** appears. Call **Door lead / HåfaPass on-call** if stuck ~2 min *(confirm wait time with on-call)*. |
| **Failed (declined)** | Buyer can retry on the **same checkout**, or tap **Cancel sale**. |
| **Expired** | Tap **Check payment status** first to make sure Stripe did not capture late before collecting another payment. |

### Pre-Doors Check (finish 15–30 min before doors open)

- [ ] Starting cash float counted with Door lead; small bills ready.
- [ ] Signed into your own HåfaPass account; **Box office** open on Copa event.
- [ ] Confirmed whether pay-by-card options are live; printer paper/battery tested (if printing).

### End-of-Night Cash & Card Count (Two People)

- [ ] Tap **Open card checkouts** — verify **zero** orders stuck in `Waiting for payment…` or `Paid — waiting for confirmation`.
- [ ] Count physical cash minus starting float: **`$__________`**
- [ ] Copy totals from **Box office → Door sales summary**:
  - **Cash:** `$__________` *(difference, if any: `$______`)*
  - **Card (reader):** `$__________` *(should be **$0** unless the Door lead says otherwise)*
  - **Phone checkout:** `$__________` · **Staff-keyed checkout:** `$__________` · **Total revenue:** `$__________`
- [ ] Hand cash, variance note, and logs to Door lead; plug phone/tablet/printer in to charge.

*Full phone guide with screenshots:* `docs/door-kit/VOLUNTEER_QUICK_GUIDE.md`
