import { useSyncExternalStore } from 'react'
import { getApiAuthContext, subscribeApiAuthContext } from '../api/client'

// Organizer, admin and support routes share the workspace shell instead of the
// public buyer navigation and marketing footer.
export const isWorkspacePath = pathname => /^\/(dashboard|admin|support)(?:\/|$)/.test(pathname)

// Shared widths for organizer, admin and support pages: `standard` for lists
// and consoles, `form` for single-column forms and notices.
export const WORKSPACE_WIDTHS = {
  standard: 'max-w-6xl',
  form: 'max-w-3xl',
}

// The navbar already performs the account-bound `/me` lookup. It publishes the
// result here so workspace pages can show role-gated links without a second
// lookup. Readers must compare the stored auth context with the current one.
let accountRole = { authContext: null, role: null }
const listeners = new Set()

export function publishAccountRole(authContext, role) {
  if (accountRole.authContext === authContext && accountRole.role === role) return
  accountRole = { authContext, role }
  listeners.forEach(listener => listener())
}

export const getAccountRole = () => accountRole

export function subscribeAccountRole(listener) {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

// Returns the platform role only while it belongs to the current auth context.
export function useAccountRole() {
  const authContext = useSyncExternalStore(subscribeApiAuthContext, getApiAuthContext)
  const stored = useSyncExternalStore(subscribeAccountRole, getAccountRole)
  return authContext && stored.authContext === authContext ? stored.role : null
}

