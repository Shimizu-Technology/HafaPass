import useOperationalListing from '../../hooks/useOperationalListing'
import OperationalSearch from '../../components/OperationalSearch'
import OperationalPagination from '../../components/OperationalPagination'
import { PageHeader, WorkspacePage } from '../../components/WorkspacePage'
import { canManageOrganizationSettings, loadOrganizerOrganizations, resetOrganizerOrganizations } from '../../utils/organizerOrganizations'
import OrganizerSetupChecklist from './OrganizerSetupChecklist'
import VerificationNotice from '../../components/VerificationNotice'
import { roleLabel } from '../../utils/roles'
import { uploadImage } from '../../utils/uploads'
import { Loader2, Pencil, X, Upload, Plus, ScanLine, Settings } from 'lucide-react'
import { useState, useLayoutEffect, useRef } from 'react'
import { Link } from 'react-router-dom'
import apiClient, { getApiAuthContext } from '../../api/client'
import { formatEventDate } from '../../utils/eventTime'
import { currentScannerOwner } from '../../utils/admissionStore'
import { useOrganizerIdentity, useOrganizerPageVisit } from '../../hooks/useOrganizerContext'
import DashboardSummary from './DashboardSummary'
import { approvedImageUrl } from '../../utils/eventPageDesign'

function OrganizerProfileForm({ context, beginRequest, isCurrent, onSuccess }) {
 const [businessName, setBusinessName] = useState('')
 const [businessDescription, setBusinessDescription] = useState('')
 const [submitting, setSubmitting] = useState(false)
 const [error, setError] = useState(null)
 const mounted = useRef(false)
 useLayoutEffect(() => { mounted.current = true; return () => { mounted.current = false } }, [])

 const handleSubmit = async (e) => {
  e.preventDefault()
  if (!mounted.current || !isCurrent()) return
  if (!businessName.trim()) {
   setError('Business name is required')
   return
  }
  const request = beginRequest(context)
  if (!request) return
  setSubmitting(true)
  setError(null)
  try {
   await apiClient.post('/organizer_profile', {
    business_name: businessName.trim(),
    business_description: businessDescription.trim()
   }, request.config)
   if (mounted.current && request.current()) onSuccess()
  } catch (err) {
   if (!mounted.current || !request.current()) return
   const msg = err.response?.data?.errors?.[0] || err.response?.data?.error || 'Failed to create profile'
   setError(msg)
  } finally {
   request.release()
   if (mounted.current && request.current()) setSubmitting(false)
  }
 }

 return (
  <div className="max-w-lg mx-auto">
   <div className="bg-white rounded-xl shadow-md p-6">
    <h2 className="text-2xl font-bold text-neutral-900 mb-2">Host events on HåfaPass</h2>
    <p className="text-neutral-600">Start with your organization’s name. After that, a short checklist walks you through the rest:</p>
    <ol className="mt-3 mb-6 list-decimal space-y-1 pl-5 text-sm text-neutral-700">
     <li>Accept the organizer agreement</li>
     <li>HåfaPass verifies your organization</li>
     <li>Choose how you get paid (check or bank transfer)</li>
     <li>Create and publish your first event</li>
    </ol>
    <p className="mb-6 text-sm text-content-muted">Joining someone else’s team? Use the invitation link from your email instead — you don’t need your own profile.</p>

    {error && (
     <div className="mb-4 p-3 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm">
      {error}
     </div>
    )}

    <form onSubmit={handleSubmit} className="space-y-4">
     <div>
      <label htmlFor="business_name" className="block text-sm font-medium text-neutral-700 mb-1">
       Business Name <span className="text-red-500">*</span>
      </label>
      <input
       id="business_name"
       type="text"
       value={businessName}
       onChange={(e) => setBusinessName(e.target.value)}
       className="input"
       placeholder="e.g., Island Nights Promotions"
       disabled={submitting}
      />
     </div>

     <div>
      <label htmlFor="business_description" className="block text-sm font-medium text-neutral-700 mb-1">
       Description
      </label>
      <textarea
       id="business_description"
       value={businessDescription}
       onChange={(e) => setBusinessDescription(e.target.value)}
       rows={3}
       className="input"
       placeholder="Tell attendees about your business..."
       disabled={submitting}
      />
     </div>

     <button
      type="submit"
      disabled={submitting}
      className="btn-primary w-full"
     >
      {submitting ? 'Creating Profile...' : 'Create Organizer Profile'}
     </button>
    </form>
   </div>
  </div>
 )
}

function StatusBadge({ status }) {
 const styles = {
  draft: 'bg-yellow-100 text-yellow-800',
  published: 'bg-green-100 text-green-800',
  cancelled: 'bg-red-100 text-red-800',
  completed: 'bg-neutral-100 text-neutral-800',
  postponed: 'bg-orange-100 text-orange-800',
  archived: 'bg-neutral-200 text-neutral-700'
 }
 return (
  <span className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${styles[status] || 'bg-neutral-100 text-neutral-800'}`}>
   {status.charAt(0).toUpperCase() + status.slice(1)}
  </span>
 )
}

// Event managers land on the event overview. Other staff keep their direct
// route to the one tool they were given.
function EventListCard({ event }) {
 const visibilityChip = !['published', 'completed'].includes(event.status) ? null
  : event.policy_hold_scope ? 'On hold'
    : event.publicly_visible === false ? ({
      unverified: 'Waiting for verification', pending: 'Waiting for verification',
      rejected: 'Action needed', suspended: 'Suspended',
    })[event.organizer_verification_status] : null
 const permissions = event.permissions || {}
 const destination = permissions.manage_events ? `/dashboard/events/${event.id}` : permissions.edit_event_content ? `/dashboard/events/${event.id}/edit` : permissions.box_office ? `/dashboard/events/${event.id}/box-office` : permissions.scan ? `/dashboard/scanner?event=${event.id}` : permissions.refund && permissions.view_finance ? `/dashboard/events/${event.id}/refunds` : permissions.view_finance ? `/dashboard/events/${event.id}/analytics` : `/dashboard/events/${event.id}/edit`
 const actionLabel = permissions.manage_events ? "Open event" : permissions.edit_event_content ? "Edit event" : permissions.box_office ? "Open box office" : permissions.scan ? "Scan tickets" : permissions.refund && permissions.view_finance ? "Open refunds" : permissions.view_finance ? "View sales" : "View event"
 const ticketsSold = event.ticket_types
  ? event.ticket_types.reduce((sum, tt) => sum + (tt.quantity_sold || 0), 0)
  : 0

 return (
  <Link
   to={destination}
   className="block bg-white rounded-xl shadow-sm border border-neutral-200 hover:shadow-md hover:border-brand-200 transition-[border-color,box-shadow] duration-200 ease-out-strong p-4"
  >
   <div className="flex items-start justify-between gap-3">
    <div className="min-w-0 flex-1">
     <h3 className="text-lg font-semibold text-neutral-900 truncate">{event.title}</h3>
     <p className="text-sm text-neutral-500 mt-0.5">
      {formatEventDate(event.starts_at, event.timezone)} {event.venue_name && `· ${event.venue_name}`}
     </p>
    </div>
    {visibilityChip ? <span className="inline-flex rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-950">{visibilityChip}</span> : <StatusBadge status={event.status} />}
    <span className="text-sm font-semibold text-brand-600">{actionLabel}</span>
   </div>
   <div className="mt-3 flex items-center gap-4 text-sm text-neutral-600">
    <span className="flex items-center gap-1">
     <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 5v2m0 4v2m0 4v2M5 5a2 2 0 00-2 2v3a2 2 0 110 4v3a2 2 0 002 2h14a2 2 0 002-2v-3a2 2 0 110-4V7a2 2 0 00-2-2H5z" />
     </svg>
     {ticketsSold} sold
    </span>
    {event.category && (
     <span className="text-neutral-600 capitalize">{event.category.replace('_', ' ')}</span>
    )}
   </div>
  </Link>
 )
}

function EditProfileModal({ profile, context, beginRequest, isCurrent, onClose, onSaved }) {
 const [businessName, setBusinessName] = useState(profile.business_name || '')
 const [description, setDescription] = useState(profile.business_description || '')
 const [logoUrl, setLogoUrl] = useState(profile.logo_url || '')
 const [saving, setSaving] = useState(false)
 const [uploading, setUploading] = useState(false)
 const [error, setError] = useState(null)
 const fileRef = useRef(null)
 const mounted = useRef(false)
 const current = () => mounted.current && isCurrent()
 useLayoutEffect(() => { mounted.current = true; return () => { mounted.current = false } }, [])

 const handleLogoUpload = async (file) => {
  if (!file || !current()) return
  const ACCEPTED = ['image/jpeg', 'image/png', 'image/webp']
  if (!ACCEPTED.includes(file.type)) { setError('Please upload JPG, PNG, or WebP'); return }
  if (file.size > 5 * 1024 * 1024) { setError('Image must be under 5MB'); return }
  setUploading(true)
  setError(null)
  try {
   const url = await uploadImage(file, undefined, current)
   if (current()) setLogoUrl(url)
  } catch {
   if (current()) setError('Logo upload failed')
  } finally {
   if (current()) setUploading(false)
  }
 }

 const handleSubmit = async (e) => {
  e.preventDefault()
  if (!current()) return
  if (!businessName.trim()) { setError('Business name is required'); return }
  const request = beginRequest(context)
  if (!request) return
  setSaving(true)
  setError(null)
  try {
   await apiClient.put('/organizer_profile', {
    business_name: businessName.trim(),
    business_description: description.trim(),
    logo_url: logoUrl || null
   }, request.config)
   if (current() && request.current()) onSaved()
  } catch (err) {
   if (current() && request.current()) setError(err.response?.data?.errors?.[0] || err.response?.data?.error || 'Failed to update profile')
  } finally {
   request.release()
   if (current() && request.current()) setSaving(false)
  }
 }

 return (
  <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 px-4">
   <div className="bg-white rounded-xl shadow-xl max-w-md w-full p-6">
    <div className="flex items-center justify-between mb-4">
     <h3 className="text-lg font-semibold text-neutral-900">Edit Profile</h3>
     <button onClick={onClose} aria-label="Close profile editor" className="p-1 text-neutral-400 hover:text-neutral-600"><X className="w-5 h-5" /></button>
    </div>
    {error && <div className="mb-4 p-3 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm">{error}</div>}
    <form onSubmit={handleSubmit} className="space-y-4">
     <div>
      <label className="block text-sm font-medium text-neutral-700 mb-1">Logo</label>
      <div className="flex items-center gap-3">
       {approvedImageUrl(logoUrl, profile.image_asset_host) ? (
        <img src={logoUrl} alt="Logo" className="w-12 h-12 rounded-xl object-cover border border-neutral-200" />
       ) : (
        <div className="w-12 h-12 rounded-xl bg-neutral-100 flex items-center justify-center">
         <Upload className="w-5 h-5 text-neutral-400" />
        </div>
       )}
       <button type="button" onClick={() => fileRef.current?.click()} disabled={uploading} className="text-sm text-brand-500 hover:text-brand-700 font-medium">
        {uploading ? 'Uploading...' : logoUrl ? 'Change' : 'Upload Logo'}
       </button>
       <input ref={fileRef} type="file" accept=".jpg,.jpeg,.png,.webp" className="hidden" onChange={e => handleLogoUpload(e.target.files[0])} />
      </div>
     </div>
     <div>
      <label htmlFor="edit-business-name" className="block text-sm font-medium text-neutral-700 mb-1">Business Name <span className="text-red-500">*</span></label>
      <input id="edit-business-name" value={businessName} onChange={e => setBusinessName(e.target.value)} className="input" disabled={saving} />
     </div>
     <div>
      <label className="block text-sm font-medium text-neutral-700 mb-1">Description</label>
      <textarea value={description} onChange={e => setDescription(e.target.value)} rows={3} className="input" disabled={saving} />
     </div>
     <div className="flex gap-3 justify-end">
      <button type="button" onClick={onClose} disabled={saving} className="px-4 py-2 text-sm font-medium text-neutral-700 hover:text-neutral-900">Cancel</button>
      <button type="submit" disabled={saving} className="btn-primary text-sm px-4 py-2">{saving ? 'Saving...' : 'Save'}</button>
     </div>
    </form>
   </div>
  </div>
 )
}

function DashboardSession({ authContext }) {
 const [profile, setProfile] = useState(null)
 const [events, setEvents] = useState([])
 const [loading, setLoading] = useState(true)
 const [error, setError] = useState(null)
 const [actionError, setActionError] = useState(null)
 const [verificationRequestSignal, setVerificationRequestSignal] = useState(null)
 const [editor, setEditor] = useState(null)
 const editorRef = useRef(null)
 const editorGeneration = useRef(0)
 const [profileContext, setProfileContext] = useState(null)
 const [readinessLoading, setReadinessLoading] = useState(false)
 const [organizations, setOrganizations] = useState([])
 const [selectedOrganizationId, setSelectedOrganizationId] = useState(window.localStorage.getItem('hafapass_organization_id') || '')
 const listing = useOperationalListing(`events:${authContext?.userId || currentScannerOwner()}:${selectedOrganizationId}`)
 const [eventMeta, setEventMeta] = useState(null)
 const [summary, setSummary] = useState(null)
 const summaryRequest = useRef(null)
 const [listLoading, setListLoading] = useState(false)
 const loadGeneration = useRef(0)
 const loadingOrganization = useRef(null)
 const eventRequest = useRef(null)
 const mounted = useRef(false)
 const requests = useRef(new Set())
 const organization = organizations.find(item => String(item.id) === selectedOrganizationId)
 const permissions = organization?.permissions || {}
 const canManageProfile = permissions.manage_organization === true
 const canCreate = permissions.manage_events === true
 const canScan = permissions.scan === true || events.some(event => event.permissions?.scan)
 const canManageSettings = canManageOrganizationSettings(organization)
 const feeNotice = organization?.fee_change_notice
 const [noticeError, setNoticeError] = useState('')
 const [acknowledgingNotice, setAcknowledgingNotice] = useState(false)

 const acknowledgeFeeNotice = async () => {
  const request = beginRequest(profileContext)
  if (!request || !feeNotice || acknowledgingNotice) return
  setAcknowledgingNotice(true)
  setNoticeError('')
  try {
   const response = await apiClient.post(`/organizer/fee_change_notices/${feeNotice.id}/acknowledge`, {}, request.config)
   if (request.current()) setOrganizations(previous => previous.map(item => item.id === organization.id
    ? { ...item, fee_change_notice: { ...item.fee_change_notice, acknowledged_at: response.data.acknowledged_at } } : item))
  } catch (failure) {
   if (request.current()) setNoticeError(failure.response?.data?.error || 'Could not record your acknowledgment. Try again.')
  } finally { request.release(); setAcknowledgingNotice(false) }
 }

 const contextCurrent = context => Boolean(context && mounted.current && context.generation === loadGeneration.current
  && context.authContext === getApiAuthContext() && context.owner === currentScannerOwner()
  && (!context.authContext || context.authContext.userId === context.owner)
  && context.organizationId === window.localStorage.getItem('hafapass_organization_id'))

 const beginRequest = context => {
  if (!contextCurrent(context)) return null
  const controller = new AbortController()
  requests.current.add(controller)
  return {
   controller,
   config: { signal: controller.signal, organizationId: context.organizationId, ...(context.authContext ? { authContext: context.authContext } : {}) },
   current: () => contextCurrent(context) && !controller.signal.aborted,
   release: () => requests.current.delete(controller),
  }
 }

 const closeEditor = expected => {
  if (editorRef.current !== expected) return
  expected?.requests.forEach(controller => controller.abort())
  editorRef.current = null
  setEditor(null)
 }

 const openEditor = () => {
  if (!contextCurrent(profileContext)) return
  const next = { context: profileContext, id: ++editorGeneration.current, requests: new Set() }
  editorRef.current = next
  setEditor(next)
 }

 const beginEditorRequest = context => {
  const expected = editorRef.current
  if (!expected || expected.context !== context) return null
  const request = beginRequest(context)
  if (!request) return null
  // Closing an editor invalidates its request synchronously, before React unmounts it.
  const controller = request.controller
  expected.requests.add(controller)
  return { ...request, release: () => { expected.requests.delete(controller); request.release() } }
 }

 const updateReadiness = async (path) => {
  if (readinessLoading) return false
  const request = beginRequest(profileContext)
  if (!request) return false
  setReadinessLoading(true)
  setActionError(null)
  try {
   const response = await apiClient.post(`/organizer_profile/${path}`, {}, request.config)
   if (request.current()) setProfile(response.data)
   return request.current()
  } catch (err) {
   if (request.current()) setActionError({ path, message: err.response?.data?.error || 'Could not update your setup. Please try again.' })
   return false
  } finally {
   request.release()
   if (request.current()) setReadinessLoading(false)
  }
 }

 // List navigation owns only its GET. Profile edits and readiness mutations
 // keep the same organization/account context until a full reload withdraws it.
 const fetchEvents = async (context = profileContext) => {
  const request = beginRequest(context)
  if (!request) return
  eventRequest.current?.controller.abort()
  eventRequest.current = request
  const current = () => request.current() && eventRequest.current === request
  setListLoading(true)
  setError(null)
  try {
   const response = await apiClient.get('/organizer/events', { ...request.config, params: { q: listing.q, page: listing.page } })
   if (!current()) return
   const data = response.data.events || response.data
   setEvents(Array.isArray(data) ? data : [])
   setEventMeta(response.data.meta || null)
  } catch (err) {
   if (current()) setError(err.response?.status === 401 ? 'Please sign in to access the dashboard.' : 'Failed to load events. Please try again.')
  } finally {
   request.release()
   if (current()) { setLoading(false); setListLoading(false) }
  }
 }
 const fetchEventsRef = useRef(fetchEvents)
 fetchEventsRef.current = fetchEvents

 // Totals cover the whole organization, so search and paging do not refetch them.
 const fetchSummary = async (context = profileContext) => {
  const request = beginRequest(context)
  if (!request) return
  summaryRequest.current?.controller.abort()
  summaryRequest.current = request
  const current = () => request.current() && summaryRequest.current === request
  setSummary({ status: 'loading' })
  try {
   const response = await apiClient.get('/organizer/events/summary', request.config)
   if (current()) setSummary({ status: 'ready', data: response.data || {} })
  } catch {
   if (current()) setSummary({ status: 'error' })
  } finally {
   request.release()
  }
 }
 const fetchSummaryRef = useRef(fetchSummary)
 fetchSummaryRef.current = fetchSummary

 const fetchDashboard = async () => {
  if (!mounted.current) return
  const generation = ++loadGeneration.current
  requests.current.forEach(controller => controller.abort())
  requests.current.clear()
  closeEditor(editorRef.current)
  setReadinessLoading(false)
  // An earlier organization's setup error must not look like this one's.
  setActionError(null)
  const requestedOrganization = window.localStorage.getItem('hafapass_organization_id')
  loadingOrganization.current = requestedOrganization || ''
  if (profileContext?.organizationId !== requestedOrganization) {
   setLoading(true)
   setProfile(null)
   setProfileContext(null)
   setEvents([])
   setEventMeta(null)
   setSummary(null)
  }
  let context = { generation, authContext, owner: currentScannerOwner(), organizationId: window.localStorage.getItem('hafapass_organization_id') }
  const current = () => contextCurrent(context)
  const request = beginRequest(context)
  if (!request) return
  setListLoading(true)
  setError(null)
  let eventsStarted = false
  try {
   const organizationsRes = await loadOrganizerOrganizations(authContext)
   if (!current()) return
   const availableOrganizations = Array.isArray(organizationsRes.data) ? organizationsRes.data : []
   setOrganizations(availableOrganizations)
   const storedOrganizationId = window.localStorage.getItem('hafapass_organization_id')
   const selectedOrganization = availableOrganizations.find(item => item.id.toString() === storedOrganizationId) || availableOrganizations[0]
   loadingOrganization.current = selectedOrganization ? String(selectedOrganization.id) : ''
   if (selectedOrganization) {
    window.localStorage.setItem('hafapass_organization_id', selectedOrganization.id.toString())
    setSelectedOrganizationId(selectedOrganization.id.toString())
   } else {
    window.localStorage.removeItem('hafapass_organization_id')
    setSelectedOrganizationId('')
   }
   const expectedOrganization = selectedOrganization ? String(selectedOrganization.id) : null
   context = { ...context, organizationId: expectedOrganization }
   const selectedConfig = { ...request.config, organizationId: expectedOrganization }
   const profileRes = await apiClient.get('/organizer_profile', selectedConfig)
   if (!current()) return
   setProfile(profileRes.data)
   setProfileContext(context)

   eventsStarted = true
   void fetchEventsRef.current(context)
   void fetchSummaryRef.current(context)
  } catch (err) {
   if (!current()) return
   if (err.response?.status === 404) {
    // No organizer profile — show create form
    setProfile(null)
    setProfileContext(context)
   } else if (err.response?.status === 401) {
    setError('Please sign in to access the dashboard.')
   } else {
    setError('Failed to load dashboard. Please try again.')
   }
  } finally {
   request.release()
   if (current() && !eventsStarted) { setLoading(false); setListLoading(false) }
  }
 }

 // An admin who opened another organization from the admin console returns
 // to their own organizations (if any) without a stale switcher entry.
 const leaveAdminView = () => {
  window.localStorage.removeItem('hafapass_organization_id')
  resetOrganizerOrganizations()
  setSelectedOrganizationId('')
  fetchDashboardRef.current()
 }

 const fetchDashboardRef = useRef(fetchDashboard)
 fetchDashboardRef.current = fetchDashboard
 useLayoutEffect(() => {
  mounted.current = true
  const owned = requests.current
  fetchDashboardRef.current()
  const changed = event => {
   if (['hafapass_organization_id', 'hafapass_scanner_user_id', null].includes(event.key)) fetchDashboardRef.current()
  }
  window.addEventListener('storage', changed)
  return () => {
   mounted.current = false
   loadGeneration.current += 1
   owned.forEach(controller => controller.abort())
   window.removeEventListener('storage', changed)
  }
 }, [])

 useLayoutEffect(() => {
  if (loadingOrganization.current !== selectedOrganizationId) fetchDashboardRef.current()
 }, [selectedOrganizationId])

 useLayoutEffect(() => {
  void fetchEventsRef.current()
 }, [listing.q, listing.page])

 if (loading) {
  return (
   <div className="min-h-[60vh] flex flex-col gap-3 items-center justify-center">
    <Loader2 className="w-8 h-8 text-brand-500 animate-spin" />
    <p role="status">Loading {organization?.name || 'selected organization'}…</p>
   </div>
  )
 }

 if (error) {
  return (
   <div className="max-w-2xl mx-auto px-4 py-12">
    <div className="bg-red-50 border border-red-200 rounded-xl p-6 text-center">
     <p className="text-red-700">{error}</p>
     <button
      onClick={fetchDashboard}
      className="mt-4 text-red-600 hover:text-red-800 font-medium underline"
     >
      Try Again
     </button>
    </div>
   </div>
  )
 }

 if (!profile && organization) return <div className="mx-auto max-w-2xl px-4 py-8">
  <h1 className="break-words text-2xl font-bold">{organization.name}</h1>
  <p className="mt-3">{canManageProfile ? 'Organizer setup is unavailable for this organization. Select another organization or contact support.' : 'This organization has no organizer profile. Ask its owner to contact support.'}</p>
  {organizations.length > 1 && <label className="mt-4 block">Organization
   <select aria-label="Organization" value={selectedOrganizationId} onChange={event => {
    window.localStorage.setItem('hafapass_organization_id', event.target.value)
    setSelectedOrganizationId(event.target.value)
   }} className="input mt-2 min-h-[44px] min-w-0 max-w-full">
    {organizations.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}
   </select>
  </label>}
 </div>

 if (!profile) {
  return (
   <div className="px-4 py-12">
    <OrganizerProfileForm context={profileContext} beginRequest={beginRequest} isCurrent={() => contextCurrent(profileContext)} onSuccess={fetchDashboard} />
   </div>
  )
 }

 return (
  <WorkspacePage>
   <PageHeader
    title={`Welcome, ${profile.business_name}`}
    titleAccessory={canManageProfile && <button onClick={openEditor} className="inline-flex min-h-[44px] min-w-[44px] shrink-0 items-center justify-center p-2.5 text-neutral-400 hover:text-brand-500 rounded-lg hover:bg-brand-50 transition-colors" title="Edit Profile">
     <Pencil className="w-4 h-4" />
    </button>}
    description={canCreate ? 'Manage your events and track ticket sales' : 'Open your assigned event tasks'}
    actions={(canScan || canCreate || canManageSettings) && <div className="grid w-full grid-cols-2 gap-2 sm:flex sm:w-auto sm:flex-nowrap sm:items-center">
     {canCreate && <Link to="/dashboard/events/new" className="btn-primary col-span-2 order-first gap-2 whitespace-nowrap !px-5 !py-2.5 text-sm sm:order-last">
      <Plus aria-hidden="true" className="h-4 w-4" />
      Create event
     </Link>}
     {canScan && <Link to="/dashboard/scanner" className={`btn-secondary gap-2 whitespace-nowrap !px-4 !py-2.5 text-sm ${canManageSettings ? '' : 'col-span-2'}`}>
      <ScanLine aria-hidden="true" className="h-4 w-4" />
      Scan tickets
     </Link>}
     {canManageSettings && <Link to="/dashboard/settings" className={`btn-secondary gap-2 whitespace-nowrap !px-4 !py-2.5 text-sm ${canScan ? '' : 'col-span-2'}`}>
      <Settings aria-hidden="true" className="h-4 w-4" />
      Settings
     </Link>}
    </div>}
   >
    {organizations.length > 1 && (
     <label className="mt-3 flex min-w-0 flex-col gap-2 text-sm text-neutral-600 sm:flex-row sm:items-center">
      Organization
      <select value={selectedOrganizationId} onChange={event => {
       window.localStorage.setItem('hafapass_organization_id', event.target.value)
       setSelectedOrganizationId(event.target.value)
      }} className="input min-h-[44px] min-w-0 max-w-full !w-full !py-2 text-sm sm:flex-1 sm:max-w-sm">
       {organizations.map(organization => <option key={organization.id} value={organization.id}>{organization.name} · {organization.admin_view ? 'Admin view' : roleLabel(organization.role) || 'Staff'}</option>)}
      </select>
     </label>
    )}
   </PageHeader>

   {canManageProfile && editor && (
    <EditProfileModal
     key={editor.id}
     profile={profile}
     context={editor.context}
     beginRequest={beginEditorRequest}
     isCurrent={() => editorRef.current === editor && contextCurrent(editor.context)}
     onClose={() => closeEditor(editor)}
     onSaved={() => { if (editorRef.current === editor && contextCurrent(editor.context)) { closeEditor(editor); fetchDashboard() } }}
    />
   )}

   {organization?.admin_view && <div role="status" className="mb-6 flex flex-col gap-3 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950 sm:flex-row sm:items-center sm:justify-between">
    <p>You’re viewing <strong>{organization.name}</strong> as a HåfaPass admin. Changes you make here are recorded in the audit log.</p>
    <button type="button" onClick={leaveAdminView} className="btn-secondary shrink-0 !px-4 !py-2 text-sm">Leave this organization</button>
   </div>}

   {feeNotice && <section aria-label="Upcoming fee change" className="mb-6 rounded-2xl border border-amber-300 bg-amber-50 p-4 text-sm text-amber-950">
    <h2 className="font-semibold">Upcoming HåfaPass fee change</h2>
    <p className="mt-1">New terms take effect {new Date(feeNotice.effective_at).toLocaleString()}. On a $25.00 {organization.name} ticket under the current fee policy, the buyer total would change from ${(feeNotice.old_example.all_in_price_cents / 100).toFixed(2)} to ${(feeNotice.new_example.all_in_price_cents / 100).toFixed(2)}.</p>
    <p className="mt-1">Service fee: {feeNotice.old_terms.service_fee_percent}% + ${(feeNotice.old_terms.service_fee_flat_cents / 100).toFixed(2)} → {feeNotice.new_terms.service_fee_percent}% + ${(feeNotice.new_terms.service_fee_flat_cents / 100).toFixed(2)} per paid ticket. Card processing: {feeNotice.old_terms.processing_fee_bearer} → {feeNotice.new_terms.processing_fee_bearer}. Payouts: {feeNotice.old_terms.payout_schedule_text} → {feeNotice.new_terms.payout_schedule_text}.</p>
    {feeNotice.acknowledged_at ? <p className="mt-2 font-medium">Acknowledged. This notice remains visible until the effective date.</p>
     : <button type="button" disabled={acknowledgingNotice} onClick={acknowledgeFeeNotice} className="btn-secondary mt-3">{acknowledgingNotice ? 'Recording…' : 'Acknowledge notice'}</button>}
    {noticeError && <p role="alert" className="mt-2 text-red-700">{noticeError}</p>}
   </section>}

   {canManageProfile && <VerificationNotice key={organization?.id} profile={profile} beginRequest={() => beginRequest(profileContext)} onUpdated={fetchDashboard} requestSignal={verificationRequestSignal} organizationId={organization?.id} className="mb-6" />}
   {canManageProfile && <OrganizerSetupChecklist profile={profile} canCreate={canCreate} adminView={Boolean(organization?.admin_view)} busy={readinessLoading}
    agreementError={actionError?.path === 'accept_policy' ? actionError.message : null} onOpenAgreement={() => setActionError(null)}
    onEditProfile={openEditor}
    onAcceptPolicy={() => updateReadiness('accept_policy')}
    onSubmitVerification={() => setVerificationRequestSignal({ organizationId: organization?.id })} />}
   {/* Agreement errors show inside the agreement dialog only. */}
   {actionError && actionError.path !== 'accept_policy' && <p role="alert" className="mb-4 rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-800">{actionError.message}</p>}

   <DashboardSummary state={summary} currency={organization?.currency || 'USD'} onRetry={() => fetchSummary()} />
   <OperationalSearch label="Find an event" buttonLabel="Search events" hint="Search by event name, venue, link name or event ID." query={listing.q} onSearch={listing.search} busy={listLoading} />
   {listLoading && <p role="status" className="mb-3 text-sm text-neutral-700">Loading events…</p>}
   <div aria-busy={listLoading}>
   {events.length === 0 ? (
    <div className="bg-white rounded-xl shadow-sm border border-neutral-200 p-12 text-center">
     <svg className="mx-auto h-12 w-12 text-neutral-400 mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z" />
     </svg>
     <h3 className="text-lg font-medium text-neutral-900 mb-1">{listing.q || listing.page > 1 ? 'No matching events' : canCreate ? 'No events yet' : 'No assigned events'}</h3>
     <p className="text-neutral-500 mb-4">{listing.q || listing.page > 1 ? 'Try another search or return to the previous page.' : canCreate ? 'Get started by creating your first event' : 'Ask your event manager to assign an event to you.'}</p>
     {canCreate && <Link
      to="/dashboard/events/new"
      className="btn-primary gap-2"
     >
      <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
       <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 4v16m8-8H4" />
      </svg>
      Create Your First Event
     </Link>}
    </div>
   ) : (
    <div className="space-y-3">
     {events.map((event) => (
      <EventListCard key={event.id} event={event} />
     ))}
    </div>
   )}
   </div>
   <OperationalPagination meta={eventMeta} page={listing.page} onPage={listing.goToPage} busy={listLoading} label="Event pages" />
  </WorkspacePage>
 )
}

export default function DashboardPage() {
 const identity = useOrganizerIdentity()
 const visit = useOrganizerPageVisit('/dashboard')
 if (!visit.active) return null
 if (!identity.ready) {
  return <div className="grid min-h-screen place-items-center" role="status">Preparing your account…</div>
 }
 return <DashboardSession key={`${identity.accountKey}:${visit.generation}`} authContext={identity.authContext} />
}
