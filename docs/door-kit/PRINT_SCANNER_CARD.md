# Copa de Marianas 2027 — Door Scanner Card (1-Sheet Print)

**Saturday, Jan 30, 2027 · UOG Calvo Field House** *(Print 1 double-sided copy per scanner lane)*  
*Screens from the Nov 24 builds (PRs #236, #240, #242) — refresh before printing.*

---

## FRONT — Setup, Scanning & Re-entry Rule

### Contacts (fill in before doors open)

- **Door lead:** `[Door lead name / phone]`
- **Backup lead:** `[Backup door lead / phone]`
- **HåfaPass on-call:** `[HåfaPass on-call]`
- **Venue contact:** `[Venue contact]` · **Medical:** `[Medical]`

### 10-Minute Pre-Doors Check

1. Phone 100% charged + battery pack; screen bright; volume up; **Auto-Lock / Screen timeout = Never**.
2. Sign into HåfaPass in Safari or Chrome with **your own** staff login → open **Scanner** → pick **Copa de Marianas**.
3. Check: **Online** · **Waiting to sync: 0** · **Ticket list ready · N tickets** (future Guam expiry). Tap **Sync now**.
4. Tap **Start camera**, allow permission, check **Sound** is on, scan 1 test QR.

### What Every Scan Screen Means

| Color / Screen | Action |
| --- | --- |
| **Green — Admitted** *(clears in ~1 s)* | Welcome **1 person** in. Stamp wrist/hand now if using hand stamps. |
| **Blue — Exited** *(Exit scan mode only)* | Guest checked out; they may re-enter later. |
| **Amber — Check ticket / Already inside / Wait to re-enter** *(stays until tapped)* | **Hold guest.** Tap to dismiss, read the reason below the camera, send to **Door lead**. |
| **Red — Do not admit / Invalid ticket / Re-entry limit reached** *(stays until tapped)* | **Do not admit.** Tap to dismiss, try **Find an attendee**, or send to **Door lead**. |
| **No working QR** | Scroll to **Find an attendee**, search name or `HP-T...`, confirm match, tap **Admit**. |

### Re-entry / Stamp Rule — CHOOSE ONE BEFORE EVENT DAY

> **Circle the active rule for today's shift:**
> - **[ ] OPTION A — EXIT SCAN (in & out):** Keep **ENTRY** selected on incoming lanes. Use **EXIT** only at the exit lane. No hand stamps. **Already inside** stops passback — guest must scan out first or see Door lead.
> - **[ ] OPTION B — HAND STAMP (Re-entry Off):** Scan QR once on first arrival, then stamp hand/wrist. Returning guests show their stamp at the marked re-entry lane (**do not re-scan QR**).
> - **[ ] OPTION C — COOL-DOWN (entry only):** No exit switch; scanner blocks rapid passbacks until wait timer clears.

*Lead override (Door lead only, online):* Dismiss warning/error → tap **Lead override** → choose **Admit (re-entry)** or **Clear inside status** → type required reason → confirm.

---

<div style="page-break-before: always;"></div>

## BACK — Offline Mode, Paper Fallback & End of Night

### Refreshing the Ticket List (Manifest)

- **When:** 15–30 min before doors · at division breaks · after a rush of walk-up sales/refunds · right after coming back online.
- **How:** Confirm **Online** → tap **Sync now**.
- **Is it current?** Check **Ticket list ready · N tickets**, future Guam expiry time, and **Waiting to sync: 0** *(exact version is inside **Device details**)*.

### If Wi-Fi / Signal Drops (Offline Mode)

1. **Keep scanning** while the ticket list is valid. Scans queue locally (**Waiting to sync** rises).
2. **NEVER sign out, switch accounts, clear browser data, or tap Reset trusted device** while **Waiting to sync > 0**.
3. Send confusing duplicates to the **Door lead** (other offline phones cannot see your queue yet).
4. When **Online** returns, tap **Sync now** and wait for **Waiting to sync: 0**.
5. If your ticket list expires offline, pause the lane, keep the browser intact, and move to the Manager Desk backup list.

### Backup Attendee CSV / Paper Fallback (Only When Door Lead Calls It)

1. Look up guest by **Name** or **Order #** (`HP-...`) on the Manager Desk backup CSV / printed door list.
2. **Check Status:** `Valid` / `Paid` = admit. `Checked in`, `Cancelled`, `Refunded`, or `Transferred` = **send to Door lead**.
3. Cross off the row with **time, gate, and your initials**. Log any unexported receipt on the **numbered paper exception log**.
4. **Reconcile later:** When online, check in manually admitted tickets via **Find an attendee** so final counts match. Keep attendee lists private and hand them back to the Door lead.

### End-of-Night Checklist

- [ ] Confirm **Online**, tap **Sync now**, wait until **Waiting to sync: 0**.
- [ ] Door lead reviews **Flagged offline conflicts** and **Recent admissions**.
- [ ] Return printed lists and numbered exception log to Door lead.
- [ ] Wait for Door lead all-clear before signing out; plug phone and battery pack in to charge.

*Full visual phone guide with screenshots:* `docs/door-kit/VOLUNTEER_QUICK_GUIDE.md`
