// Installs the fictional demo staff identity. Only imported behind the literal
// `import.meta.env.VITE_HAFAPASS_DEMO_DATA === '1'` check, so production builds
// never contain it. It stands in for Clerk: no real sign-in, no real token.
import { setAuthTokenGetter } from '../../api/client'
import { SCANNER_OWNER_KEY } from '../../utils/scannerAccountBinding'
import { DEMO_ORG_ID, DEMO_STAFF_CLERK_ID, DEMO_STAFF_SESSION_ID } from './fixtures'

export function installDemoStaffSession() {
  try {
    window.localStorage.setItem(SCANNER_OWNER_KEY, DEMO_STAFF_CLERK_ID)
    window.localStorage.setItem('hafapass_organization_id', String(DEMO_ORG_ID))
  } catch { /* The preview still opens; staff screens may ask to choose an organization. */ }
  return setAuthTokenGetter(async () => 'demo-staff-token', {
    userId: DEMO_STAFF_CLERK_ID, sessionId: DEMO_STAFF_SESSION_ID, ready: true,
  })
}
