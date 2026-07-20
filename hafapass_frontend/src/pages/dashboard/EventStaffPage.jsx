import { Loader2, Trash2, UserRoundCog } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import apiClient from '../../api/client'

const ROLES = ['manager', 'box_office', 'scanner']
const label = value => value?.replaceAll('_', ' ').replace(/\b\w/g, character => character.toUpperCase())

export default function EventStaffPage() {
  const { id } = useParams()
  const [event, setEvent] = useState(null)
  const [assignments, setAssignments] = useState([])
  const [candidates, setCandidates] = useState([])
  const [userId, setUserId] = useState('')
  const [role, setRole] = useState('scanner')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const [eventResponse, staffResponse] = await Promise.all([
        apiClient.get(`/organizer/events/${id}`),
        apiClient.get(`/organizer/events/${id}/staff_assignments`)
      ])
      setEvent(eventResponse.data)
      setAssignments(staffResponse.data.assignments)
      setCandidates(staffResponse.data.candidates)
      setUserId(current => current || staffResponse.data.candidates[0]?.user_id?.toString() || '')
    } catch (requestError) {
      setError(requestError.response?.data?.error || 'Could not load event staff.')
    } finally {
      setLoading(false)
    }
  }, [id])

  useEffect(() => { load() }, [load])

  const assign = async submitEvent => {
    submitEvent.preventDefault()
    if (!userId) return
    setBusy(true)
    setError(null)
    try {
      const response = await apiClient.post(`/organizer/events/${id}/staff_assignments`, { user_id: userId, role })
      setAssignments(current => [...current, response.data])
    } catch (requestError) {
      setError(requestError.response?.data?.error || requestError.response?.data?.errors?.[0] || 'Could not assign staff.')
    } finally {
      setBusy(false)
    }
  }

  const revoke = async assignment => {
    setBusy(true)
    setError(null)
    try {
      await apiClient.delete(`/organizer/events/${id}/staff_assignments/${assignment.id}`)
      setAssignments(current => current.map(item => item.id === assignment.id ? { ...item, status: 'revoked' } : item))
    } catch (requestError) {
      setError(requestError.response?.data?.error || 'Could not revoke assignment.')
    } finally {
      setBusy(false)
    }
  }

  if (loading) return <div className="flex justify-center py-20"><Loader2 className="h-8 w-8 animate-spin text-brand-500" /></div>

  return (
    <main className="mx-auto max-w-3xl px-4 py-8">
      <Link to={`/dashboard/events/${id}/edit`} className="text-sm font-medium text-brand-600 hover:text-brand-700">← Back to event</Link>
      <div className="mt-5 flex items-start gap-3"><UserRoundCog className="mt-1 h-6 w-6 text-brand-600" /><div><h1 className="text-2xl font-bold text-neutral-950">Event team</h1><p className="mt-1 text-sm text-neutral-500">{event?.title} · assignments can expire or be revoked without changing organization membership.</p></div></div>
      {error && <div className="mt-6 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{error}</div>}

      <section className="mt-8 rounded-2xl border border-neutral-200 bg-white p-5">
        <h2 className="font-semibold text-neutral-900">Add an assignment</h2>
        <form onSubmit={assign} className="mt-4 grid gap-3 sm:grid-cols-[1fr_10rem_auto]">
          <select required value={userId} onChange={event => setUserId(event.target.value)} className="input" aria-label="Team member">
            <option value="">Choose a team member</option>
            {candidates.map(candidate => <option key={candidate.user_id} value={candidate.user_id}>{candidate.name || candidate.email} · {label(candidate.organization_role)}</option>)}
          </select>
          <select value={role} onChange={event => setRole(event.target.value)} className="input" aria-label="Event role">{ROLES.map(item => <option key={item} value={item}>{label(item)}</option>)}</select>
          <button disabled={busy || !userId} className="btn-primary">Assign</button>
        </form>
        {candidates.length === 0 && <p className="mt-3 text-sm text-amber-700">Invite organization members from Settings before assigning event access.</p>}
      </section>

      <section className="mt-6 overflow-hidden rounded-2xl border border-neutral-200 bg-white">
        <div className="border-b border-neutral-100 px-5 py-4"><h2 className="font-semibold text-neutral-900">Current assignments</h2></div>
        <div className="divide-y divide-neutral-100">
          {assignments.map(assignment => (
            <div key={assignment.id} className="flex items-center justify-between gap-3 px-5 py-4">
              <div><p className="font-medium text-neutral-900">{assignment.email}</p><p className="text-sm text-neutral-500">{label(assignment.role)} · {label(assignment.status)}</p></div>
              <button disabled={busy || assignment.status === 'revoked'} onClick={() => revoke(assignment)} className="rounded-lg p-2 text-red-600 hover:bg-red-50" aria-label={`Revoke ${assignment.email}`}><Trash2 className="h-4 w-4" /></button>
            </div>
          ))}
          {assignments.length === 0 && <p className="px-5 py-8 text-center text-sm text-neutral-500">No event-specific assignments yet.</p>}
        </div>
      </section>
    </main>
  )
}
