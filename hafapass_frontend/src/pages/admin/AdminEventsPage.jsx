import { useState, useEffect, useCallback } from 'react'
import { Link } from 'react-router-dom'
import { Loader2, Search, Star, ChevronLeft, ChevronRight } from 'lucide-react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'

const statuses = ['', 'draft', 'published', 'cancelled', 'completed']
const categories = ['', 'nightlife', 'concert', 'festival', 'dining', 'sports', 'other']

export default function AdminEventsPage() {
  const [events, setEvents] = useState([])
  const [meta, setMeta] = useState({})
  const [loading, setLoading] = useState(true)
  const [search, setSearch] = useState('')
  const [status, setStatus] = useState('')
  const [category, setCategory] = useState('')
  const [page, setPage] = useState(1)

  const fetchEvents = useCallback(() => {
    setLoading(true)
    const params = { page, per_page: 20 }
    if (search) params.search = search
    if (status) params.status = status
    if (category) params.category = category
    apiClient.get('/admin/events', { params })
      .then(res => { setEvents(res.data.events); setMeta(res.data.meta) })
      .catch(console.error)
      .finally(() => setLoading(false))
  }, [page, search, status, category])

  useEffect(() => { fetchEvents() }, [fetchEvents])

  const toggleFeatured = async (event) => {
    try {
      const res = await apiClient.patch(`/admin/events/${event.id}`, { is_featured: !event.is_featured })
      setEvents(prev => prev.map(e => e.id === event.id ? res.data : e))
    } catch (err) { console.error(err) }
  }

  return (
    <AdminLayout>
      <div className="flex flex-col sm:flex-row gap-3 mb-6">
        <div className="relative flex-1">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-neutral-400" />
          <input
            type="text"
            placeholder="Search events..."
            value={search}
            onChange={e => { setSearch(e.target.value); setPage(1) }}
            className="w-full pl-10 pr-4 py-2.5 bg-white/70 border border-neutral-200/50 rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-brand-500/20 focus:border-brand-500"
          />
        </div>
        <select value={status} onChange={e => { setStatus(e.target.value); setPage(1) }} className="px-4 py-2.5 bg-white/70 border border-neutral-200/50 rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-brand-500/20">
          <option value="">All Statuses</option>
          {statuses.filter(Boolean).map(s => <option key={s} value={s}>{s}</option>)}
        </select>
        <select value={category} onChange={e => { setCategory(e.target.value); setPage(1) }} className="px-4 py-2.5 bg-white/70 border border-neutral-200/50 rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-brand-500/20">
          <option value="">All Categories</option>
          {categories.filter(Boolean).map(c => <option key={c} value={c}>{c}</option>)}
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
                  <th className="px-4 py-3 font-medium">Title</th>
                  <th className="px-4 py-3 font-medium hidden lg:table-cell">Organizer</th>
                  <th className="px-4 py-3 font-medium">Status</th>
                  <th className="px-4 py-3 font-medium hidden md:table-cell">Category</th>
                  <th className="px-4 py-3 font-medium text-right">Sold</th>
                  <th className="px-4 py-3 font-medium text-right hidden md:table-cell">Revenue</th>
                  <th className="px-4 py-3 font-medium text-center">★</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-neutral-100">
                {events.map(event => (
                  <tr key={event.id} className="hover:bg-neutral-50/50 transition-colors">
                    <td className="px-4 py-3">
                      <Link to={`/events/${event.slug}`} className="font-medium text-brand-600 hover:text-brand-700">{event.title}</Link>
                    </td>
                    <td className="px-4 py-3 text-neutral-500 hidden lg:table-cell">{event.organizer_name}</td>
                    <td className="px-4 py-3">
                      <span className={`text-xs px-2 py-1 rounded-full font-medium ${
                        event.status === 'published' ? 'bg-emerald-50 text-emerald-600' :
                        event.status === 'draft' ? 'bg-neutral-100 text-neutral-600' :
                        'bg-red-50 text-red-600'
                      }`}>{event.status}</span>
                    </td>
                    <td className="px-4 py-3 text-neutral-500 hidden md:table-cell capitalize">{event.category}</td>
                    <td className="px-4 py-3 text-right text-neutral-700">{event.tickets_sold}</td>
                    <td className="px-4 py-3 text-right text-neutral-700 hidden md:table-cell">${(event.revenue_cents / 100).toFixed(2)}</td>
                    <td className="px-4 py-3 text-center">
                      <button onClick={() => toggleFeatured(event)} className="p-1 rounded-lg hover:bg-neutral-100 transition-colors">
                        <Star className={`w-4 h-4 ${event.is_featured ? 'fill-amber-400 text-amber-400' : 'text-neutral-300'}`} />
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {events.length === 0 && <p className="text-center py-8 text-neutral-400">No events found.</p>}
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
