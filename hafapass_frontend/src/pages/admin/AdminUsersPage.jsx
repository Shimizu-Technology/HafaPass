import { useState, useEffect, useCallback } from 'react'
import { Loader2, Search, ChevronLeft, ChevronRight } from 'lucide-react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'
import PaymentReadinessReviewDialog from '../../components/PaymentReadinessReviewDialog'

const roles = ['', 'attendee', 'organizer', 'support', 'admin']

export default function AdminUsersPage() {
  const [users, setUsers] = useState([])
  const [meta, setMeta] = useState({})
  const [loading, setLoading] = useState(true)
  const [search, setSearch] = useState('')
  const [roleFilter, setRoleFilter] = useState('')
  const [page, setPage] = useState(1)

  const fetchUsers = useCallback(() => {
    setLoading(true)
    const params = { page, per_page: 20 }
    if (search) params.search = search
    if (roleFilter) params.role = roleFilter
    apiClient.get('/admin/users', { params })
      .then(res => { setUsers(res.data.users); setMeta(res.data.meta) })
      .catch(console.error)
      .finally(() => setLoading(false))
  }, [page, search, roleFilter])

  useEffect(() => { fetchUsers() }, [fetchUsers])

  const changeRole = async (user, newRole) => {
    if (newRole === 'admin' && !window.confirm(`Promote ${user.email} to admin? This grants full platform access.`)) return
    try {
      const res = await apiClient.patch(`/admin/users/${user.id}`, { role: newRole })
      setUsers(prev => prev.map(u => u.id === user.id ? res.data : u))
    } catch (err) { console.error(err) }
  }

  const updateOrganizer = async (user, updates) => {
    const profile = user.organizer_profile
    if (!profile) return
    try {
      const response = await apiClient.patch(`/admin/organizer_profiles/${profile.id}`, updates)
      setUsers(current => current.map(item => item.id === user.id ? { ...item, organizer_profile: { ...profile, ...response.data } } : item))
    } catch (err) { console.error(err) }
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
    try {
      const response = await apiClient.patch(`/admin/connected_accounts/${account.id}`, updates)
      setUsers(current => current.map(item => item.id === user.id ? {
        ...item,
        organizer_profile: {
          ...item.organizer_profile,
          payout_ready: response.data.payout_ready,
          connected_account: response.data
        }
      } : item))
    } catch (err) { console.error(err) }
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
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-neutral-400" />
          <input
            type="text"
            placeholder="Search by name or email..."
            value={search}
            onChange={e => { setSearch(e.target.value); setPage(1) }}
            className="w-full pl-10 pr-4 py-2.5 bg-white/70 border border-neutral-200/50 rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-brand-500/20 focus:border-brand-500"
          />
        </div>
        <select value={roleFilter} onChange={e => { setRoleFilter(e.target.value); setPage(1) }} className="px-4 py-2.5 bg-white/70 border border-neutral-200/50 rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-brand-500/20">
          <option value="">All Roles</option>
          {roles.filter(Boolean).map(r => <option key={r} value={r}>{r}</option>)}
        </select>
      </div>

      <div className="bg-white/70 backdrop-blur-sm rounded-xl border border-neutral-200/50 shadow-soft overflow-hidden">
        {loading ? (
          <div className="flex justify-center py-12"><Loader2 className="w-6 h-6 text-brand-500 animate-spin" /></div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-neutral-100 text-left text-neutral-500">
                  <th className="px-4 py-3 font-medium">Name</th>
                  <th className="px-4 py-3 font-medium">Email</th>
                  <th className="px-4 py-3 font-medium">Role</th>
                  <th className="px-4 py-3 font-medium hidden lg:table-cell">Organizer readiness</th>
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
                        onChange={e => changeRole(user, e.target.value)}
                        className={`text-xs px-2 py-1 rounded-full font-medium border-0 cursor-pointer ${roleBadge(user.role)}`}
                      >
                        {roles.filter(Boolean).map(r => <option key={r} value={r}>{r}</option>)}
                      </select>
                    </td>
                    <td className="px-4 py-3 text-neutral-500 hidden lg:table-cell">
                      {user.organizer_profile ? (
                        <div className="space-y-2 min-w-[13rem]">
                          <p className="font-medium text-neutral-800">{user.organizer_profile.business_name}</p>
                          <select value={user.organizer_profile.verification_status} onChange={event => reviewOrganizer(user, event.target.value)} className="input !py-1 !text-xs">
                            {['unverified', 'pending', 'verified', 'rejected', 'suspended'].map(status => <option key={status} value={status}>{status}</option>)}
                          </select>
                          {user.organizer_profile.connected_account ? (
                            <div className="rounded-lg border border-neutral-200 bg-neutral-50 p-2 text-xs">
                              <p className="font-semibold text-neutral-800">{user.organizer_profile.connected_account.provider} · {user.organizer_profile.connected_account.status}</p>
                              <p className="mt-1 text-neutral-500">{user.organizer_profile.connected_account.requirements_due?.length ? `Due: ${user.organizer_profile.connected_account.requirements_due.join(', ')}` : 'No outstanding requirements'}</p>
                              <div className="mt-2 flex gap-2">
                                {!user.organizer_profile.payout_ready && <button onClick={() => {
                                  if (window.confirm('Record the provider capability sync? Independent Gate B evidence approval will still be required.')) syncConnectedAccount(user, { charges_enabled: true, payouts_enabled: true, details_submitted: true, requirements_due: [] })
                                }} className="font-semibold text-emerald-700 hover:text-emerald-800">Record provider status</button>}
                                {user.organizer_profile.connected_account.status !== 'disabled' && <button onClick={() => syncConnectedAccount(user, { disabled: true })} className="font-semibold text-red-600 hover:text-red-700">Disable</button>}
                              </div>
                              {(user.organizer_profile.connected_account.requirements_due?.includes('independent_readiness_approval') || user.organizer_profile.connected_account.readiness_submission || user.organizer_profile.connected_account.readiness_approval) && (
                                <div className="mt-3 border-t border-neutral-200 pt-3">
                                  <PaymentReadinessReviewDialog account={user.organizer_profile.connected_account} onComplete={fetchUsers} />
                                </div>
                              )}
                            </div>
                          ) : <p className="text-xs text-amber-700">Organizer has not started payout onboarding.</p>}
                        </div>
                      ) : '—'}
                    </td>
                    <td className="px-4 py-3 text-right text-neutral-700 hidden md:table-cell">{user.orders_count}</td>
                    <td className="px-4 py-3 text-neutral-500 hidden md:table-cell">{new Date(user.created_at).toLocaleDateString()}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {users.length === 0 && <p className="text-center py-8 text-neutral-400">No users found.</p>}
          </div>
        )}
      </div>

      {meta.total_pages > 1 && (
        <div className="flex items-center justify-center gap-2 mt-6">
          <button onClick={() => setPage(p => Math.max(1, p - 1))} disabled={page === 1} className="p-2 rounded-xl border border-neutral-200/50 bg-white/70 disabled:opacity-40 hover:bg-neutral-50 transition-colors">
            <ChevronLeft className="w-4 h-4" />
          </button>
          <span className="text-sm text-neutral-600">Page {meta.page} of {meta.total_pages}</span>
          <button onClick={() => setPage(p => Math.min(meta.total_pages, p + 1))} disabled={page === meta.total_pages} className="p-2 rounded-xl border border-neutral-200/50 bg-white/70 disabled:opacity-40 hover:bg-neutral-50 transition-colors">
            <ChevronRight className="w-4 h-4" />
          </button>
        </div>
      )}
    </AdminLayout>
  )
}
