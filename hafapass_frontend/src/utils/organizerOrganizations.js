import { useEffect, useSyncExternalStore } from 'react'
import apiClient from '../api/client'

// One `/organizer/organizations` lookup per account, shared by the dashboard
// and the workspace navigation. Results are bound to the auth context they
// were loaded for, so sign-out or an account switch never reuses them.
let cache = { authContext: undefined, organizations: null }
let inFlight = null
const listeners = new Set()

const getCache = () => cache
function subscribe(listener) {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

// Starts a fresh lookup unless one for the same account is already running.
// The shared request is bound to the account only, never to one page's abort
// signal, so callers must check their own request is still current afterwards.
export function loadOrganizerOrganizations(authContext) {
  if (inFlight?.authContext === authContext) return inFlight.promise
  const promise = apiClient.get('/organizer/organizations', authContext ? { authContext } : {}).then(response => {
    const organizations = Array.isArray(response.data) ? response.data : []
    cache = { authContext, organizations }
    listeners.forEach(listener => listener())
    return response
  }).finally(() => { if (inFlight?.promise === promise) inFlight = null })
  inFlight = { authContext, promise }
  return promise
}

// Same rule as the dashboard: the stored organization, otherwise the first one.
export const selectedOrganization = (organizations, organizationId) =>
  organizations.find(item => String(item.id) === organizationId) || organizations[0] || null

export const canManageOrganizationSettings = organization =>
  Boolean(organization?.permissions?.manage_members || organization?.permissions?.manage_payout_settings)

const storedOrganization = () => window.localStorage.getItem('hafapass_organization_id')
function subscribeStoredOrganization(listener) {
  const changed = event => { if ([null, 'hafapass_organization_id'].includes(event.key)) listener() }
  window.addEventListener('storage', changed)
  return () => window.removeEventListener('storage', changed)
}

// Whether the current account may open organization Settings for the selected
// organization. Uses the cached lookup, loading it once when it is missing.
export function useCanManageOrganizationSettings(authContext, enabled) {
  const current = useSyncExternalStore(subscribe, getCache)
  const organizationId = useSyncExternalStore(subscribeStoredOrganization, storedOrganization)
  const loaded = enabled && authContext && current.authContext === authContext
  useEffect(() => {
    if (!enabled || !authContext || loaded) return
    loadOrganizerOrganizations(authContext).catch(() => {})
  }, [enabled, authContext, loaded])
  return Boolean(loaded && canManageOrganizationSettings(selectedOrganization(current.organizations, organizationId)))
}
