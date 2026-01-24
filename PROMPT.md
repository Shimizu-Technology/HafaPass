# HafaPass Autonomous Development & Testing

You are working on the HafaPass ticketing platform. This is an autonomous development loop - complete tasks from `prd.md` without user intervention.

## Setup

1. Read `prd.md` to see all tasks
2. Read `activity.md` to see what has been completed
3. Find the next task where `"passes": false` and complete it

## Environment

The following should already be running (started via `start-autonomous.sh`):

- **Rails API:** Running locally, exposed via ngrok
- **Vite Frontend:** Running locally, exposed via ngrok
- **ngrok Tunnels:** Exposing both services publicly

**Important URLs (check http://localhost:4040 for current ngrok URLs):**
- Local API: `http://localhost:3000`
- Local Frontend: `http://localhost:5173`
- Public URLs: Available via ngrok dashboard at http://localhost:4040

## Browser Testing with Browserbase

You have access to the `browserbase` MCP server for cloud-hosted browser automation. This allows you to:
- Navigate to pages
- Take screenshots
- Interact with elements
- Verify visual appearance

### Using Browserbase MCP Tools

```
# Navigate to a page
mcp__browserbase__navigate { "url": "https://[ngrok-url]/" }

# Take a snapshot (get page structure)
mcp__browserbase__snapshot {}

# Click an element
mcp__browserbase__click { "selector": "#my-button" }

# Type into a field
mcp__browserbase__type { "selector": "#email", "text": "test@example.com" }

# Take a screenshot
mcp__browserbase__screenshot { "path": "screenshots/test-name.png" }
```

**Important:** Use the ngrok public URLs (https://xxx.ngrok.io) for browser testing, NOT localhost!

## For Code/Build Tasks

If the task involves writing code, run tests, or building:

```bash
# Rails commands
cd hafapass_api && bundle exec rails s -p 3000
cd hafapass_api && bundle exec rspec
cd hafapass_api && bundle exec rails db:migrate

# Frontend commands
cd hafapass_frontend && npm run dev
cd hafapass_frontend && npm run build
cd hafapass_frontend && npm test
```

## Authentication (for testing protected routes)

Test user credentials:
- **Email:** test@hafapass.com
- **Password:** TestPass123!

Or use Rails runner for backend auth testing:
```bash
cd hafapass_api && rails runner "puts User.first.inspect"
```

## Task Completion Workflow

For each task:

1. **Read the task** from prd.md
2. **Complete the work** (code, test, or visual verification)
3. **Log to activity.md:**
   ```markdown
   ## [Date] - Task [ID]: [Title]
   - What was done
   - Commands run / files changed
   - Result: PASS/FAIL
   - Screenshot: (if applicable)
   ```
4. **Update prd.md** - set `"passes": true` for the completed task
5. **Move to next task**

## Important Notes

- If ngrok URLs change, check http://localhost:4040/api/tunnels
- For visual tests, take screenshots to `screenshots/` directory
- Document any bugs or issues found in activity.md
- If a task is blocked, document why and move to next task
- Commit meaningful changes with descriptive messages

## Git Workflow

After completing significant work:
```bash
git add -A
git commit -m "feat: [description of changes]"
```

Do NOT push automatically - the user will push after review.

## Completion Signal

When ALL tasks have `"passes": true`, output:

<promise>COMPLETE</promise>
