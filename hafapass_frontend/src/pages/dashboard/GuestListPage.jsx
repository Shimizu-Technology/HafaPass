import { useState, useEffect } from 'react'
import { useParams, Link } from 'react-router-dom'
import { ArrowLeft, Plus, Users, UserPlus, Check, Loader2, Trash2 } from 'lucide-react'
import apiClient from '../../api/client'

export default function GuestListPage() {
 const { id: eventId } = useParams()
 const [entries, setEntries] = useState([])
 const [ticketTypes, setTicketTypes] = useState([])
 const [loading, setLoading] = useState(true)
 const [showForm, setShowForm] = useState(false)
 const [saving, setSaving] = useState(false)
 const [form, setForm] = useState({ guest_name: '', guest_email: '', guest_phone: '', notes: '', quantity: 1, ticket_type_id: '' })

 const fetchData = async () => {
  try {
   const [entriesRes, eventRes] = await Promise.all([
    apiClient.get(`/organizer/events/${eventId}/guest_list`),
    apiClient.get(`/organizer/events/${eventId}`),
   ])
   // Handle both paginated { guest_list: [...], meta: {...} } and legacy array response
   const entriesData = entriesRes.data.guest_list || entriesRes.data
   setEntries(Array.isArray(entriesData) ? entriesData : [])
   setTicketTypes(eventRes.data.ticket_types || [])
   if (!form.ticket_type_id && eventRes.data.ticket_types?.length > 0) {
    setForm(f => ({ ...f, ticket_type_id: eventRes.data.ticket_types[0].id }))
   }
  } catch (e) { console.error(e) }
  setLoading(false)
 }

 useEffect(() => { fetchData() }, [eventId])

 const handleCreate = async (e) => {
  e.preventDefault()
  setSaving(true)
  try {
   await apiClient.post(`/organizer/events/${eventId}/guest_list`, form)
   setForm(f => ({ guest_name: '', guest_email: '', guest_phone: '', notes: '', quantity: 1, ticket_type_id: f.ticket_type_id }))
   setShowForm(false)
   fetchData()
  } catch (e) { alert(e.response?.data?.errors?.join(', ') || 'Error') }
  setSaving(false)
 }

 const handleRedeem = async (entry) => {
  if (!confirm(`Redeem ${entry.quantity} ticket(s) for ${entry.guest_name}?`)) return
  try {
   await apiClient.post(`/organizer/events/${eventId}/guest_list/${entry.id}/redeem`)
   fetchData()
  } catch (e) { alert(e.response?.data?.error || 'Error') }
 }

 const handleDelete = async (entry) => {
  if (!confirm(`Remove ${entry.guest_name} from guest list?`)) return
  try {
   await apiClient.delete(`/organizer/events/${eventId}/guest_list/${entry.id}`)
   fetchData()
  } catch (e) { alert(e.response?.data?.error || 'Error') }
 }

 if (loading) return <div className="flex justify-center py-20"><Loader2 className="w-8 h-8 text-brand-500 animate-spin" /></div>

 const unredeemed = entries.filter(e => !e.redeemed)
 const redeemed = entries.filter(e => e.redeemed)

 return (
  <div className="max-w-4xl mx-auto px-4 sm:px-6 py-8">
   <Link to={`/dashboard/events/${eventId}/edit`} className="inline-flex items-center gap-1.5 text-neutral-500 hover:text-neutral-900 mb-6 text-sm font-medium transition-colors">
    <ArrowLeft className="w-4 h-4" /> Back to Event
   </Link>

   <div className="flex items-center justify-between mb-8">
    <div>
     <h1 className="text-2xl font-bold tracking-tight text-neutral-900">Guest List</h1>
     <p className="text-sm text-neutral-500 mt-1">{unredeemed.length} pending, {redeemed.length} redeemed</p>
    </div>
    <button onClick={() => setShowForm(!showForm)} className="btn-primary text-sm !py-2.5 gap-1.5">
     <UserPlus className="w-4 h-4" /> Add Guest
    </button>
   </div>

   {showForm && (
    <form onSubmit={handleCreate} className="card p-6 mb-6">
     <h3 className="font-semibold text-neutral-900 mb-4">Add to Guest List</h3>
     <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
      <div>
       <label className="block text-sm font-medium text-neutral-700 mb-1.5">Name</label>
       <input value={form.guest_name} onChange={e => setForm({...form, guest_name: e.target.value})} className="input" placeholder="Guest name" required />
      </div>
      <div>
       <label className="block text-sm font-medium text-neutral-700 mb-1.5">Email <span className="text-neutral-400 font-normal">(optional)</span></label>
       <input type="email" value={form.guest_email} onChange={e => setForm({...form, guest_email: e.target.value})} className="input" placeholder="guest@email.com" />
      </div>
      <div>
       <label className="block text-sm font-medium text-neutral-700 mb-1.5">Ticket Type</label>
       <select value={form.ticket_type_id} onChange={e => setForm({...form, ticket_type_id: parseInt(e.target.value)})} className="input">
        {ticketTypes.map(tt => <option key={tt.id} value={tt.id}>{tt.name}</option>)}
       </select>
      </div>
      <div>
       <label className="block text-sm font-medium text-neutral-700 mb-1.5">Quantity</label>
       <input type="number" min="1" max="10" value={form.quantity} onChange={e => setForm({...form, quantity: parseInt(e.target.value)})} className="input" />
      </div>
      <div className="sm:col-span-2">
       <label className="block text-sm font-medium text-neutral-700 mb-1.5">Notes <span className="text-neutral-400 font-normal">(optional)</span></label>
       <input value={form.notes} onChange={e => setForm({...form, notes: e.target.value})} className="input" placeholder="VIP, photographer, etc." />
      </div>
     </div>
     <div className="flex gap-3 mt-5">
      <button type="submit" disabled={saving} className="btn-primary text-sm !py-2.5">{saving ? 'Adding...' : 'Add Guest'}</button>
      <button type="button" onClick={() => setShowForm(false)} className="btn-secondary text-sm !py-2.5">Cancel</button>
     </div>
    </form>
   )}

   {entries.length === 0 ? (
    <div className="card p-12 text-center">
     <Users className="w-10 h-10 text-neutral-300 mx-auto mb-3" />
     <p className="text-neutral-500">No guests added yet</p>
    </div>
   ) : (
    <div className="space-y-3">
     {unredeemed.map(entry => (
      <div key={entry.id} className="card p-5 flex items-center justify-between">
       <div className="flex items-center gap-4">
        <div className="w-10 h-10 rounded-xl bg-accent-50 flex items-center justify-center">
         <Users className="w-5 h-5 text-accent-500" />
        </div>
        <div>
         <p className="font-medium text-neutral-900">{entry.guest_name}</p>
         <p className="text-sm text-neutral-500">
          {entry.ticket_type.name} &times; {entry.quantity}
          {entry.guest_email && ` · ${entry.guest_email}`}
          {entry.notes && ` · ${entry.notes}`}
         </p>
        </div>
       </div>
       <div className="flex items-center gap-2">
        <button onClick={() => handleRedeem(entry)} className="btn-primary text-xs !py-2 !px-3 gap-1">
         <Check className="w-3 h-3" /> Redeem
        </button>
        <button onClick={() => handleDelete(entry)} className="p-2 rounded-xl hover:bg-red-50 text-neutral-400 hover:text-red-500 transition-colors">
         <Trash2 className="w-4 h-4" />
        </button>
       </div>
      </div>
     ))}
     {redeemed.length > 0 && (
      <>
       <h3 className="text-sm font-medium text-neutral-500 pt-4">Redeemed</h3>
       {redeemed.map(entry => (
        <div key={entry.id} className="card p-5 flex items-center justify-between opacity-60">
         <div className="flex items-center gap-4">
          <div className="w-10 h-10 rounded-xl bg-emerald-50 flex items-center justify-center">
           <Check className="w-5 h-5 text-emerald-500" />
          </div>
          <div>
           <p className="font-medium text-neutral-900">{entry.guest_name}</p>
           <p className="text-sm text-neutral-500">{entry.ticket_type.name} &times; {entry.quantity} &middot; Order #{entry.order_id}</p>
          </div>
         </div>
        </div>
       ))}
      </>
     )}
    </div>
   )}
  </div>
 )
}
