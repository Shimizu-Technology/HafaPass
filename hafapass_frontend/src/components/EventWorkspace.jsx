import { useCallback, useEffect, useRef, useState } from 'react'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import { CalendarDays, MapPin, PanelLeftClose, PanelLeftOpen, Menu, X } from 'lucide-react'
import apiClient from '../api/client'
import Dialog from './Dialog'
import useDraftProtection from '../hooks/useDraftProtection'
import useLaunchCapabilities from '../hooks/useLaunchCapabilities'
import { useOrganizerIdentity, useOrganizerRequests } from '../hooks/useOrganizerContext'
import { formatEventDateTime } from '../utils/eventTime'
import { WORKSPACE_WIDTHS } from '../utils/workspace'
import { loadOrganizerOrganizations } from '../utils/organizerOrganizations'
import { navigationFor } from '../utils/eventWorkspaceNavigation'

const preferenceKey = 'hafapass:event-workspace:collapsed'
const readPreference = () => { try { return window.localStorage.getItem(preferenceKey) === 'true' } catch { return false } }
const roleLabels = { owner: 'Owner', manager: 'Manager', finance: 'Finance', marketer: 'Marketing', box_office: 'Box office', scanner: 'Door scanner' }
// Mirrors OrganizationAuthorization::PERMISSIONS (hafapass_api/app/services). Event staff assignments can grant more than the
// organization role; then the header names the event access instead.
const eventRolePermissions = {
  owner: ['manage_organization', 'manage_members', 'manage_payout_settings', 'view_events', 'manage_events', 'edit_event_content', 'manage_inventory', 'manage_staff', 'view_attendees', 'manage_attendees', 'manage_marketing', 'box_office', 'scan', 'view_finance', 'manage_finance', 'refund', 'payout'],
  manager: ['view_events', 'manage_events', 'edit_event_content', 'manage_inventory', 'manage_staff', 'view_attendees', 'view_finance', 'manage_attendees', 'manage_marketing', 'box_office', 'scan'],
  finance: ['view_events', 'view_finance', 'manage_finance', 'refund', 'payout'],
  marketer: ['view_events', 'edit_event_content', 'manage_marketing'],
  box_office: ['view_events', 'view_attendees', 'manage_attendees', 'box_office', 'scan'],
  scanner: ['view_events', 'scan'],
}
const assignmentRoles = ['manager', 'box_office', 'scanner']
function accessSummary(role, permissions = {}, hasTools) {
  const granted = Object.keys(permissions).filter(key => permissions[key] === true)
  const roleGrants = eventRolePermissions[role]
  if (!roleGrants) return hasTools ? 'You can work on parts of this event' : 'No event tools available'
  if (granted.every(key => roleGrants.includes(key))) return `Organization role: ${roleLabels[role]}`
  // Only an assignment can add access beyond the role; name the broadest one granted.
  const assigned = assignmentRoles.find(candidate => eventRolePermissions[candidate].every(key => permissions[key] === true))
  if (assigned) return `Event access: ${roleLabels[assigned]}`
  return hasTools ? 'You can work on parts of this event' : 'No event tools available'
}
const statusLabels = { draft: 'Draft', published: 'Published', postponed: 'Postponed', cancelled: 'Cancelled', completed: 'Completed', archived: 'Archived' }

function WorkspaceLinks({ groups, collapsed = false, onNavigate, location }) {
  return <nav aria-label="Event workspace">
    <div className="space-y-5">
      {groups.map(group => <div key={group.label}>
        {!collapsed && group.label !== group.links[0].label && <p className="mb-1 px-3 text-xs font-semibold text-neutral-600">{group.label}</p>}
        <ul className="space-y-1">
          {group.links.map(link => {
            const target = new URL(link.to, 'https://hafapass.invalid')
            const active = location.pathname === target.pathname && (target.hash ? location.hash === target.hash : !location.hash)
            return <li key={link.to}><Link to={link.to} onClick={event => onNavigate?.(event, link.to)} aria-current={active ? 'page' : undefined}
              aria-label={collapsed ? link.label : undefined} title={collapsed ? link.label : undefined}
              className={`group relative flex min-h-11 items-center rounded-lg text-sm font-medium transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand-700 ${collapsed ? 'justify-center px-2' : 'gap-2 px-3'} ${active ? 'bg-brand-50 text-brand-800' : 'text-neutral-700 hover:bg-neutral-100'}`}>
              <group.icon aria-hidden="true" className="h-4 w-4 shrink-0" />
              {!collapsed && <span>{link.label}</span>}
              {collapsed && <span className="pointer-events-none absolute left-full z-40 ml-3 whitespace-nowrap rounded-lg bg-neutral-950 px-3 py-2 text-xs text-white opacity-0 group-hover:opacity-100 group-focus-visible:opacity-100">{link.label}</span>}
            </Link></li>
          })}
        </ul>
      </div>)}
    </div>
  </nav>
}

function MobileNavigation({ groups, location, onClose, onNavigate }) {
  const ref = useRef(null)
  useEffect(() => {
    const dialog = ref.current
    const previous = document.activeElement
    // StrictMode closes and reopens during effect verification. A native close
    // event from that cleanup must not dismiss the newly reopened drawer.
    dialog.showModal()
    return () => { if (dialog.open) dialog.close(); if (previous?.isConnected) previous.focus() }
  }, [])
  return <dialog ref={ref} aria-label="Event navigation" onCancel={onClose}
    onClick={event => {
      if (event.target !== ref.current) return
      const bounds = ref.current.getBoundingClientRect()
      if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) onClose()
    }}
    className="fixed inset-y-0 left-0 m-0 h-dvh max-h-none w-[min(88vw,20rem)] max-w-none overflow-y-auto border-0 bg-white p-4 backdrop:bg-black/40">
    <button type="button" onClick={onClose} className="mb-4 flex min-h-11 items-center gap-2 rounded-lg px-3 font-medium text-neutral-800"><X className="h-4 w-4" aria-hidden="true" />Close event navigation</button>
    <WorkspaceLinks groups={groups} location={location} onNavigate={onNavigate} />
  </dialog>
}

function WorkspaceSession({ suppliedEvent, eventId, identity, children, location, hasUnsavedChanges }) {
  const navigate = useNavigate()
  const loadEvent = suppliedEvent === undefined
  const { current, beginRequest } = useOrganizerRequests(identity, location.pathname)
  const capabilities = useLaunchCapabilities()
  const [loadedEvent, setLoadedEvent] = useState(null)
  const [organization, setOrganization] = useState(null)
  const [error, setError] = useState(null)
  const [attempt, setAttempt] = useState(0)
  const [collapsed, setCollapsed] = useState(readPreference)
  const [pendingNavigation, setPendingNavigation] = useState(null)
  const [mobileOpen, setMobileOpen] = useState(false)
  const closeMobile = useCallback(() => setMobileOpen(false), [])
  const event = loadEvent ? loadedEvent : suppliedEvent
  const centrallyProtected = useDraftProtection({ dirty: hasUnsavedChanges, scope: `${identity.accountKey}:${identity.organizationId}:${eventId}:${location.pathname}`, pathname: location.pathname, isCurrent: current })

  useEffect(() => {
    const request = beginRequest()
    if (!request) return
    setError(null)
    Promise.all([
      loadEvent ? apiClient.get(`/organizer/events/${eventId}`, request.config) : Promise.resolve(null),
      // Shared with the workspace navbar so an event page sends one lookup.
      loadOrganizerOrganizations(identity.authContext),
    ]).then(([eventResponse, organizationsResponse]) => {
      if (!request.current()) return
      if (eventResponse) setLoadedEvent(eventResponse.data)
      const organizations = Array.isArray(organizationsResponse.data) ? organizationsResponse.data : []
      setOrganization(organizations.find(item => String(item.id) === String(identity.organizationId)) || null)
    }).catch(() => { if (request.current()) setError('Event navigation could not be loaded. Your work below is still available.') })
      .finally(() => request.release())
    return () => request.controller.abort()
  }, [beginRequest, eventId, identity.authContext, identity.organizationId, loadEvent, attempt])

  const correctEvent = event && String(event.id) === String(eventId)
    && (event.organization_id == null || identity.organizationId == null || String(event.organization_id) === String(identity.organizationId))
  const groups = correctEvent ? navigationFor(event, capabilities) : []
  const toolGroups = groups.filter(group => group.label !== 'Overview')
  useEffect(() => {
    if (location.hash !== '#ticket-types' || !correctEvent || !current()) return
    const target = document.getElementById('ticket-types')
    // Router links change the fragment without the browser's native anchor
    // scroll. Run after the authorized editor has rendered its section.
    target?.scrollIntoView?.({ behavior: 'instant', block: 'start' })
    target?.focus({ preventScroll: true })
  }, [location.hash, location.key, correctEvent, current])
  const navigateTo = (event, destination) => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    closeMobile()
    if (!centrallyProtected && hasUnsavedChanges && new URL(destination, window.location.origin).pathname !== location.pathname) {
      event.preventDefault()
      setPendingNavigation(destination)
    }
  }
  const toggleCollapsed = () => {
    const next = !collapsed
    setCollapsed(next)
    try { window.localStorage.setItem(preferenceKey, String(next)) } catch { /* Navigation remains usable when storage is unavailable. */ }
  }

  // Same container as the workspace navbar so pages keep their left edge
  // when moving between the dashboard and an event.
  return <div className={`mx-auto w-full min-w-0 ${WORKSPACE_WIDTHS.standard} px-4 py-6 sm:px-6 lg:px-8`}>
    <header className="mb-6 border-b border-neutral-200 pb-5">
      <Link to="/dashboard" onClick={event => navigateTo(event, '/dashboard')} className="inline-flex min-h-11 items-center text-sm font-medium text-brand-800">All events</Link>
      {correctEvent ? <>
        <div className="mt-2 flex flex-wrap items-start gap-3">
          <h1 className="min-w-0 flex-1 break-words text-2xl font-bold text-neutral-950 sm:text-3xl">{event.title}</h1>
          <span className="rounded-md bg-neutral-100 px-2.5 py-1 text-sm font-medium text-neutral-800">{statusLabels[event.status] || 'Event'}</span>
        </div>
        <div className="mt-3 flex flex-wrap gap-x-5 gap-y-2 text-sm text-neutral-700">
          {event.starts_at && <p className="flex items-start gap-2"><CalendarDays className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" /><span>{formatEventDateTime(event.starts_at, event.timezone)} · {event.timezone || 'Pacific/Guam'}</span></p>}
          {event.venue_name && <p className="flex items-start gap-2"><MapPin className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" /><span className="break-words">{event.venue_name}</span></p>}
        </div>
        <p className="mt-3 text-sm text-neutral-700">{organization?.name || event.organization_name || (event.organization_id != null ? `Organization ${event.organization_id}` : 'Event workspace')}</p>
        <p className="mt-1 text-sm text-neutral-600">{accessSummary(organization?.role, event.permissions, toolGroups.length > 0)}</p>
        {toolGroups.length > 0 && <details className="mt-1 text-sm text-neutral-600">
          <summary className="inline-flex min-h-11 cursor-pointer items-center font-medium text-brand-800">What you can do</summary>
          <p className="pb-1">{toolGroups.map(group => group.label).join(', ')}</p>
        </details>}
      </> : <p className="mt-2 text-sm text-neutral-600">{error ? 'Event context unavailable' : 'Loading event context…'}</p>}
      {error && <div className="mt-3 text-sm text-red-700" role="alert"><p>{error}</p><button type="button" className="min-h-11 font-semibold underline" onClick={() => setAttempt(value => value + 1)}>Retry event navigation</button></div>}
      {groups.length > 0 && <button type="button" className="mt-4 flex min-h-11 items-center gap-2 rounded-lg border border-neutral-300 px-3 text-sm font-semibold text-neutral-800 lg:hidden" aria-expanded={mobileOpen} onClick={() => setMobileOpen(true)}><Menu className="h-4 w-4" aria-hidden="true" />Event navigation</button>}
    </header>
    <div className="flex items-start gap-6 lg:gap-8">
      {groups.length > 0 && <aside className={`sticky top-24 hidden shrink-0 lg:block ${collapsed ? 'w-16' : 'w-56'}`}>
        <button type="button" className="mb-4 flex min-h-11 w-full items-center gap-2 rounded-lg px-3 text-sm font-medium text-neutral-700 hover:bg-neutral-100" onClick={toggleCollapsed} aria-label={collapsed ? 'Expand event navigation' : 'Collapse event navigation'} aria-expanded={!collapsed}>
          {collapsed ? <PanelLeftOpen className="h-5 w-5" aria-hidden="true" /> : <><PanelLeftClose className="h-5 w-5" aria-hidden="true" /><span>Collapse navigation</span></>}
        </button>
        <WorkspaceLinks groups={groups} collapsed={collapsed} location={location} onNavigate={navigateTo} />
      </aside>}
      <div className="min-w-0 flex-1">{children}</div>
    </div>
    {pendingNavigation && <Dialog labelledBy="event-leave-title" onClose={() => setPendingNavigation(null)}>
      <h2 id="event-leave-title" className="text-lg font-semibold text-neutral-950">Leave unsaved event changes?</h2>
      <p className="mt-2 text-sm text-neutral-700">Your event details have unsaved changes. Stay here to save them, or leave without saving.</p>
      <div className="mt-5 flex flex-wrap gap-3">
        <button type="button" className="btn-primary" onClick={() => setPendingNavigation(null)}>Stay and save</button>
        <button type="button" className="btn-secondary" onClick={() => navigate(pendingNavigation)}>Leave without saving</button>
      </div>
    </Dialog>}
    {mobileOpen && <MobileNavigation groups={groups} location={location} onClose={closeMobile} onNavigate={navigateTo} />}
  </div>
}

export default function EventWorkspace({ event, eventId, children, hasUnsavedChanges = false }) {
  const identity = useOrganizerIdentity()
  const location = useLocation()
  const base = `/dashboard/events/${eventId}`
  if (location.pathname !== base && !location.pathname.startsWith(`${base}/`)) return null
  if (!identity.ready) return <p className="p-6" role="status">Preparing your account…</p>
  return <WorkspaceSession key={`${identity.accountKey}:${identity.organizationId}:${eventId}:${location.pathname}`} suppliedEvent={event} eventId={eventId} identity={identity} location={location} hasUnsavedChanges={hasUnsavedChanges}>{children}</WorkspaceSession>
}
