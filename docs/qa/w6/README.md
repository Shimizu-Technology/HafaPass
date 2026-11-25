# W6 email screens: QA evidence (Nov 24, 2026)

Chromium, demo preview data (`VITE_HAFAPASS_DEMO_DATA=1`), 390 × 844 and 1280 × 900. Each image is a contact sheet; the steps read left to right. Refreshed after review rounds 1 and 2 (the "after", "review-fixes" and "worst" sheets). Some full-page shots show the sticky navbar mid-page. That is a capture artifact, not a layout bug.

| File | What it shows |
|---|---|
| `before-390.png`, `before-1280.png` | The #233 screens before this change: audience, preview, test and history, organizer page |
| `after-390-compose.png`, `after-1280-compose.png` | Audience → Write → Preview and test (desktop view at its real 600 px width, shrunk to fit on phones; after a test is queued) → Phone preview (375 px) |
| `after-390-send-history.png`, `after-1280-send-history.png` | Confirm dialog → "on its way" → History → History detail → Organizer audience step |
| `review-fixes-390.png`, `review-fixes-1280.png` | Review rounds 1–2: a scheduled time under a minute away when confirming (focus starts on "Pick a new time") → History with "Not delivered" (all suppressed or failed, labeled "Started", not "Sent") and "Partly sent" outcomes (including 1 delivered + 9 bounced) → a "Starting" send past its time that the server still lets you cancel |
| `worst-390.png`, `worst-1280.png` | 48,000 recipients with a long name/email expanded → 240-character emoji + Japanese subject in the confirm dialog → 200-item history (newest 100 listed, a send in progress, a failed send) → no signups yet → organizer waitlist with 0 eligible → exactly 1 recipient |

Worst-case scenarios load with `?demo_email=worst|empty|one|huge` on `/dashboard/email` (add `scope=platform` for the admin event-alerts list).
