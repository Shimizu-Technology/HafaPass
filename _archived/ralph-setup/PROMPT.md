# Ralph Browserbase Test

You are testing HafaPass using Browserbase cloud browsers.

## Setup

1. Read `prd.md` to see the 3 test tasks
2. Read `activity.md` to see what's been completed
3. The ngrok URL is in `.ngrok-url`

## How to Take Screenshots

Use the provided script:

```bash
source .env && node test-browserbase-hafapass.mjs "$(cat .ngrok-url)"
```

For a specific page:
```bash
source .env && node test-browserbase-hafapass.mjs "$(cat .ngrok-url)/events"
```

The script will:
- Create a Browserbase cloud browser session
- Navigate to the URL
- Take desktop screenshot (1280x800)
- Take mobile screenshot (375x667)
- Save to `screenshots/` folder

## Task Workflow

For each task in prd.md:

1. Run the screenshot command
2. Check the output for success indicators
3. Log the result in activity.md:
   ```markdown
   ## Task [ID]: [Title]
   - Command: [what you ran]
   - Result: PASS/FAIL
   - Screenshots: [filenames]
   - Notes: [any issues]
   ```
4. Update prd.md to set `"passes": true`

## Important Notes

- The API is NOT tunneled, so data won't load - that's OK
- Focus on whether the UI renders correctly
- Each session has a 5-minute limit
- If a session times out, just run the command again

## Completion

When all 3 tasks have `"passes": true`, output:

<promise>COMPLETE</promise>
