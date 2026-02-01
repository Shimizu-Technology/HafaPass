import { useState, useEffect } from 'react'
import { useParams, Link } from 'react-router-dom'
import { ArrowLeft, Plus, Tag, Trash2, ToggleLeft, ToggleRight, Loader2 } from 'lucide-react'
import apiClient from '../../api/client'

export default function PromoCodesPage() {
 const { id: eventId } = useParams()
 const [codes, setCodes] = useState([])
 const [loading, setLoading] = useState(true)
 const [showForm, setShowForm] = useState(false)
 const [saving, setSaving] = useState(false)
 const [form, setForm] = useState({ code: '', discount_type: 'percentage', discount_value: '', max_uses: '', expires_at: '' })

 const fetchCodes = async () => {
  try {
   const res = await apiClient.get(`/organizer/events/${eventId}/promo_codes`)
   setCodes(res.data)
  } catch (e) { console.error(e) }
  setLoading(false)
 }

 useEffect(() => { fetchCodes() }, [eventId])

 const handleCreate = async (e) => {
  e.preventDefault()
  setSaving(true)
  try {
   await apiClient.post(`/organizer/events/${eventId}/promo_codes`, {
    code: form.code, discount_type: form.discount_type,
    discount_value: parseInt(form.discount_value),
    max_uses: form.max_uses ? parseInt(form.max_uses) : null,
    expires_at: form.expires_at || null,
   })
   setForm({ code: '', discount_type: 'percentage', discount_value: '', max_uses: '', expires_at: '' })
   setShowForm(false)
   fetchCodes()
  } catch (e) { alert(e.response?.data?.errors?.join(', ') || 'Error creating code') }
  setSaving(false)
 }

 const toggleActive = async (pc) => {
  try {
   await apiClient.patch(`/organizer/events/${eventId}/promo_codes/${pc.id}`, { active: !pc.active })
   fetchCodes()
  } catch (e) { console.error(e) }
 }

 const deleteCode = async (pc) => {
  if (!confirm(`Delete promo code ${pc.code}?`)) return
  try {
   await apiClient.delete(`/organizer/events/${eventId}/promo_codes/${pc.id}`)
   fetchCodes()
  } catch (e) { console.error(e) }
 }

 if (loading) return <div className="flex justify-center py-20"><Loader2 className="w-8 h-8 text-brand-500 animate-spin" /></div>

 return (
  <div className="max-w-4xl mx-auto px-4 sm:px-6 py-8">
   <Link to={`/dashboard/events/${eventId}/edit`} className="inline-flex items-center gap-1.5 text-neutral-500 hover:text-neutral-900 mb-6 text-sm font-medium transition-colors">
    <ArrowLeft className="w-4 h-4" /> Back to Event
   </Link>

   <div className="flex items-center justify-between mb-8">
    <div>
     <h1 className="text-2xl font-bold tracking-tight text-neutral-900">Promo Codes</h1>
     <p className="text-sm text-neutral-500 mt-1">Create discount codes for your event</p>
    </div>
    <button onClick={() => setShowForm(!showForm)} className="btn-primary text-sm !py-2.5 gap-1.5">
     <Plus className="w-4 h-4" /> New Code
    </button>
   </div>

   {showForm && (
    <form onSubmit={handleCreate} className="card p-6 mb-6">
     <h3 className="font-semibold text-neutral-900 mb-4">Create Promo Code</h3>
     <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
      <div>
       <label className="block text-sm font-medium text-neutral-700 mb-1.5">Code</label>
       <input value={form.code} onChange={e => setForm({...form, code: e.target.value.toUpperCase()})} className="input uppercase" placeholder="SUMMER20" required />
      </div>
      <div>
       <label className="block text-sm font-medium text-neutral-700 mb-1.5">Discount Type</label>
       <select value={form.discount_type} onChange={e => setForm({...form, discount_type: e.target.value})} className="input">
        <option value="percentage">Percentage (%)</option>
        <option value="fixed">Fixed Amount (cents)</option>
       </select>
      </div>
      <div>
       <label className="block text-sm font-medium text-neutral-700 mb-1.5">
        {form.discount_type === 'percentage' ? 'Discount (%)' : 'Discount (cents)'}
       </label>
       <input type="number" value={form.discount_value} onChange={e => setForm({...form, discount_value: e.target.value})} className="input" placeholder={form.discount_type === 'percentage' ? '20' : '500'} required />
      </div>
      <div>
       <label className="block text-sm font-medium text-neutral-700 mb-1.5">Max Uses <span className="text-neutral-400 font-normal">(optional)</span></label>
       <input type="number" value={form.max_uses} onChange={e => setForm({...form, max_uses: e.target.value})} className="input" placeholder="Unlimited" />
      </div>
      <div className="sm:col-span-2">
       <label className="block text-sm font-medium text-neutral-700 mb-1.5">Expires At <span className="text-neutral-400 font-normal">(optional)</span></label>
       <input type="datetime-local" value={form.expires_at} onChange={e => setForm({...form, expires_at: e.target.value})} className="input" />
      </div>
     </div>
     <div className="flex gap-3 mt-5">
      <button type="submit" disabled={saving} className="btn-primary text-sm !py-2.5">{saving ? 'Creating...' : 'Create Code'}</button>
      <button type="button" onClick={() => setShowForm(false)} className="btn-secondary text-sm !py-2.5">Cancel</button>
     </div>
    </form>
   )}

   {codes.length === 0 ? (
    <div className="card p-12 text-center">
     <Tag className="w-10 h-10 text-neutral-300 mx-auto mb-3" />
     <p className="text-neutral-500">No promo codes yet</p>
     <p className="text-sm text-neutral-400 mt-1">Create a code to offer discounts</p>
    </div>
   ) : (
    <div className="space-y-3">
     {codes.map(pc => (
      <div key={pc.id} className="card p-5 flex items-center justify-between">
       <div className="flex items-center gap-4">
        <div className={`w-10 h-10 rounded-xl flex items-center justify-center ${pc.active ? 'bg-emerald-50' : 'bg-neutral-100'}`}>
         <Tag className={`w-5 h-5 ${pc.active ? 'text-emerald-500' : 'text-neutral-400'}`} />
        </div>
        <div>
         <p className="font-mono font-semibold text-neutral-900">{pc.code}</p>
         <p className="text-sm text-neutral-500">
          {pc.discount_type === 'percentage' ? `${pc.discount_value}% off` : `$${(pc.discount_value / 100).toFixed(2)} off`}
          {' '}&middot; {pc.current_uses}{pc.max_uses ? `/${pc.max_uses}` : ''} used
          {pc.expires_at && ` · Expires ${new Date(pc.expires_at).toLocaleDateString()}`}
         </p>
        </div>
       </div>
       <div className="flex items-center gap-2">
        <button onClick={() => toggleActive(pc)} className="p-2 rounded-xl hover:bg-neutral-100 transition-colors" title={pc.active ? 'Deactivate' : 'Activate'}>
         {pc.active ? <ToggleRight className="w-5 h-5 text-emerald-500" /> : <ToggleLeft className="w-5 h-5 text-neutral-400" />}
        </button>
        <button onClick={() => deleteCode(pc)} className="p-2 rounded-xl hover:bg-red-50 text-neutral-400 hover:text-red-500 transition-colors">
         <Trash2 className="w-4 h-4" />
        </button>
       </div>
      </div>
     ))}
    </div>
   )}
  </div>
 )
}
