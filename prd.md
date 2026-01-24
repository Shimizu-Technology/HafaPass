# HafaPass - Development & Testing PRD

## Overview

This PRD contains tasks for building and testing the HafaPass ticketing platform.
Tasks should be completed in order where dependencies exist.

## Environment Setup

**Before starting Ralph:**
1. Run `./start-autonomous.sh` to start all services
2. Check http://localhost:4040 for ngrok tunnel URLs
3. Set environment variables:
   ```bash
   export BROWSERBASE_API_KEY=your_key
   export BROWSERBASE_PROJECT_ID=your_project_id
   ```

## URL References

- **Local Frontend:** http://localhost:5173
- **Local API:** http://localhost:3000  
- **ngrok URLs:** Check http://localhost:4040/api/tunnels

**For browser testing, use the ngrok HTTPS URLs!**

## Test Data

From seed data:
- **Test User:** test@hafapass.com (organizer)
- **Published Events:** Full Moon Beach Party, Sunset Sessions
- **Event Slug:** full-moon-beach-party

## Tasks

```json
[
  {
    "id": 1,
    "title": "Verify API Health",
    "type": "api",
    "steps": [
      "Curl localhost:3000/api/v1/health to verify API is responding",
      "Verify response contains { status: 'ok' }"
    ],
    "passes": false
  },
  {
    "id": 2,
    "title": "Verify Frontend Build",
    "type": "build",
    "steps": [
      "Run npm run build in hafapass_frontend",
      "Verify build completes without errors",
      "Check dist/ folder is created"
    ],
    "passes": false
  },
  {
    "id": 3,
    "title": "Test Homepage Visual",
    "type": "browser",
    "steps": [
      "Navigate to frontend ngrok URL",
      "Take screenshot of homepage",
      "Verify: navbar, hero section with gradient, footer"
    ],
    "passes": false
  },
  {
    "id": 4,
    "title": "Test Events Page",
    "type": "browser",
    "steps": [
      "Navigate to /events on ngrok URL",
      "Take screenshot",
      "Verify event cards are displayed"
    ],
    "passes": false
  },
  {
    "id": 5,
    "title": "Test Event Detail Page",
    "type": "browser",
    "steps": [
      "Navigate to /events/full-moon-beach-party on ngrok URL",
      "Take screenshot",
      "Verify event title, description, ticket types displayed"
    ],
    "passes": false
  },
  {
    "id": 6,
    "title": "Test Sign In Page",
    "type": "browser",
    "steps": [
      "Navigate to /sign-in on ngrok URL",
      "Take screenshot",
      "Verify Clerk sign-in form is displayed"
    ],
    "passes": false
  },
  {
    "id": 7,
    "title": "Test Mobile Responsiveness",
    "type": "browser",
    "steps": [
      "Set viewport to 375x667",
      "Navigate to homepage",
      "Take screenshot",
      "Verify mobile layout (hamburger menu, stacked content)"
    ],
    "passes": false
  },
  {
    "id": 8,
    "title": "API Events Endpoint",
    "type": "api",
    "steps": [
      "Curl localhost:3000/api/v1/events",
      "Verify JSON response with array of events",
      "Verify each event has: id, title, slug, date, venue"
    ],
    "passes": false
  },
  {
    "id": 9,
    "title": "API Single Event Endpoint",
    "type": "api",
    "steps": [
      "Curl localhost:3000/api/v1/events/full-moon-beach-party",
      "Verify JSON response with event details",
      "Verify includes ticket_types array"
    ],
    "passes": false
  },
  {
    "id": 10,
    "title": "Run RSpec Tests",
    "type": "test",
    "steps": [
      "cd hafapass_api && bundle exec rspec",
      "Verify all tests pass",
      "Document any failures"
    ],
    "passes": false
  },
  {
    "id": 11,
    "title": "Test Dashboard (Protected)",
    "type": "browser",
    "steps": [
      "Navigate to /dashboard on ngrok URL",
      "If redirected to sign-in, document that auth is working",
      "Take screenshot of either dashboard or sign-in redirect"
    ],
    "passes": false
  },
  {
    "id": 12,
    "title": "Final Summary",
    "type": "documentation",
    "steps": [
      "Review all screenshots in screenshots/ folder",
      "Document any issues found in activity.md",
      "List any features that need work",
      "Mark this task as complete"
    ],
    "passes": false
  }
]
```

## Success Criteria

All tasks should have `"passes": true` when complete. Document any issues or blockers in activity.md.
