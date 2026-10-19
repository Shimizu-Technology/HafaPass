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

// The dashboard already loads the selected organization's permissions. It
// publishes whether Settings is available so the workspace navigation offers
// Settings to exactly the people the dashboard does. Until the dashboard has
// loaded for this account and organization, Settings stays hidden.
let organizationAccess = { authContext: null, organizationId: null, canManageSettings: false }
const accessListeners = new Set()

export function publishOrganizationAccess(authContext, organizationId, canManageSettings) {
  const next = { authContext, organizationId: organizationId == null ? null : String(organizationId), canManageSettings: Boolean(canManageSettings) }
  if (Object.keys(next).every(key => next[key] === organizationAccess[key])) return
  organizationAccess = next
  accessListeners.forEach(listener => listener())
}

const getOrganizationAccess = () => organizationAccess
function subscribeOrganizationAccess(listener) {
  accessListeners.add(listener)
  return () => accessListeners.delete(listener)
}

const selectedOrganization = () => window.localStorage.getItem('hafapass_organization_id')
function subscribeSelectedOrganization(listener) {
  const changed = event => { if ([null, 'hafapass_organization_id'].includes(event.key)) listener() }
  window.addEventListener('storage', changed)
  return () => window.removeEventListener('storage', changed)
}

export function useCanManageOrganizationSettings() {
  const authContext = useSyncExternalStore(subscribeApiAuthContext, getApiAuthContext)
  const access = useSyncExternalStore(subscribeOrganizationAccess, getOrganizationAccess)
  const organizationId = useSyncExternalStore(subscribeSelectedOrganization, selectedOrganization)
  return Boolean(access.canManageSettings && access.authContext === authContext && access.organizationId === organizationId)
}
