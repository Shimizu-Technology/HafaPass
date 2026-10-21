import AdminAccessRecovery from '../../components/AdminAccessRecovery'
import { useState, useEffect, useCallback, useRef } from 'react'
import { Loader2, Search, ChevronLeft, ChevronRight } from 'lucide-react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'
import { usePlatformIdentity, usePlatformVisit, usePlatformRequests } from '../../hooks/usePlatformContext'
import PaymentReadinessReviewDialog from '../../components/PaymentReadinessReviewDialog'
import Dialog from '../../components/Dialog'
import { adminLabel } from './adminLabels'
import StaffInvitationsPanel from './StaffInvitationsPanel'
import { PLATFORM_ROLES, roleLabel } from '../../utils/roles'

const roles = ['', 'attendee', 'organizer', 'support', 'admin']
// Platform access an admin can choose. "Organizer" is not a grant: it is the
// label for anyone on an organization team, derived by the API.
const accessOptions = [
  { value: 'member', label: 'No staff access', description: 'Buys tickets. Organizer tools come only from organization teams.' },
  { value: 'support', label: 'Support', description: PLATFORM_ROLES.support.description },
  { value: 'admin', label: 'Admin', description: PLATFORM_ROLES.admin.description },
]
const accessValue = role => ['attendee', 'organizer'].includes(role) ? 'member' : role
const accessLabel = value => accessOptions.find(option => option.value === accessValue(value))?.label || adminLabel(value)
const roleFilterLabel = role => role === 'organizer' ? 'Organizer (on a team)' : role === 'attendee' ? 'Attendee (no team)' : adminLabel(role)
const userEmail = (user, fallback = 'Email unavailable') => user.email?.trim() || fallback
const userLabel = user => userEmail(user, `User #${user.id}`)
const userName = user => [user.first_name, user.last_name].filter(name => name?.trim()).join(' ') || `User #${user.id}`
const verificationStatuses = ['unverified', 'pending', 'verified', 'rejected', 'suspended']
// Rejecting needs a fresh note (the backend requires one); pausing sales
// (suspended) takes an optional one.
const needsReviewNote = status => status === 'rejected'
const offersReviewNote = status => ['rejected', 'suspended'].includes(status)
// Suspending an organizer pauses all of its ticket sales.
const verificationLabel = status => status === 'suspended' ? 'Sales paused' : adminLabel(status)

// Every role or verification change is confirmed here. The selects stay bound to the
// saved value, so cancelling leaves them showing what the server last confirmed.
// The note field starts empty rather than carrying an earlier review's wording
// into the new status.
function ConfirmChangeDialog({ change, busy, onCancel, onConfirm }) {
  const [note, setNote] = useState('')
  const noteRequired = change.kind === 'verification' && needsReviewNote(change.to)
  const noteOffered = change.kind === 'verification' && offersReviewNote(change.to)
  const noteMissing = noteRequired && !note.trim()
  const subject = change.kind === 'role' ? userLabel(change.user) : change.user.organizer_profile?.business_name || userLabel(change.user)
  return (
    <Dialog labelledBy="confirm-change-title" onClose={onCancel} busy={busy} className="max-w-md">
      <h2 id="confirm-change-title" className="text-lg font-semibold text-neutral-900">{change.kind === 'role' ? 'Change platform role?' : 'Change verification status?'}</h2>
      <p className="mt-2 break-words text-sm text-content-muted">{subject}</p>
      <p className="mt-4 flex flex-wrap items-center gap-2 text-sm text-neutral-800">
        <span className="rounded-full bg-neutral-100 px-2.5 py-1 font-medium">{change.kind === 'role' ? accessLabel(change.from) : verificationLabel(change.from)}</span>
        <span aria-hidden="true">→</span>
        <span className="sr-only">to</span>
        <span className="rounded-full bg-brand-50 px-2.5 py-1 font-semibold text-brand-800">{change.kind === 'role' ? accessLabel(change.to) : verificationLabel(change.to)}</span>
      </p>
      {change.kind === 'role' && change.to === 'admin' && <p className="mt-4 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">This grants full platform access.</p>}
      {change.kind === 'verification' && change.to === 'suspended' && <p className="mt-4 text-sm text-neutral-700">Their events stay visible but stop selling until you verify them again.</p>}
      {noteOffered && (
        <label className="mt-4 block text-sm font-medium text-neutral-800">
          {noteRequired ? 'Review note' : 'Review note (optional)'}
          <span id="review-note-help" className="block font-normal text-content-muted">{noteRequired ? 'Required. Explain what the organizer must address.' : 'Shown to the organizer.'}</span>
          <textarea value={note} onChange={event => setNote(event.target.value)} rows={3} required={noteRequired} aria-required={noteRequired ? 'true' : undefined} aria-describedby="review-note-help" disabled={busy} className="input mt-1 !text-sm" />
        </label>
      )}
      <div className="mt-6 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
        <button type="button" onClick={onCancel} disabled={busy} className="btn-secondary min-h-11">Cancel</button>
        <button type="button" onClick={() => onConfirm(note.trim())} disabled={busy || noteMissing} className="btn-primary min-h-11 disabled:opacity-50">
          {busy ? 'Saving…' : change.kind === 'role' ? 'Change role' : 'Change status'}
        </button>
      </div>
    </Dialog>
  )
}

// Staff access plus the organizations that give this person organizer tools.
function AccessPicker({ user, busy, onChange, className = '' }) {
  const value = accessValue(user.role)
  const option = accessOptions.find(item => item.value === value)
  const descriptionId = `access-${user.id}-description`
  return (
    <div className="min-w-[12rem]">
      <select value={value} disabled={busy} aria-label={`Role for ${userLabel(user)}`} aria-describedby={descriptionId} onChange={event => onChange(event.target.value)}
        className={`input min-h-11 !py-1 !text-sm font-medium ${className}`}>
        {accessOptions.map(item => <option key={item.value} value={item.value}>{item.label}</option>)}
      </select>
      <p id={descriptionId} className="mt-1 text-xs font-normal text-content-muted">{option?.description}</p>
      <p className="mt-1 text-xs font-normal text-neutral-700">
        {user.organizations?.length
          ? user.organizations.map(item => `${item.name} · ${roleLabel(item.role)}`).join(', ')
          : 'Not on any organization team'}
      </p>
    </div>
  )
}

function OrganizerReadiness({ user, busy, reviewOrganizer, syncConnectedAccount, fetchUsers }) {
  const profile = user.organizer_profile
  if (!profile) return <p className="text-sm text-content-muted">No organizer profile.</p>
  const account = profile.connected_account

  return (
    <div className="min-w-0 space-y-2 lg:min-w-[13rem]">
      <p className="break-words font-medium text-neutral-800">{profile.business_name}</p>
      <select value={profile.verification_status} disabled={busy} onChange={event => reviewOrganizer(user, event.target.value)}
        aria-label={`Verification status for ${profile.business_name || userLabel(user)}`} className="input min-h-11 !text-sm">
        {verificationStatuses.map(status => <option key={status} value={status}>{verificationLabel(status)}</option>)}
      </select>
      {account ? (
        <div className="rounded-lg border border-neutral-200 bg-neutral-50 p-3 text-sm">
          <p className="break-words font-semibold text-neutral-800">{account.provider} · {account.status}</p>
          {account.provider === 'check' && account.payout_details?.payee_name && <p className="mt-1 [overflow-wrap:anywhere] text-neutral-800">Check to {account.payout_details.payee_name} · {account.payout_details.delivery_method === 'pickup' ? 'pickup' : 'mail'}</p>}
          <p className="mt-1 [overflow-wrap:anywhere] text-content-muted">{account.requirements_due?.length ? `Due: ${account.requirements_due.join(', ')}` : 'No outstanding requirements'}</p>
          <div className="mt-2 flex flex-wrap gap-2">
            {!profile.payout_ready && <button onClick={() => {
              if (window.confirm('Record the provider capability sync? Gate B evidence approval will still be required.')) syncConnectedAccount(user, { charges_enabled: true, payouts_enabled: true, details_submitted: true, requirements_due: [] })
            }} disabled={busy} className="min-h-11 rounded px-2 font-semibold text-emerald-700 hover:bg-emerald-50 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus">Record provider status</button>}
            {account.status !== 'disabled' && <button onClick={() => syncConnectedAccount(user, { disabled: true })} disabled={busy} className="min-h-11 rounded px-2 font-semibold text-red-700 hover:bg-red-50 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus">Disable</button>}
          </div>
          {(account.requirements_due?.includes('independent_readiness_approval') || account.readiness_submission || account.readiness_approval) && (
            <div className="mt-3 border-t border-neutral-200 pt-3">
              <PaymentReadinessReviewDialog account={account} onComplete={fetchUsers} />
            </div>
          )}
        </div>
      ) : <p className="text-sm text-amber-800">Organizer has not started payout onboarding.</p>}
    </div>
  )
}

function AdminUsersPageSession({ identity, resourcePath }) {
  const { beginRequest } = usePlatformRequests(identity, resourcePath)
  const loadGeneration = useRef(0)
  const pendingLoad = useRef(null)
  const mutationBusy = useRef(false)
  const [loadError, setLoadError] = useState('')
  const [actionError, setActionError] = useState('')
  const [users, setUsers] = useState([])
  const [meta, setMeta] = useState({})
  const [loading, setLoading] = useState(true)
  const [search, setSearch] = useState('')
  const [roleFilter, setRoleFilter] = useState('')
  const [page, setPage] = useState(1)
  const [pendingChange, setPendingChange] = useState(null)
  const [busy, setBusy] = useState(false)

  // One saved change at a time. A refused second change says so instead of vanishing.
  const mutationAvailable = () => {
    if (!mutationBusy.current) return true
    setActionError('Another change is still saving. Wait for it to finish, then try again.')
    return false
  }
  const startMutation = () => { mutationBusy.current = true; setBusy(true); setActionError('') }
  const endMutation = () => { mutationBusy.current = false; setBusy(false) }

  const fetchUsers = useCallback(() => {
    const request = beginRequest()
    if (!request) return
    pendingLoad.current?.abort()
    pendingLoad.current = request
    const generation = ++loadGeneration.current
    const active = () => request.current() && generation === loadGeneration.current
    setLoading(true)
    setLoadError('')
    const params = { page, per_page: 20 }
    if (search) params.search = search
    if (roleFilter) params.role = roleFilter
    apiClient.get('/admin/users', { ...request.config, params })
      .then(res => { if (active()) { setUsers(res.data.users); setMeta(res.data.meta); } })
      .catch(error => { if (active() && !request.handleError(error)) setLoadError('Could not load users. Your filters have been kept.') })
      .finally(() => { request.release(); if (active()) setLoading(false) })
  }, [page, search, roleFilter, beginRequest])

  useEffect(() => { fetchUsers(); return () => pendingLoad.current?.abort() }, [fetchUsers])

  const requestRoleChange = (user, newAccess) => {
    const newRole = newAccess === 'member' ? 'attendee' : newAccess
    if (newAccess === accessValue(user.role) || !mutationAvailable()) return
    setPendingChange({ kind: 'role', user, from: user.role, to: newRole })
  }

  const changeRole = async (user, newRole) => {
    if (!mutationAvailable()) return
    const request = beginRequest()
    if (!request) return
    startMutation()
    try {
      const res = await apiClient.patch(`/admin/users/${user.id}`, { role: newRole }, request.config)
      if (!request.current()) return
      setUsers(prev => prev.map(u => u.id === user.id ? res.data : u))
    } catch (err) {
      if (request.handleError(err)) return
      if (request.current()) setActionError(err.response?.data?.error || 'The update was not confirmed. Review the saved user before trying again.')
    } finally { request.release(); endMutation() }
  }

  const updateOrganizer = async (user, updates) => {
    const profile = user.organizer_profile
    if (!profile) return
    if (!mutationAvailable()) return
    const request = beginRequest()
    if (!request) return
    startMutation()
    try {
      const response = await apiClient.patch(`/admin/organizer_profiles/${profile.id}`, updates, request.config)
      if (!request.current()) return
      setUsers(current => current.map(item => item.id === user.id ? { ...item, organizer_profile: { ...profile, ...response.data } } : item))
    } catch (err) {
      if (request.handleError(err)) return
      if (request.current()) setActionError(err.response?.data?.error || 'The update was not confirmed. Review the saved user before trying again.')
    } finally { request.release(); endMutation() }
  }

  const reviewOrganizer = (user, verificationStatus) => {
    const profile = user.organizer_profile
    if (!profile || verificationStatus === profile.verification_status || !mutationAvailable()) return
    setPendingChange({ kind: 'verification', user, from: profile.verification_status, to: verificationStatus, note: profile.verification_notes || '' })
  }

  // The dialog stays open (and busy) until the server answers, then closes either way;
  // a failure is reported in the page alert.
  const confirmChange = async note => {
    const change = pendingChange
    if (!change) return
    if (change.kind === 'role') await changeRole(change.user, change.to)
    else {
      if (needsReviewNote(change.to) && !note) return
      // An optional pause note replaces the old one only when given.
      const verificationNotes = offersReviewNote(change.to) && note ? note : change.note
      await updateOrganizer(change.user, { verification_status: change.to, verification_notes: verificationNotes })
    }
    setPendingChange(null)
  }

  const syncConnectedAccount = async (user, updates) => {
    const account = user.organizer_profile?.connected_account
    if (!account) return
    if (!mutationAvailable()) return
    const request = beginRequest()
    if (!request) return
    startMutation()
    try {
      const response = await apiClient.patch(`/admin/connected_accounts/${account.id}`, updates, request.config)
      if (!request.current()) return
      setUsers(current => current.map(item => item.id === user.id ? {
        ...item,
        organizer_profile: {
          ...item.organizer_profile,
          payout_ready: response.data.payout_ready,
          connected_account: response.data
        }
      } : item))
    } catch (err) {
      if (request.handleError(err)) return
      if (request.current()) setActionError(err.response?.data?.error || 'The update was not confirmed. Review the saved user before trying again.')
    } finally { request.release(); endMutation() }
  }

  const roleBadge = (role) => {
    const styles = {
      admin: 'bg-brand-50 text-brand-600',
      organizer: 'bg-indigo-50 text-indigo-600',
      support: 'bg-amber-50 text-amber-700',
      attendee: 'bg-neutral-100 text-neutral-600',
    }
    return styles[role] || styles.attendee
  }

  return (
    <AdminLayout>
      <StaffInvitationsPanel beginRequest={beginRequest} />
      <div className="flex flex-col sm:flex-row gap-3 mb-6">
        <div className="relative flex-1">
          <Search aria-hidden="true" className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-content-muted" />
          <input
            type="text"
            aria-label="Search users by name or email"
            placeholder="Search by name or email..."
            value={search}
            onChange={e => { setSearch(e.target.value); setPage(1) }}
            className="input min-h-11 !pl-10 !text-sm"
          />
        </div>
        <select aria-label="Filter users by role" value={roleFilter} onChange={e => { setRoleFilter(e.target.value); setPage(1) }} className="input min-h-11 !text-sm sm:w-auto">
          <option value="">All people</option>
          {roles.filter(Boolean).map(r => <option key={r} value={r}>{roleFilterLabel(r)}</option>)}
        </select>
      </div>

      {actionError && <p role="alert" className="mb-4 rounded-lg border border-red-200 bg-red-50 p-3 text-red-700">{actionError}</p>}
      <div className="rounded-xl border border-neutral-200 bg-white overflow-hidden">
        {loading ? (
          <div role="status" aria-label="Loading users" className="flex justify-center py-12"><Loader2 aria-hidden="true" className="w-6 h-6 text-brand-700 animate-spin motion-reduce:animate-none" /></div>
        ) : loadError ? (
          <div role="alert" className="p-5 text-red-700">{loadError} <button onClick={fetchUsers} className="min-h-11 rounded px-3 font-semibold underline focus-visible:ring-2 focus-visible:ring-focus">Try again</button></div>
        ) : (
          <div>
            <div className="overflow-x-auto hidden lg:block">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-neutral-100 text-left text-neutral-500">
                    <th className="min-w-[14rem] px-4 py-3 font-medium">User</th>
                    <th className="px-3 py-3 font-medium">Platform access</th>
                    <th className="px-3 py-3 font-medium">Organizer readiness</th>
                    <th className="px-3 py-3 font-medium text-right">Orders</th>
                    <th className="px-3 py-3 font-medium">Created</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-neutral-100">
                  {users.map(user => (
                    <tr key={user.id} className="hover:bg-neutral-50/50 transition-colors">
                      <td className="min-w-[14rem] px-4 py-3">
                        <p className="font-medium text-neutral-900">{userName(user)}</p>
                        <p className="text-xs text-neutral-500 [overflow-wrap:anywhere]">{userEmail(user)}</p>
                      </td>
                      <td className="px-3 py-3">
                        <AccessPicker user={user} busy={busy} onChange={next => requestRoleChange(user, next)} className={roleBadge(user.role)} />
                      </td>
                      <td className="px-3 py-3 text-content-muted">
                        <OrganizerReadiness user={user} busy={busy} reviewOrganizer={reviewOrganizer} syncConnectedAccount={syncConnectedAccount} fetchUsers={fetchUsers} />
                      </td>
                      <td className="whitespace-nowrap px-3 py-3 text-right text-neutral-700">{user.orders_count}</td>
                      <td className="whitespace-nowrap px-3 py-3 text-neutral-500">{new Date(user.created_at).toLocaleDateString()}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="grid gap-4 p-4 lg:hidden">
              {users.map(user => (
                <article key={user.id} aria-label={userEmail(user, '') ? `User ${userLabel(user)}` : userLabel(user)} className="min-w-0 rounded-xl border border-neutral-200 bg-white p-4">
                  <h2 className="break-words font-semibold text-neutral-900">{userName(user)}</h2>
                  <p className="mt-1 break-all text-sm text-content-muted">{userEmail(user)}</p>
                  <div className="mt-4 text-sm font-medium text-neutral-800">
                    <p className="mb-1">Platform access</p>
                    <AccessPicker user={user} busy={busy} onChange={next => requestRoleChange(user, next)} className={roleBadge(user.role)} />
                  </div>
                  <section aria-label={`Organizer readiness for ${userLabel(user)}`} className="mt-4 border-t border-neutral-200 pt-4">
                    <h3 className="mb-2 text-sm font-semibold text-neutral-900">Organizer readiness</h3>
                    <OrganizerReadiness user={user} busy={busy} reviewOrganizer={reviewOrganizer} syncConnectedAccount={syncConnectedAccount} fetchUsers={fetchUsers} />
                  </section>
                  <dl className="mt-4 flex flex-wrap gap-x-6 gap-y-2 text-sm text-content-muted">
                    <div><dt className="inline">Orders: </dt><dd className="inline font-medium text-neutral-800">{user.orders_count}</dd></div>
                    <div><dt className="inline">Joined: </dt><dd className="inline">{new Date(user.created_at).toLocaleDateString()}</dd></div>
                  </dl>
                </article>
              ))}
            </div>
            {users.length === 0 && <p className="text-center py-8 text-content-muted">No users found.</p>}
          </div>
        )}
      </div>

      {meta.total_pages > 1 && (
        <div className="flex items-center justify-center gap-2 mt-6">
          <button aria-label="Previous page of users" onClick={() => setPage(p => Math.max(1, p - 1))} disabled={page === 1} className="min-h-11 min-w-11 p-2 rounded-xl border border-neutral-200/50 bg-white/70 disabled:opacity-40 hover:bg-neutral-50 transition-colors">
            <ChevronLeft className="w-4 h-4" />
          </button>
          <span className="text-sm text-neutral-600">Page {meta.page} of {meta.total_pages}</span>
          <button aria-label="Next page of users" onClick={() => setPage(p => Math.min(meta.total_pages, p + 1))} disabled={page === meta.total_pages} className="min-h-11 min-w-11 p-2 rounded-xl border border-neutral-200/50 bg-white/70 disabled:opacity-40 hover:bg-neutral-50 transition-colors">
            <ChevronRight className="w-4 h-4" />
          </button>
        </div>
      )}
      {pendingChange && <ConfirmChangeDialog change={pendingChange} busy={busy} onCancel={() => setPendingChange(null)} onConfirm={confirmChange} />}
    </AdminLayout>
  )
}

export default function AdminUsersPage() {
  const identity = usePlatformIdentity('admin')
  const visit = usePlatformVisit('/admin/users')
  if (!visit.active) return null
  if (identity.authorityDenied) return <AdminAccessRecovery key={identity.accountKey} identity={identity} />
  if (!identity.ready) return <p role="status">Checking account access…</p>
  return <AdminUsersPageSession key={`${identity.accountKey}:${visit.generation}`} identity={identity} resourcePath="/admin/users" />
}
