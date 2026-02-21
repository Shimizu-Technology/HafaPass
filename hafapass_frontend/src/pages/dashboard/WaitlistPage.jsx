import { useState, useEffect } from 'react'
import { useParams, Link } from 'react-router-dom'
import { ArrowLeft, Bell, Trash2, Loader2, ClipboardList, Send } from 'lucide-react'
import apiClient from '../../api/client'

const STATUS_COLORS = {
  waiting: 'bg-amber-50 text-amber-700',
  notified: 'bg-blue-50 text-blue-700',
  offered: 'bg-indigo-50 text-indigo-700',
  converted: 'bg-emerald-50 text-emerald-700',
  expired: 'bg-neutral-100 text-neutral-500',
  cancelled: 'bg-red-50 text-red-600',
}

export default function WaitlistPage() {
  const { id: eventId } = useParams()
  const [entries, setEntries] = useState([])
  const [stats, setStats] = useState({})
  const [loading, setLoading] = useState(true)
  const [filter, setFilter] = useState('')
  const [notifyCount, setNotifyCount] = useState(1)
  const [notifying, setNotifying] = useState(false)

  const fetchData = async () => {
    try {
      const params = filter ? { status: filter } : {}
      const res = await apiClient.get(`/organizer/events/${eventId}/waitlist`, { params })
      setEntries(res.data.waitlist || [])
      setStats(res.data.stats || {})
    } catch (e) {
      console.error(e)
    }
    setLoading(false)
  }

  useEffect(() => { fetchData() }, [eventId, filter])

  const handleNotify = async (entry) => {
    if (!confirm(`Notify ${entry.name || entry.email} that tickets are available?`)) return
    try {
      await apiClient.post(`/organizer/events/${eventId}/waitlist/${entry.id}/notify`)
      fetchData()
    } catch (e) {
      alert(e.response?.data?.error || 'Error notifying')
    }
  }

  const handleNotifyNext = async () => {
    if (!confirm(`Notify the next ${notifyCount} people on the waitlist?`)) return
    setNotifying(true)
    try {
      const res = await apiClient.post(`/organizer/events/${eventId}/waitlist/notify_next`, { count: notifyCount })
      alert(`Notified ${res.data.count} people`)
      fetchData()
    } catch (e) {
      alert(e.response?.data?.error || 'Error')
    }
    setNotifying(false)
  }

  const handleRemove = async (entry) => {
    if (!confirm(`Remove ${entry.name || entry.email} from the waitlist?`)) return
    try {
      await apiClient.delete(`/organizer/events/${eventId}/waitlist/${entry.id}`)
      fetchData()
    } catch (e) {
      alert(e.response?.data?.error || 'Error')
    }
  }

  const formatDate = (d) => new Date(d).toLocaleDateString('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })

  if (loading) return <div className="flex justify-center py-20"><Loader2 className="w-8 h-8 text-brand-500 animate-spin" /></div>

  return (
    <div className="max-w-5xl mx-auto px-4 sm:px-6 py-8">
      <Link to={`/dashboard/events/${eventId}/edit`} className="inline-flex items-center gap-1.5 text-neutral-500 hover:text-neutral-900 mb-6 text-sm font-medium transition-colors">
        <ArrowLeft className="w-4 h-4" /> Back to Event
      </Link>

      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-neutral-900 flex items-center gap-2">
            <ClipboardList className="w-6 h-6 text-brand-500" /> Waitlist
          </h1>
          <p className="text-sm text-neutral-500 mt-1">
            {stats.total_waiting || 0} waiting, {stats.total_notified || 0} notified, {stats.total_converted || 0} converted
          </p>
        </div>
        <div className="flex items-center gap-2">
          <input
            type="number"
            min={1}
            max={50}
            value={notifyCount}
            onChange={(e) => setNotifyCount(Math.max(1, parseInt(e.target.value) || 1))}
            className="input !w-16 text-center text-sm"
          />
          <button onClick={handleNotifyNext} disabled={notifying} className="btn-primary text-sm !py-2.5 gap-1.5">
            {notifying ? <Loader2 className="w-4 h-4 animate-spin" /> : <Send className="w-4 h-4" />}
            Notify Next
          </button>
        </div>
      </div>

      {/* Filters */}
      <div className="flex gap-2 mb-4">
        {['', 'waiting', 'notified', 'expired', 'converted'].map(s => (
          <button
            key={s}
            onClick={() => setFilter(s)}
            className={`px-3 py-1.5 rounded-lg text-sm font-medium transition-colors ${
              filter === s ? 'bg-brand-500 text-white' : 'bg-neutral-100 text-neutral-600 hover:bg-neutral-200'
            }`}
          >
            {s || 'All'}
          </button>
        ))}
      </div>

      {/* Table */}
      {entries.length === 0 ? (
        <div className="text-center py-12 text-neutral-500">No waitlist entries found.</div>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-neutral-200 text-left text-neutral-500">
                <th className="pb-3 font-medium">#</th>
                <th className="pb-3 font-medium">Name</th>
                <th className="pb-3 font-medium">Email</th>
                <th className="pb-3 font-medium">Ticket Type</th>
                <th className="pb-3 font-medium">Qty</th>
                <th className="pb-3 font-medium">Status</th>
                <th className="pb-3 font-medium">Joined</th>
                <th className="pb-3 font-medium">Actions</th>
              </tr>
            </thead>
            <tbody>
              {entries.map(entry => (
                <tr key={entry.id} className="border-b border-neutral-100 hover:bg-neutral-50">
                  <td className="py-3 text-neutral-900 font-medium">{entry.position}</td>
                  <td className="py-3 text-neutral-900">{entry.name || '—'}</td>
                  <td className="py-3 text-neutral-600">{entry.email}</td>
                  <td className="py-3 text-neutral-600">{entry.ticket_type?.name || 'Any'}</td>
                  <td className="py-3 text-neutral-600">{entry.quantity}</td>
                  <td className="py-3">
                    <span className={`inline-flex px-2 py-0.5 rounded-full text-xs font-medium ${STATUS_COLORS[entry.status] || ''}`}>
                      {entry.status}
                    </span>
                  </td>
                  <td className="py-3 text-neutral-500 text-xs">{formatDate(entry.created_at)}</td>
                  <td className="py-3">
                    <div className="flex items-center gap-1">
                      {entry.status === 'waiting' && (
                        <button
                          onClick={() => handleNotify(entry)}
                          className="p-1.5 rounded-lg text-blue-500 hover:bg-blue-50 transition-colors"
                          title="Notify"
                        >
                          <Bell className="w-4 h-4" />
                        </button>
                      )}
                      <button
                        onClick={() => handleRemove(entry)}
                        className="p-1.5 rounded-lg text-red-400 hover:bg-red-50 transition-colors"
                        title="Remove"
                      >
                        <Trash2 className="w-4 h-4" />
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
