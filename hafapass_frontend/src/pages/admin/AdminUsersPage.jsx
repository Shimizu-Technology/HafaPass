import { useState, useEffect, useCallback, useRef } from 'react'
import { Loader2, Search, ChevronLeft, ChevronRight } from 'lucide-react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'
import { usePlatformIdentity, usePlatformVisit, usePlatformRequests } from '../../hooks/usePlatformContext'
import PaymentReadinessReviewDialog from '../../components/PaymentReadinessReviewDialog'

const roles = ['', 'attendee', 'organizer', 'support', 'admin']

function OrganizerReadiness({ user, reviewOrganizer, syncConnectedAccount, fetchUsers }) {
  const profile = user.organizer_profile
  if (!profile) return <p className="text-sm text-content-muted">No organizer profile.</p>
  const account = profile.connected_account

  return (
    <div className="min-w-0 space-y-2 lg:min-w-[13rem]">
      <p className="break-words font-medium text-neutral-800">{profile.business_name}</p>
      <select value={profile.verification_status} onChange={event => reviewOrganizer(user, event.target.value)}
        aria-label={`Verification status for ${profile.business_name || user.email}`} className="input min-h-11 !text-sm">
        {['unverified', 'pending', 'verified', 'rejected', 'suspended'].map(status => <option key={status} value={status}>{status}</option>)}
      </select>
      {account ? (
        <div className="rounded-lg border border-neutral-200 bg-neutral-50 p-3 text-sm">
          <p className="break-words font-semibold text-neutral-800">{account.provider} · {account.status}</p>
          <p className="mt-1 [overflow-wrap:anywhere] text-content-muted">{account.requirements_due?.length ? `Due: ${account.requirements_due.join(', ')}` : 'No outstanding requirements'}</p>
          <div className="mt-2 flex flex-wrap gap-2">
            {!profile.payout_ready && <button onClick={() => {
              if (window.confirm('Record the provider capability sync? Independent Gate B evidence approval will still be required.')) syncConnectedAccount(user, { charges_enabled: true, payouts_enabled: true, details_submitted: true, requirements_due: [] })
            }} className="min-h-11 rounded px-2 font-semibold text-emerald-700 hover:bg-emerald-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus">Record provider status</button>}
            {account.status !== 'disabled' && <button onClick={() => syncConnectedAccount(user, { disabled: true })} className="min-h-11 rounded px-2 font-semibold text-red-700 hover:bg-red-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus">Disable</button>}
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
      .catch(() => { if (active()) setLoadError('Could not load users. Your filters have been kept.') })
      .finally(() => { request.release(); if (active()) setLoading(false) })
  }, [page, search, roleFilter, beginRequest])

  useEffect(() => { fetchUsers(); return () => pendingLoad.current?.abort() }, [fetchUsers])

  const changeRole = async (user, newRole) => {
    if (newRole === 'admin' && !window.confirm(`Promote ${user.email} to admin? This grants full platform access.`)) return
    if (mutationBusy.current) return
    const request = beginRequest()
    if (!request) return
    mutationBusy.current = true
    setActionError('')
    try {
      const res = await apiClient.patch(`/admin/users/${user.id}`, { role: newRole }, request.config)
      if (!request.current()) return
      setUsers(prev => prev.map(u => u.id === user.id ? res.data : u))
    } catch (err) {
      if (request.current()) setActionError(err.response?.data?.error || 'The update was not confirmed. Review the saved user before trying again.')
    } finally { request.release(); mutationBusy.current = false }
  }

  const updateOrganizer = async (user, updates) => {
    const profile = user.organizer_profile
    if (!profile) return
    if (mutationBusy.current) return
    const request = beginRequest()
    if (!request) return
    mutationBusy.current = true
    setActionError('')
    try {
      const response = await apiClient.patch(`/admin/organizer_profiles/${profile.id}`, updates, request.config)
      if (!request.current()) return
      setUsers(current => current.map(item => item.id === user.id ? { ...item, organizer_profile: { ...profile, ...response.data } } : item))
    } catch (err) {
      if (request.current()) setActionError(err.response?.data?.error || 'The update was not confirmed. Review the saved user before trying again.')
    } finally { request.release(); mutationBusy.current = false }
  }

  const reviewOrganizer = (user, verificationStatus) => {
    let verificationNotes = user.organizer_profile?.verification_notes || ''
    if (['rejected', 'suspended'].includes(verificationStatus)) {
      const note = window.prompt('Add a review note explaining what the organizer must address:', verificationNotes)
      if (note === null) return
      verificationNotes = note
    }
    updateOrganizer(user, { verification_status: verificationStatus, verification_notes: verificationNotes })
  }

  const syncConnectedAccount = async (user, updates) => {
    const account = user.organizer_profile?.connected_account
    if (!account) return
    if (mutationBusy.current) return
    const request = beginRequest()
    if (!request) return
    mutationBusy.current = true
    setActionError('')
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
      if (request.current()) setActionError(err.response?.data?.error || 'The update was not confirmed. Review the saved user before trying again.')
    } finally { request.release(); mutationBusy.current = false }
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
          <option value="">All Roles</option>
          {roles.filter(Boolean).map(r => <option key={r} value={r}>{r}</option>)}
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
                    <th className="px-4 py-3 font-medium">Name</th>
                    <th className="px-4 py-3 font-medium">Email</th>
                    <th className="px-4 py-3 font-medium">Role</th>
                    <th className="px-4 py-3 font-medium">Organizer readiness</th>
                    <th className="px-4 py-3 font-medium text-right hidden md:table-cell">Orders</th>
                    <th className="px-4 py-3 font-medium hidden md:table-cell">Created</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-neutral-100">
                  {users.map(user => (
                    <tr key={user.id} className="hover:bg-neutral-50/50 transition-colors">
                      <td className="px-4 py-3 font-medium text-neutral-900">{user.first_name} {user.last_name}</td>
                      <td className="px-4 py-3 text-neutral-500">{user.email}</td>
                      <td className="px-4 py-3">
                        <select
                          value={user.role}
                          aria-label={`Role for ${user.email}`}
                          onChange={e => changeRole(user, e.target.value)}
                          className={`min-h-11 text-sm px-2 py-1 rounded-lg font-medium border border-neutral-200 cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus ${roleBadge(user.role)}`}
                        >
                          {roles.filter(Boolean).map(r => <option key={r} value={r}>{r}</option>)}
                        </select>
                      </td>
                      <td className="px-4 py-3 text-content-muted">
                        <OrganizerReadiness user={user} reviewOrganizer={reviewOrganizer} syncConnectedAccount={syncConnectedAccount} fetchUsers={fetchUsers} />
                      </td>
                      <td className="px-4 py-3 text-right text-neutral-700 hidden md:table-cell">{user.orders_count}</td>
                      <td className="px-4 py-3 text-neutral-500 hidden md:table-cell">{new Date(user.created_at).toLocaleDateString()}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="grid gap-4 p-4 lg:hidden">
              {users.map(user => (
                <article key={user.id} aria-label={`User ${user.email}`} className="min-w-0 rounded-xl border border-neutral-200 bg-white p-4">
                  <h2 className="break-words font-semibold text-neutral-900">{user.first_name} {user.last_name}</h2>
                  <p className="mt-1 break-all text-sm text-content-muted">{user.email}</p>
                  <label className="mt-4 block text-sm font-medium text-neutral-800">
                    Platform role
                    <select value={user.role} aria-label={`Role for ${user.email}`} onChange={event => changeRole(user, event.target.value)} className={`input mt-1 min-h-11 ${roleBadge(user.role)}`}>
                      {roles.filter(Boolean).map(role => <option key={role} value={role}>{role}</option>)}
                    </select>
                  </label>
                  <section aria-label={`Organizer readiness for ${user.email}`} className="mt-4 border-t border-neutral-200 pt-4">
                    <h3 className="mb-2 text-sm font-semibold text-neutral-900">Organizer readiness</h3>
                    <OrganizerReadiness user={user} reviewOrganizer={reviewOrganizer} syncConnectedAccount={syncConnectedAccount} fetchUsers={fetchUsers} />
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
    </AdminLayout>
  )
}

export default function AdminUsersPage() {
  const identity = usePlatformIdentity()
  const visit = usePlatformVisit('/admin/users')
  if (!visit.active) return null
  if (!identity.ready) return <p role="status">Checking account access…</p>
  return <AdminUsersPageSession key={`${identity.accountKey}:${visit.generation}`} identity={identity} resourcePath="/admin/users" />
}
