# HafaPass Visual Testing Session

You are testing the HafaPass application using `agent-browser` to verify all pages render correctly and user flows work as expected.

## Setup

First, read these files:
1. Read `prd.md` to see all testing tasks
2. Read `activity.md` to see what tests have been completed

## Servers

Both servers should already be running:
- **Backend:** Rails API on `localhost:3000`
- **Frontend:** React Vite on `localhost:5173`

If servers aren't running, start them:
```bash
# Terminal 1 - Backend
cd hafapass_api && rails server

# Terminal 2 - Frontend  
cd hafapass_frontend && npm run dev
```

## Testing Workflow

For each task in prd.md where `"passes": false`:

### 1. Navigate to the page
```bash
agent-browser open http://localhost:5173/[route]
```

### 2. Take snapshot to inspect elements
```bash
agent-browser snapshot -i -c
```

### 3. Interact with the page (if needed)
```bash
agent-browser fill @e1 "value"
agent-browser click @e2
agent-browser wait --load networkidle
```

### 4. Take screenshot for verification
```bash
agent-browser screenshot screenshots/test-XX-name.png
```

### 5. Resize for mobile tests
```bash
agent-browser set viewport 375 667   # Mobile
agent-browser set viewport 1280 800  # Desktop
```

## Authentication

Test user credentials (if Clerk is configured):
- **Email:** test-admin@hafameetings.com
- **Password:** HafaMeetings!

To authenticate:
```bash
agent-browser open http://localhost:5173/sign-in
agent-browser snapshot -i
# Find email/password fields and sign in button
agent-browser fill @email "test-admin@hafameetings.com"
agent-browser fill @password "HafaMeetings!"
agent-browser click @submit
agent-browser wait --load networkidle
```

## API Helpers

To get data for testing:
```bash
# Get a valid ticket QR code
curl -s http://localhost:3000/api/v1/events/full-moon-beach-party | python3 -c "import json,sys; print(json.load(sys.stdin))"

# Get ticket for scanner test (need to find one from orders)
cd hafapass_api && rails runner "puts Ticket.first.qr_code"
```

## Logging

After completing each task:
1. Update the task's `"passes"` field to `true` in prd.md
2. Append a dated entry to activity.md with:
   - What was tested
   - Screenshot filename
   - Any issues found
   - Pass/fail status

## Important Notes

- If a page has issues, document them but still mark the test as passed if the screenshot was captured
- Take extra screenshots of interesting states (loading, errors, empty states)
- If Clerk auth isn't working, skip auth-required tests and note in activity.md
- Focus on visual verification - does the page LOOK right?

## Completion

## Additional Commands

For SEO/PWA verification:
```bash
# Check meta tags
curl -s http://localhost:5173/ | grep -E '<title>|<meta'

# Check manifest
curl -s http://localhost:5173/manifest.json | python3 -m json.tool

# Check robots.txt
curl -s http://localhost:5173/robots.txt
```

## Completion

When ALL 45 tasks have `"passes": true`, output:

<promise>COMPLETE</promise>
