import EventWorkspace from '../../components/EventWorkspace'
import { Loader2, Mail, RotateCw, Trash2, UserPlus, UserRoundCog } from 'lucide-react'
import { useCallback, useEffect, useRef, useState } from 'react'
import { useParams } from 'react-router-dom'
import apiClient from '../../api/client'
import EventAccessNotice from '../../components/EventAccessNotice'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import { RoleRadioGroup, RoleSelect } from '../../components/team/RoleChoice'
import { InvitationLinkPanel, InvitationStatusPill } from '../../components/team/TeamManager'
import { EVENT_ASSIGNMENT_ROLES, EVENT_INVITE_ROLES, emailDeliveryLabel, invitationUrl, roleLabel } from '../../utils/roles'

const label = roleLabel

function EventStaffSession({ id, identity }) {
  const { current, beginRequest } = useOrganizerRequests(identity, `/dashboard/events/${id}/team`)
  const loadState = useRef({ generation: 0, request: null })
  const loaded = useRef(false)
  const refreshingRef = useRef(false)
  const busyRef = useRef(false)
  const storageKey = `hafapass:team-outcome:${identity.owner}:${identity.organizationId}:${id}`
  const [pending, setPending] = useState(() => { try { const raw = window.sessionStorage.getItem(storageKey); if (raw === null) return null; const value = JSON.parse(raw); return value && typeof value.label === 'string' ? value : { label: 'A previous staff change' } } catch { return { label: 'A previous staff change' } } })
  const pendingRef = useRef(pending)
  const [reviewed, setReviewed] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const [event, setEvent] = useState(null)
  const [assignments, setAssignments] = useState([])
  const [candidates, setCandidates] = useState([])
  const [invitations, setInvitations] = useState([])
  const [inviteEmail, setInviteEmail] = useState('')
  const [inviteRole, setInviteRole] = useState('scanner')
  const [link, setLink] = useState(null)
  const [notice, setNotice] = useState(null)
  const [userId, setUserId] = useState('')
  const [role, setRole] = useState('scanner')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  const clearPending = () => {
    try { window.sessionStorage.removeItem(storageKey); pendingRef.current = null; setPending(null); return true }
    catch { setError('The saved recovery record could not be cleared. Check browser storage before another change.'); return false }
  }
  const load = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    loadState.current.request?.controller.abort()
    const generation = ++loadState.current.generation
    loadState.current.request = request
    const canApply = () => request.current() && generation === loadState.current.generation
    if (!loaded.current) setLoading(true)
    refreshingRef.current = true
    setRefreshing(true)
    setError(null)
    if (pendingRef.current) setReviewed(false)
    try {
      const eventResponse = await apiClient.get(`/organizer/events/${id}`, request.config)
      if (!canApply()) return
      const savedEvent = eventResponse.data
      if (String(savedEvent.id) !== String(id) || (identity.organizationId != null && savedEvent.organization_id != null && String(savedEvent.organization_id) !== String(identity.organizationId))) throw new Error('Wrong event context')
      if (savedEvent.permissions?.manage_staff !== true) {
        setEvent(savedEvent); setAssignments([]); setCandidates([]); setInvitations([])
        return
      }
      const staffResponse = await apiClient.get(`/organizer/events/${id}/staff_assignments`, request.config)
      if (!canApply()) return
      setEvent(savedEvent)
      setAssignments(staffResponse.data.assignments || [])
      setInvitations(staffResponse.data.pending_invitations || [])
      const available = staffResponse.data.candidates || []
      setCandidates(available)
      setUserId(value => available.some(candidate => String(candidate.user_id) === value) ? value : available[0]?.user_id?.toString() || '')
      loaded.current = true
      setReviewed(Boolean(pendingRef.current))
    } catch (requestError) {
      if (!canApply()) return
      if ([401, 403, 404].includes(requestError.response?.status)) { setEvent(null); loaded.current = false }
      setError(requestError.response?.data?.error || 'Could not load event staff. Your assignment choices are retained.')
    } finally {
      if (canApply()) { setLoading(false); setRefreshing(false); refreshingRef.current = false }
      request.release()
    }
  }, [id, beginRequest, identity.organizationId])

  useEffect(() => { load() }, [load])

  const mutate = async (labelText, send, apply) => {
    if (refreshingRef.current || busyRef.current || pendingRef.current || !current() || event?.permissions?.manage_staff !== true) return
    const request = beginRequest()
    if (!request) return
    const record = { label: labelText, started_at: new Date().toISOString() }
    try { window.sessionStorage.setItem(storageKey, JSON.stringify(record)) }
    catch { setError('The recovery record could not be saved. Enable browser storage before changing staff.'); request.release(); return }
    pendingRef.current = record
    setPending(record); setReviewed(false)
    busyRef.current = true
    setBusy(true); setError(null)
    try {
      const response = await send(request.config)
      if (!request.current()) return
      if (!clearPending()) return
      apply(response)
    } catch (requestError) {
      if (!request.current()) return
      const uncertain = !requestError.response || requestError.response.status >= 500 || [408, 409, 429].includes(requestError.response.status)
      if (!uncertain) clearPending()
      if ([401, 403, 404].includes(requestError.response?.status)) { setEvent(null); loaded.current = false }
      setError(uncertain ? 'The staff response was not confirmed. Refresh the saved staff list and verify the outcome before making another change.' : requestError.response?.data?.error || requestError.response?.data?.errors?.[0] || 'Could not update staff. Your choices are retained.')
    } finally {
      if (request.current()) { busyRef.current = false; setBusy(false) }
      request.release()
    }
  }
  const assign = submitEvent => {
    submitEvent.preventDefault()
    if (!userId) return
    return mutate('Assign event staff', config => apiClient.post(`/organizer/events/${id}/staff_assignments`, { user_id: userId, role }, config), response => {
      setAssignments(items => [...items.filter(item => item.id !== response.data.id), response.data])
    })
  }
  // One step: invite by email with door access to this event. People already
  // on the team are assigned at once; everyone else joins when they accept.
  const inviteStaff = submitEvent => {
    submitEvent.preventDefault()
    const email = inviteEmail.trim()
    if (!email) return
    setNotice(null); setLink(null)
    return mutate('Invite event staff', config => apiClient.post(`/organizer/events/${id}/staff_assignments`, { email, role: inviteRole }, config), response => {
      setInviteEmail('')
      if (response.data.assignment) {
        setAssignments(items => [...items.filter(item => item.id !== response.data.assignment.id), response.data.assignment])
        setNotice(`${response.data.assignment.email} is already on your team and can now work this event as ${label(inviteRole)}.`)
      } else {
        const invitation = response.data.invitation
        setInvitations(items => [...items.filter(item => item.membership_id !== invitation.membership_id), invitation])
        setNotice(`Invitation sent to ${invitation.email}. They can work this event as ${label(invitation.role)} as soon as they accept.`)
        setLink({ url: invitationUrl(invitation.invitation_token), email: invitation.email })
      }
    })
  }
  const resendInvitation = invitation => {
    setNotice(null); setLink(null)
    return mutate('Resend event invitation', config => apiClient.post(`/organizer/events/${id}/staff_invitations/${invitation.membership_id}/resend`, {}, config), response => {
      setInvitations(items => items.map(item => item.membership_id === invitation.membership_id ? response.data : item))
      setNotice(`A new invitation was sent to ${invitation.email}.`)
      setLink({ url: invitationUrl(response.data.invitation_token), email: invitation.email })
    })
  }
  const withdrawInvitation = invitation => mutate('Withdraw event invitation', config => apiClient.delete(`/organizer/events/${id}/staff_invitations/${invitation.membership_id}`, config), () => {
    setInvitations(items => items.filter(item => item.membership_id !== invitation.membership_id))
    setNotice(`${invitation.email} was removed from this event’s invitations.`)
  })
  const revoke = assignment => mutate('Revoke event staff', config => apiClient.delete(`/organizer/events/${id}/staff_assignments/${assignment.id}`, config), () => {
    setAssignments(items => items.map(item => item.id === assignment.id ? { ...item, status: 'revoked' } : item))
  })
  const acknowledge = () => {
    if (!current() || busyRef.current || !reviewed) return
    if (clearPending()) setError(null)
  }

  if (loading) return <div role="status" aria-label="Loading event staff" className="flex justify-center py-20"><Loader2 className="h-8 w-8 animate-spin text-brand-500" /></div>

  if (!event) return <div className="mx-auto max-w-3xl p-6"><p role="alert" className="text-red-700">{error || 'Event staff could not be loaded.'}</p><button disabled={refreshing} onClick={load} className="btn-secondary mt-4">Retry staff list</button></div>
  if (event.permissions?.manage_staff !== true) return <EventAccessNotice event={event} message="Your role doesn’t include managing this event’s team. Ask your organization owner if you need it." />
  const locked = refreshing || busy || Boolean(pending)
  return (
    <EventWorkspace eventId={id} event={event}><main className="mx-auto max-w-3xl">
      <div className="mt-5 flex items-start gap-3"><UserRoundCog className="mt-1 h-6 w-6 text-brand-600" /><div><h2 className="text-2xl font-bold text-neutral-950">Event team</h2><p className="mt-1 text-sm text-neutral-500">{event?.title} · assignments can expire or be revoked without changing organization membership.</p></div></div>
      {error && <div role="alert" className="mt-6 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{error}</div>}

      <div className="mt-4 flex flex-wrap items-center gap-3"><button disabled={busy || refreshing} onClick={load} className="btn-secondary">{refreshing ? 'Refreshing staff…' : 'Refresh saved staff'}</button></div>
      {pending && <div role="status" className="mt-4 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950"><p>{pending.label} may have completed. Review the refreshed staff list before making another change.</p><button disabled={busy || refreshing || !reviewed} onClick={acknowledge} className="btn-secondary mt-3">I verified the staff list</button></div>}
      {notice && <p role="status" className="mt-4 rounded-xl border border-brand-200 bg-brand-50 p-3 text-sm text-brand-900">{notice}</p>}
      {link && <InvitationLinkPanel url={link.url} email={link.email} onDismiss={() => setLink(null)} />}
      <section className="mt-8 rounded-2xl border border-neutral-200 bg-white p-5" aria-labelledby="invite-staff-heading">
        <h2 id="invite-staff-heading" className="flex items-center gap-2 font-semibold text-neutral-900"><UserPlus aria-hidden="true" className="h-4 w-4 text-brand-600" />Invite door staff by email</h2>
        <p className="mt-1 text-sm text-content-muted">They get an email and can work this event as soon as they accept. They only see the events you assign.</p>
        <form onSubmit={inviteStaff} className="mt-4 space-y-4">
          <label className="block text-sm font-medium text-neutral-900">
            Email
            <input type="email" required disabled={locked} value={inviteEmail} onChange={event => setInviteEmail(event.target.value)} className="input mt-1" placeholder="door.staff@example.com" autoComplete="off" />
          </label>
          <RoleRadioGroup legend="What will they do?" roles={EVENT_INVITE_ROLES} value={inviteRole} onChange={setInviteRole} disabled={locked} name="event-invite-role" />
          <button disabled={locked || !inviteEmail.trim()} className="btn-primary w-full sm:w-auto">Send invitation</button>
        </form>
      </section>

      {invitations.length > 0 && (
        <section className="mt-6 rounded-2xl border border-neutral-200 bg-white" aria-labelledby="pending-staff-heading">
          <div className="border-b border-neutral-100 px-5 py-4"><h2 id="pending-staff-heading" className="font-semibold text-neutral-900">Waiting to accept</h2></div>
          <ul className="divide-y divide-neutral-100">
            {invitations.map(invitation => (
              <li key={invitation.membership_id} className="flex flex-col gap-3 px-5 py-4 sm:flex-row sm:items-center sm:justify-between">
                <div className="min-w-0">
                  <p className="flex flex-wrap items-center gap-2 font-medium text-neutral-900"><span className="[overflow-wrap:anywhere]">{invitation.email}</span><InvitationStatusPill status={invitation.invitation_status} /></p>
                  <p className="text-sm text-content-muted">{label(invitation.role)} · <Mail aria-hidden="true" className="inline h-3.5 w-3.5" /> {invitation.invitation_status === 'expired' ? 'The link expired. Resend to email a new one.' : emailDeliveryLabel(invitation.email_delivery)}</p>
                </div>
                <div className="flex gap-2">
                  <button type="button" disabled={locked} onClick={() => resendInvitation(invitation)} className="btn-secondary gap-2 !px-3 !py-2 text-sm"><RotateCw aria-hidden="true" className="h-4 w-4" />Resend</button>
                  <button type="button" disabled={locked} onClick={() => withdrawInvitation(invitation)} className="inline-flex min-h-11 min-w-11 items-center justify-center rounded-lg text-red-700 [@media(hover:hover)]:hover:bg-red-50" aria-label={`Withdraw invitation for ${invitation.email}`}><Trash2 aria-hidden="true" className="h-4 w-4" /></button>
                </div>
              </li>
            ))}
          </ul>
        </section>
      )}

      <section className="mt-6 rounded-2xl border border-neutral-200 bg-white p-5">
        <h2 className="font-semibold text-neutral-900">Assign someone already on your team</h2>
        <form onSubmit={assign} className="mt-4 grid gap-3 sm:grid-cols-[1fr_14rem_auto] sm:items-start">
          <select disabled={locked} required value={userId} onChange={event => setUserId(event.target.value)} className="input" aria-label="Team member">
            <option value="">Choose a team member</option>
            {candidates.map(candidate => <option key={candidate.user_id} value={candidate.user_id}>{candidate.name || candidate.email} · {label(candidate.organization_role)}</option>)}
          </select>
          <RoleSelect label="Event role" roles={EVENT_ASSIGNMENT_ROLES} value={role} onChange={setRole} disabled={locked} />
          <button disabled={locked || !userId} className="btn-primary">Assign</button>
        </form>
        {candidates.length === 0 && <p className="mt-3 text-sm text-content-muted">No one else has joined your team yet. Invite door staff by email above.</p>}
      </section>

      <section className="mt-6 overflow-hidden rounded-2xl border border-neutral-200 bg-white">
        <div className="border-b border-neutral-100 px-5 py-4"><h2 className="font-semibold text-neutral-900">Current assignments</h2></div>
        <div className="divide-y divide-neutral-100">
          {assignments.map(assignment => (
            <div key={assignment.id} className="flex items-center justify-between gap-3 px-5 py-4">
              <div><p className="font-medium text-neutral-900">{assignment.email}</p><p className="text-sm text-neutral-500">{label(assignment.role)} · {label(assignment.status)}</p></div>
              <button disabled={locked || assignment.status === 'revoked'} onClick={() => revoke(assignment)} className="rounded-lg p-2 text-red-600 hover:bg-red-50" aria-label={`Revoke ${assignment.email}`}><Trash2 className="h-4 w-4" /></button>
            </div>
          ))}
          {assignments.length === 0 && <p className="px-5 py-8 text-center text-sm text-neutral-500">No event-specific assignments yet.</p>}
        </div>
      </section>
    </main></EventWorkspace>
  )
}

export default function EventStaffPage() {
  const { id } = useParams()
  const identity = useOrganizerIdentity()
  const visit = useOrganizerPageVisit(`/dashboard/events/${id}/team`)
  if (!visit.active) return null
  if (!identity.ready) return <p role="status" className="p-6">Preparing your account…</p>
  return <EventStaffSession key={`${identity.accountKey}:${identity.organizationId}:${id}:${visit.generation}`} id={id} identity={identity} />
}
