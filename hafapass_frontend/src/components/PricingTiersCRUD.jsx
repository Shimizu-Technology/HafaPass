import { useState, useEffect } from 'react'
import { Plus, Pencil, Trash2, Loader2, Clock, Hash } from 'lucide-react'
import apiClient from '../api/client'

const EMPTY_FORM = {
  name: '',
  price: '',
  tier_type: 'quantity_based',
  quantity_limit: '',
  starts_at: '',
  ends_at: '',
  position: '0'
}

function formatDatetimeLocal(isoString) {
  if (!isoString) return ''
  const date = new Date(isoString)
  if (Number.isNaN(date.valueOf())) return ''
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  const hours = String(date.getHours()).padStart(2, '0')
  const minutes = String(date.getMinutes()).padStart(2, '0')
  return `${year}-${month}-${day}T${hours}:${minutes}`
}

function TierForm({ initial, onSave, onCancel, saving }) {
  const [form, setForm] = useState(initial || EMPTY_FORM)
  const [error, setError] = useState(null)

  const handleSubmit = (e) => {
    e.preventDefault()
    if (!form.name.trim()) { setError('Name is required'); return }
    setError(null)

    const data = {
      name: form.name.trim(),
      price_cents: Math.round(parseFloat(form.price || '0') * 100),
      tier_type: form.tier_type,
      position: parseInt(form.position || '0', 10)
    }

    if (form.tier_type === 'quantity_based') {
      data.quantity_limit = form.quantity_limit ? parseInt(form.quantity_limit, 10) : null
    } else {
      data.starts_at = form.starts_at || null
      data.ends_at = form.ends_at || null
    }

    onSave(data)
  }

  return (
    <form onSubmit={handleSubmit} className="p-4 bg-neutral-50 rounded-xl border border-neutral-200 space-y-3">
      {error && <p className="text-sm text-red-600">{error}</p>}
      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className="block text-sm font-medium text-neutral-700 mb-1">Name <span className="text-red-500">*</span></label>
          <input value={form.name} onChange={e => setForm(f => ({...f, name: e.target.value}))} className="input" placeholder="e.g., Early Bird" disabled={saving} />
        </div>
        <div>
          <label className="block text-sm font-medium text-neutral-700 mb-1">Price ($)</label>
          <input type="number" step="0.01" min="0" value={form.price} onChange={e => setForm(f => ({...f, price: e.target.value}))} className="input" placeholder="0.00" disabled={saving} />
        </div>
      </div>
      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className="block text-sm font-medium text-neutral-700 mb-1">Type</label>
          <select value={form.tier_type} onChange={e => setForm(f => ({...f, tier_type: e.target.value}))} className="input" disabled={saving}>
            <option value="quantity_based">Quantity Based</option>
            <option value="time_based">Time Based</option>
          </select>
        </div>
        <div>
          <label className="block text-sm font-medium text-neutral-700 mb-1">Position</label>
          <input type="number" min="0" value={form.position} onChange={e => setForm(f => ({...f, position: e.target.value}))} className="input" disabled={saving} />
        </div>
      </div>
      {form.tier_type === 'quantity_based' && (
        <div>
          <label className="block text-sm font-medium text-neutral-700 mb-1">Quantity Limit</label>
          <input type="number" min="1" value={form.quantity_limit} onChange={e => setForm(f => ({...f, quantity_limit: e.target.value}))} className="input" placeholder="e.g., 50" disabled={saving} />
        </div>
      )}
      {form.tier_type === 'time_based' && (
        <div className="grid grid-cols-2 gap-3">
          <div>
            <label className="block text-sm font-medium text-neutral-700 mb-1">Starts At</label>
            <input type="datetime-local" value={form.starts_at} onChange={e => setForm(f => ({...f, starts_at: e.target.value}))} className="input" disabled={saving} />
          </div>
          <div>
            <label className="block text-sm font-medium text-neutral-700 mb-1">Ends At</label>
            <input type="datetime-local" value={form.ends_at} onChange={e => setForm(f => ({...f, ends_at: e.target.value}))} className="input" disabled={saving} />
          </div>
        </div>
      )}
      <div className="flex gap-2 justify-end">
        <button type="button" onClick={onCancel} disabled={saving} className="px-3 py-1.5 text-sm text-neutral-600 hover:text-neutral-800">Cancel</button>
        <button type="submit" disabled={saving} className="btn-primary text-sm px-4 py-1.5">
          {saving ? 'Saving...' : initial ? 'Update' : 'Add Tier'}
        </button>
      </div>
    </form>
  )
}

export default function PricingTiersCRUD({ eventId, ticketTypeId }) {
  const [tiers, setTiers] = useState([])
  const [loading, setLoading] = useState(true)
  const [showForm, setShowForm] = useState(false)
  const [editingId, setEditingId] = useState(null)
  const [saving, setSaving] = useState(false)
  const [deletingId, setDeletingId] = useState(null)
  const [error, setError] = useState(null)

  const basePath = `/organizer/events/${eventId}/ticket_types/${ticketTypeId}/pricing_tiers`

  const fetchTiers = async () => {
    try {
      const res = await apiClient.get(basePath)
      setTiers(res.data)
    } catch {
      setError('Failed to load pricing tiers')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { fetchTiers() }, [eventId, ticketTypeId])

  const handleCreate = async (data) => {
    setSaving(true)
    setError(null)
    try {
      await apiClient.post(basePath, data)
      setShowForm(false)
      fetchTiers()
    } catch (err) {
      setError(err.response?.data?.errors?.join(', ') || 'Failed to create tier')
    } finally {
      setSaving(false)
    }
  }

  const handleUpdate = async (data) => {
    setSaving(true)
    setError(null)
    try {
      await apiClient.put(`${basePath}/${editingId}`, data)
      setEditingId(null)
      fetchTiers()
    } catch (err) {
      setError(err.response?.data?.errors?.join(', ') || 'Failed to update tier')
    } finally {
      setSaving(false)
    }
  }

  const handleDelete = async (tierId) => {
    setDeletingId(tierId)
    try {
      await apiClient.delete(`${basePath}/${tierId}`)
      fetchTiers()
    } catch (err) {
      setError(err.response?.data?.error || 'Failed to delete tier')
    } finally {
      setDeletingId(null)
    }
  }

  if (loading) return <div className="text-sm text-neutral-400 py-2"><Loader2 className="w-4 h-4 animate-spin inline mr-1" /> Loading tiers...</div>

  return (
    <div className="mt-3 ml-4 border-l-2 border-brand-200 pl-4">
      <div className="flex items-center justify-between mb-2">
        <h4 className="text-sm font-medium text-neutral-700">Pricing Tiers</h4>
        {!showForm && !editingId && (
          <button onClick={() => setShowForm(true)} className="text-xs text-brand-500 hover:text-brand-600 font-medium flex items-center gap-1">
            <Plus className="w-3 h-3" /> Add Tier
          </button>
        )}
      </div>

      {error && <p className="text-xs text-red-600 mb-2">{error}</p>}

      {showForm && (
        <div className="mb-3">
          <TierForm onSave={handleCreate} onCancel={() => setShowForm(false)} saving={saving} />
        </div>
      )}

      {tiers.length === 0 && !showForm && (
        <p className="text-xs text-neutral-400">No pricing tiers. Base price will be used.</p>
      )}

      <div className="space-y-2">
        {tiers.map(tier => (
          <div key={tier.id}>
            {editingId === tier.id ? (
              <TierForm
                initial={{
                  name: tier.name,
                  price: (tier.price_cents / 100).toFixed(2),
                  tier_type: tier.tier_type,
                  quantity_limit: tier.quantity_limit ? String(tier.quantity_limit) : '',
                  starts_at: formatDatetimeLocal(tier.starts_at),
                  ends_at: formatDatetimeLocal(tier.ends_at),
                  position: String(tier.position)
                }}
                onSave={handleUpdate}
                onCancel={() => setEditingId(null)}
                saving={saving}
              />
            ) : (
              <div className="flex items-center justify-between py-2 px-3 bg-neutral-50 rounded-lg text-sm">
                <div className="flex items-center gap-2">
                  {tier.tier_type === 'quantity_based' ? (
                    <Hash className="w-3.5 h-3.5 text-neutral-400" />
                  ) : (
                    <Clock className="w-3.5 h-3.5 text-neutral-400" />
                  )}
                  <span className="font-medium text-neutral-800">{tier.name}</span>
                  <span className="text-neutral-500">${(tier.price_cents / 100).toFixed(2)}</span>
                  {tier.active && (
                    <span className="text-xs bg-emerald-50 text-emerald-600 px-1.5 py-0.5 rounded-full font-medium">Active</span>
                  )}
                  {tier.tier_type === 'quantity_based' && (
                    <span className="text-xs text-neutral-400">{tier.quantity_sold}/{tier.quantity_limit} sold</span>
                  )}
                </div>
                <div className="flex items-center gap-1">
                  <button onClick={() => { setEditingId(tier.id); setShowForm(false) }} className="p-1 text-neutral-400 hover:text-brand-500">
                    <Pencil className="w-3.5 h-3.5" />
                  </button>
                  <button onClick={() => handleDelete(tier.id)} disabled={deletingId === tier.id} className="p-1 text-neutral-400 hover:text-red-500">
                    {deletingId === tier.id ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Trash2 className="w-3.5 h-3.5" />}
                  </button>
                </div>
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  )
}
