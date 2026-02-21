import { useState } from 'react'
import { Plus, Pencil, Trash2, X, Loader2 } from 'lucide-react'
import apiClient from '../api/client'
import PricingTiersCRUD from './PricingTiersCRUD'

const EMPTY_FORM = { name: '', description: '', price: '', quantity_available: '', max_per_order: '' }

function TicketTypeForm({ initial, onSave, onCancel, saving }) {
  const [form, setForm] = useState(initial || EMPTY_FORM)
  const [error, setError] = useState(null)

  const handleSubmit = (e) => {
    e.preventDefault()
    if (!form.name.trim()) { setError('Name is required'); return }
    setError(null)
    onSave({
      name: form.name.trim(),
      description: form.description.trim() || null,
      price_cents: Math.round(parseFloat(form.price || '0') * 100),
      quantity_available: form.quantity_available ? parseInt(form.quantity_available, 10) : null,
      max_per_order: form.max_per_order ? parseInt(form.max_per_order, 10) : null
    })
  }

  return (
    <form onSubmit={handleSubmit} className="p-4 bg-neutral-50 rounded-xl border border-neutral-200 space-y-3">
      {error && <p className="text-sm text-red-600">{error}</p>}
      <div>
        <label className="block text-sm font-medium text-neutral-700 mb-1">Name <span className="text-red-500">*</span></label>
        <input value={form.name} onChange={e => setForm(f => ({...f, name: e.target.value}))} className="input" placeholder="e.g., General Admission" disabled={saving} />
      </div>
      <div>
        <label className="block text-sm font-medium text-neutral-700 mb-1">Description</label>
        <input value={form.description} onChange={e => setForm(f => ({...f, description: e.target.value}))} className="input" placeholder="Optional description" disabled={saving} />
      </div>
      <div className="grid grid-cols-3 gap-3">
        <div>
          <label className="block text-sm font-medium text-neutral-700 mb-1">Price ($)</label>
          <input type="number" step="0.01" min="0" value={form.price} onChange={e => setForm(f => ({...f, price: e.target.value}))} className="input" placeholder="0.00" disabled={saving} />
        </div>
        <div>
          <label className="block text-sm font-medium text-neutral-700 mb-1">Qty Available</label>
          <input type="number" min="1" value={form.quantity_available} onChange={e => setForm(f => ({...f, quantity_available: e.target.value}))} className="input" placeholder="∞" disabled={saving} />
        </div>
        <div>
          <label className="block text-sm font-medium text-neutral-700 mb-1">Max/Order</label>
          <input type="number" min="1" value={form.max_per_order} onChange={e => setForm(f => ({...f, max_per_order: e.target.value}))} className="input" placeholder="∞" disabled={saving} />
        </div>
      </div>
      <div className="flex gap-2 justify-end">
        <button type="button" onClick={onCancel} disabled={saving} className="px-3 py-1.5 text-sm text-neutral-600 hover:text-neutral-800">Cancel</button>
        <button type="submit" disabled={saving} className="btn-primary text-sm px-4 py-1.5">
          {saving ? 'Saving...' : initial ? 'Update' : 'Add Ticket Type'}
        </button>
      </div>
    </form>
  )
}

export default function TicketTypeCRUD({ eventId, ticketTypes = [], onRefresh }) {
  const [showForm, setShowForm] = useState(false)
  const [editingId, setEditingId] = useState(null)
  const [saving, setSaving] = useState(false)
  const [deletingId, setDeletingId] = useState(null)
  const [confirmDeleteId, setConfirmDeleteId] = useState(null)
  const [error, setError] = useState(null)

  const handleCreate = async (data) => {
    setSaving(true)
    setError(null)
    try {
      await apiClient.post(`/organizer/events/${eventId}/ticket_types`, data)
      setShowForm(false)
      onRefresh()
    } catch (err) {
      setError(err.response?.data?.errors?.join(', ') || 'Failed to create ticket type')
    } finally {
      setSaving(false)
    }
  }

  const handleUpdate = async (data) => {
    setSaving(true)
    setError(null)
    try {
      await apiClient.put(`/organizer/events/${eventId}/ticket_types/${editingId}`, data)
      setEditingId(null)
      onRefresh()
    } catch (err) {
      setError(err.response?.data?.errors?.join(', ') || 'Failed to update ticket type')
    } finally {
      setSaving(false)
    }
  }

  const handleDelete = async (ttId) => {
    setDeletingId(ttId)
    setError(null)
    try {
      await apiClient.delete(`/organizer/events/${eventId}/ticket_types/${ttId}`)
      setConfirmDeleteId(null)
      onRefresh()
    } catch (err) {
      setError(err.response?.data?.error || 'Failed to delete ticket type')
    } finally {
      setDeletingId(null)
    }
  }

  return (
    <div className="card p-5 sm:p-6 mt-6">
      <div className="flex items-center justify-between mb-4">
        <h2 className="text-lg font-semibold text-neutral-900">Ticket Types</h2>
        {!showForm && !editingId && (
          <button onClick={() => setShowForm(true)} className="btn-primary text-sm px-3 py-1.5 flex items-center gap-1.5">
            <Plus className="w-4 h-4" /> Add Ticket Type
          </button>
        )}
      </div>

      {error && (
        <div className="mb-4 p-3 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm">{error}</div>
      )}

      {showForm && (
        <div className="mb-4">
          <TicketTypeForm onSave={handleCreate} onCancel={() => setShowForm(false)} saving={saving} />
        </div>
      )}

      {ticketTypes.length === 0 && !showForm ? (
        <p className="text-sm text-neutral-500 text-center py-4">No ticket types yet. Add one to start selling tickets.</p>
      ) : (
        <div className="space-y-3">
          {ticketTypes.map(tt => (
            <div key={tt.id}>
              {editingId === tt.id ? (
                <TicketTypeForm
                  initial={{
                    name: tt.name,
                    description: tt.description || '',
                    price: (tt.price_cents / 100).toFixed(2),
                    quantity_available: tt.quantity_available ? String(tt.quantity_available) : '',
                    max_per_order: tt.max_per_order ? String(tt.max_per_order) : ''
                  }}
                  onSave={handleUpdate}
                  onCancel={() => setEditingId(null)}
                  saving={saving}
                />
              ) : (
                <div>
                  <div className="flex items-center justify-between p-3 bg-neutral-50 rounded-xl">
                    <div>
                      <p className="font-medium text-neutral-900">{tt.name}</p>
                      {tt.description && <p className="text-sm text-neutral-500">{tt.description}</p>}
                    </div>
                    <div className="flex items-center gap-3">
                      <div className="text-right mr-2">
                        <p className="font-semibold text-neutral-900">${(tt.price_cents / 100).toFixed(2)}</p>
                        {tt.current_price_cents != null && tt.current_price_cents !== tt.price_cents && (
                          <p className="text-xs text-emerald-600">Current: ${(tt.current_price_cents / 100).toFixed(2)}</p>
                        )}
                        <p className="text-xs text-neutral-500">{tt.quantity_sold ?? 0}/{tt.quantity_available ?? '∞'} sold</p>
                      </div>
                    {confirmDeleteId === tt.id ? (
                      <div className="flex items-center gap-1">
                        <span className="text-xs text-red-600 mr-1">Delete?</span>
                        <button onClick={() => handleDelete(tt.id)} disabled={deletingId === tt.id} className="text-red-600 hover:text-red-800 text-xs font-medium">
                          {deletingId === tt.id ? '...' : 'Yes'}
                        </button>
                        <button onClick={() => setConfirmDeleteId(null)} className="text-neutral-500 hover:text-neutral-700 text-xs font-medium">No</button>
                      </div>
                    ) : (
                      <>
                        <button onClick={() => { setEditingId(tt.id); setShowForm(false) }} className="p-1.5 text-neutral-400 hover:text-brand-500 rounded-lg hover:bg-brand-50 transition-colors">
                          <Pencil className="w-4 h-4" />
                        </button>
                        <button onClick={() => setConfirmDeleteId(tt.id)} className="p-1.5 text-neutral-400 hover:text-red-500 rounded-lg hover:bg-red-50 transition-colors">
                          <Trash2 className="w-4 h-4" />
                        </button>
                      </>
                    )}
                  </div>
                </div>
                  <PricingTiersCRUD eventId={eventId} ticketTypeId={tt.id} />
                </div>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
