import { useState, useEffect, useCallback } from 'react'
import { Loader2, Search, ChevronLeft, ChevronRight } from 'lucide-react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'

const roles = ['', 'attendee', 'organizer', 'admin']

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

  const roleBadge = (role) => {
    const styles = {
      admin: 'bg-brand-50 text-brand-600',
      organizer: 'bg-indigo-50 text-indigo-600',
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
                  <th className="px-4 py-3 font-medium hidden lg:table-cell">Organizer</th>
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
                    <td className="px-4 py-3 text-neutral-500 hidden lg:table-cell">{user.organizer_profile?.business_name || '—'}</td>
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
