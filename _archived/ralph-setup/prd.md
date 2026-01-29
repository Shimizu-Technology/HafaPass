# HafaPass - Ralph Browserbase Test PRD

## Overview

Simple 3-task test to verify Ralph can use Browserbase for autonomous visual testing.

## Prerequisites

1. ngrok running: Check `.ngrok-url` for the public URL
2. Frontend server running on localhost:5173
3. Environment variables set in `.env`

## How Ralph Should Test

Use the `test-browserbase-hafapass.mjs` script:
```bash
source .env && node test-browserbase-hafapass.mjs "$(cat .ngrok-url)"
```

Or for specific pages:
```bash
source .env && node test-browserbase-hafapass.mjs "$(cat .ngrok-url)/events"
```

## Tasks

```json
[
  {
    "id": 1,
    "title": "Test Homepage",
    "type": "browser",
    "steps": [
      "Read the ngrok URL from .ngrok-url file",
      "Run: source .env && node test-browserbase-hafapass.mjs \"$(cat .ngrok-url)\"",
      "Verify screenshots were saved to screenshots/",
      "Check output shows: Page title contains 'HafaPass', Navbar: ✅, Footer: ✅"
    ],
    "expected": "Desktop and mobile screenshots of homepage saved",
    "passes": true
  },
  {
    "id": 2,
    "title": "Test Events Page",
    "type": "browser",
    "steps": [
      "Run: source .env && node test-browserbase-hafapass.mjs \"$(cat .ngrok-url)/events\"",
      "Verify the page loads (may show 'loading' or 'no events' since API isn't tunneled)",
      "Rename screenshots to events-desktop.png and events-mobile.png"
    ],
    "expected": "Events page renders, even if no data loads",
    "passes": true
  },
  {
    "id": 3,
    "title": "Test Sign In Page",
    "type": "browser",
    "steps": [
      "Run: source .env && node test-browserbase-hafapass.mjs \"$(cat .ngrok-url)/sign-in\"",
      "Verify Clerk sign-in component renders",
      "Rename screenshots to signin-desktop.png and signin-mobile.png"
    ],
    "expected": "Sign-in page with Clerk form visible",
    "passes": true
  }
]
```

## Completion

When all 3 tasks pass, output:

<promise>COMPLETE</promise>

## Notes

- Each Browserbase session has a 5-minute limit on free tier
- The script handles ngrok interstitial bypass automatically
- API calls will fail (not tunneled) - that's expected, focus on UI rendering
