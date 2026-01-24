# HafaPass - Claude Code Instructions

## Test Credentials

Use the credentials from the `.env` file for authentication testing:
- `TEST_USER_EMAIL` - Clerk test user email
- `TEST_USER_PASSWORD` - Clerk test user password
- `TEST_BASE_URL` - Frontend URL (http://localhost:5173)

When doing any validation with agent-browser, use Clerk authentication with these credentials.

## Environment Variables

You have access to these environment variables (defined in `.env`):
- `TEST_USER_EMAIL`, `TEST_USER_PASSWORD`, `TEST_BASE_URL`
- `CLERK_PUBLISHABLE_KEY`, `CLERK_SECRET_KEY`

You don't have permission to read the `.env` file directly, but you can use these values in code you generate and copy them into any `.env` files needed in subprojects.

## Project Structure

- **Backend:** `hafapass_api/` - Rails API on `localhost:3000`
- **Frontend:** `hafapass_frontend/` - Vite React on `localhost:5173`

## Key Commands

```bash
# Backend
cd hafapass_api
rails server

# Frontend
cd hafapass_frontend
npm run dev
```
