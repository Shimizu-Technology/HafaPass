import { useState, useEffect, useCallback } from 'react'
import apiClient from '../api/client'

function TicketTypeCard({ ticketType, eventId, onUpdated, onDeleted }) {
  const [editing, setEditing] = useState(false)
  const [saving, setSaving] = useState(false)
  const [deleting, setDeleting] = useState(false)
  const [error, setError] = useState(null)
  const [form, setForm] = useState({
    name: ticketType.name,
    price: (ticketType.price_cents / 100).toFixed(2),
    quantity_available: String(ticketType.quantity_available),
    max_per_order: String(ticketType.max_per_order || 10)
  })

  const handleSave = async () => {
    setError(null)
    if (!form.name.trim()) {
      setError('Name is required')
      return
    }
    const priceCents = Math.round(parseFloat(form.price || '0') * 100)
    if (isNaN(priceCents) || priceCents < 0) {
      setError('Price must be a valid number')
      return
    }
    const qty = parseInt(form.quantity_available, 10)
    if (isNaN(qty) || qty < 1) {
      setError('Quantity must be at least 1')
      return
    }

    setSaving(true)
    try {
      const res = await apiClient.put(
        `/organizer/events/${eventId}/ticket_types/${ticketType.id}`,
        {
          name: form.name.trim(),
          price_cents: priceCents,
          quantity_available: qty,
          max_per_order: parseInt(form.max_per_order, 10) || 10
        }
      )
      onUpdated(res.data)
      setEditing(false)
    } catch (err) {
      setError(err.response?.data?.errors?.join(', ') || err.response?.data?.error || 'Failed to update')
    } finally {
      setSaving(false)
    }
  }

  const handleDelete = async () => {
    if (!window.confirm(`Delete "${ticketType.name}"? This cannot be undone.`)) return
    setDeleting(true)
    setError(null)
    try {
      await apiClient.delete(`/organizer/events/${eventId}/ticket_types/${ticketType.id}`)
      onDeleted(ticketType.id)
    } catch (err) {
      setError(err.response?.data?.error || 'Failed to delete')
      setDeleting(false)
    }
  }

  if (editing) {
    return (
      <div className="border border-blue-200 bg-blue-50 rounded-lg p-4">
        {error && (
          <p className="text-sm text-red-600 mb-3">{error}</p>
        )}
        <div className="space-y-3">
          <div>
            <label className="block text-xs font-medium text-gray-700 mb-1">Name</label>
            <input
              type="text"
              value={form.name}
              onChange={(e) => setForm(prev => ({ ...prev, name: e.target.value }))}
              className="w-full px-3 py-2 border border-gray-300 rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
              disabled={saving}
            />
          </div>
          <div className="grid grid-cols-3 gap-3">
            <div>
              <label className="block text-xs font-medium text-gray-700 mb-1">Price ($)</label>
              <input
                type="number"
                step="0.01"
                min="0"
                value={form.price}
                onChange={(e) => setForm(prev => ({ ...prev, price: e.target.value }))}
                className="w-full px-3 py-2 border border-gray-300 rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                disabled={saving}
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-gray-700 mb-1">Quantity</label>
              <input
                type="number"
                min="1"
                value={form.quantity_available}
                onChange={(e) => setForm(prev => ({ ...prev, quantity_available: e.target.value }))}
                className="w-full px-3 py-2 border border-gray-300 rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                disabled={saving}
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-gray-700 mb-1">Max/Order</label>
              <input
                type="number"
                min="1"
                value={form.max_per_order}
                onChange={(e) => setForm(prev => ({ ...prev, max_per_order: e.target.value }))}
                className="w-full px-3 py-2 border border-gray-300 rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                disabled={saving}
              />
            </div>
          </div>
        </div>
        <div className="flex gap-2 mt-4">
          <button
            onClick={handleSave}
            disabled={saving}
            className="bg-blue-900 text-white px-3 py-1.5 rounded-md text-sm font-medium hover:bg-blue-800 disabled:opacity-50 transition-colors"
          >
            {saving ? 'Saving...' : 'Save'}
          </button>
          <button
            onClick={() => {
              setEditing(false)
              setError(null)
              setForm({
                name: ticketType.name,
                price: (ticketType.price_cents / 100).toFixed(2),
                quantity_available: String(ticketType.quantity_available),
                max_per_order: String(ticketType.max_per_order || 10)
              })
            }}
            disabled={saving}
            className="text-gray-600 hover:text-gray-800 px-3 py-1.5 text-sm font-medium disabled:opacity-50"
          >
            Cancel
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="border border-gray-200 rounded-lg p-4 hover:border-gray-300 transition-colors">
      {error && (
        <p className="text-sm text-red-600 mb-2">{error}</p>
      )}
      <div className="flex items-start justify-between">
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <h4 className="font-medium text-gray-900 text-sm">{ticketType.name}</h4>
            {ticketType.price_cents === 0 ? (
              <span className="text-xs font-medium text-green-700 bg-green-100 px-1.5 py-0.5 rounded">Free</span>
            ) : (
              <span className="text-sm font-semibold text-gray-700">
                ${(ticketType.price_cents / 100).toFixed(2)}
              </span>
            )}
          </div>
          <p className="text-xs text-gray-500 mt-1">
            {ticketType.quantity_sold} / {ticketType.quantity_available} sold
            {ticketType.sold_out && (
              <span className="ml-2 text-xs font-medium text-red-600">Sold Out</span>
            )}
          </p>
        </div>
        <div className="flex items-center gap-1 ml-2">
          <button
            onClick={() => setEditing(true)}
            className="p-1.5 text-gray-400 hover:text-blue-600 rounded transition-colors"
            title="Edit"
          >
            <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
            </svg>
          </button>
          {ticketType.quantity_sold === 0 && (
            <button
              onClick={handleDelete}
              disabled={deleting}
              className="p-1.5 text-gray-400 hover:text-red-600 rounded transition-colors disabled:opacity-50"
              title="Delete"
            >
              <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
              </svg>
            </button>
          )}
        </div>
      </div>
    </div>
  )
}

function AddTicketTypeForm({ eventId, onAdded, onCancel }) {
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState(null)
  const [form, setForm] = useState({
    name: '',
    price: '0.00',
    quantity_available: '100',
    max_per_order: '10'
  })

  const handleSubmit = async (e) => {
    e.preventDefault()
    setError(null)

    if (!form.name.trim()) {
      setError('Name is required')
      return
    }
    const priceCents = Math.round(parseFloat(form.price || '0') * 100)
    if (isNaN(priceCents) || priceCents < 0) {
      setError('Price must be a valid number')
      return
    }
    const qty = parseInt(form.quantity_available, 10)
    if (isNaN(qty) || qty < 1) {
      setError('Quantity must be at least 1')
      return
    }

    setSaving(true)
    try {
      const res = await apiClient.post(
        `/organizer/events/${eventId}/ticket_types`,
        {
          name: form.name.trim(),
          price_cents: priceCents,
          quantity_available: qty,
          max_per_order: parseInt(form.max_per_order, 10) || 10
        }
      )
      onAdded(res.data)
    } catch (err) {
      setError(err.response?.data?.errors?.join(', ') || err.response?.data?.error || 'Failed to create ticket type')
      setSaving(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="border border-green-200 bg-green-50 rounded-lg p-4">
      <h4 className="text-sm font-medium text-gray-900 mb-3">New Ticket Type</h4>
      {error && (
        <p className="text-sm text-red-600 mb-3">{error}</p>
      )}
      <div className="space-y-3">
        <div>
          <label className="block text-xs font-medium text-gray-700 mb-1">Name <span className="text-red-500">*</span></label>
          <input
            type="text"
            value={form.name}
            onChange={(e) => setForm(prev => ({ ...prev, name: e.target.value }))}
            className="w-full px-3 py-2 border border-gray-300 rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
            placeholder="e.g., General Admission, VIP"
            disabled={saving}
          />
        </div>
        <div className="grid grid-cols-3 gap-3">
          <div>
            <label className="block text-xs font-medium text-gray-700 mb-1">Price ($)</label>
            <input
              type="number"
              step="0.01"
              min="0"
              value={form.price}
              onChange={(e) => setForm(prev => ({ ...prev, price: e.target.value }))}
              className="w-full px-3 py-2 border border-gray-300 rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
              disabled={saving}
            />
          </div>
          <div>
            <label className="block text-xs font-medium text-gray-700 mb-1">Quantity <span className="text-red-500">*</span></label>
            <input
              type="number"
              min="1"
              value={form.quantity_available}
              onChange={(e) => setForm(prev => ({ ...prev, quantity_available: e.target.value }))}
              className="w-full px-3 py-2 border border-gray-300 rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
              disabled={saving}
            />
          </div>
          <div>
            <label className="block text-xs font-medium text-gray-700 mb-1">Max/Order</label>
            <input
              type="number"
              min="1"
              value={form.max_per_order}
              onChange={(e) => setForm(prev => ({ ...prev, max_per_order: e.target.value }))}
              className="w-full px-3 py-2 border border-gray-300 rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
              disabled={saving}
            />
          </div>
        </div>
      </div>
      <div className="flex gap-2 mt-4">
        <button
          type="submit"
          disabled={saving}
          className="bg-green-600 text-white px-3 py-1.5 rounded-md text-sm font-medium hover:bg-green-700 disabled:opacity-50 transition-colors"
        >
          {saving ? 'Adding...' : 'Add Ticket Type'}
        </button>
        <button
          type="button"
          onClick={onCancel}
          disabled={saving}
          className="text-gray-600 hover:text-gray-800 px-3 py-1.5 text-sm font-medium disabled:opacity-50"
        >
          Cancel
        </button>
      </div>
    </form>
  )
}

export default function TicketTypesSection({ eventId }) {
  const [ticketTypes, setTicketTypes] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [showAddForm, setShowAddForm] = useState(false)

  const fetchTicketTypes = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const res = await apiClient.get(`/organizer/events/${eventId}/ticket_types`)
      setTicketTypes(res.data)
    } catch (err) {
      setError(err.response?.data?.error || 'Failed to load ticket types')
    } finally {
      setLoading(false)
    }
  }, [eventId])

  useEffect(() => {
    fetchTicketTypes()
  }, [fetchTicketTypes])

  const handleAdded = (newTicketType) => {
    setTicketTypes(prev => [...prev, newTicketType])
    setShowAddForm(false)
  }

  const handleUpdated = (updatedTicketType) => {
    setTicketTypes(prev => prev.map(tt => tt.id === updatedTicketType.id ? updatedTicketType : tt))
  }

  const handleDeleted = (deletedId) => {
    setTicketTypes(prev => prev.filter(tt => tt.id !== deletedId))
  }

  return (
    <section className="mt-8">
      <div className="flex items-center justify-between mb-4 pb-2 border-b border-gray-200">
        <h2 className="text-lg font-semibold text-gray-900">Ticket Types</h2>
        {!showAddForm && (
          <button
            onClick={() => setShowAddForm(true)}
            className="inline-flex items-center gap-1 text-sm font-medium text-blue-600 hover:text-blue-800 transition-colors"
          >
            <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 4v16m8-8H4" />
            </svg>
            Add Ticket Type
          </button>
        )}
      </div>

      {loading ? (
        <div className="flex justify-center py-6">
          <div className="animate-spin rounded-full h-6 w-6 border-b-2 border-blue-900"></div>
        </div>
      ) : error ? (
        <div className="p-3 bg-red-50 border border-red-200 rounded-lg text-red-700 text-sm">
          {error}
          <button onClick={fetchTicketTypes} className="ml-2 underline hover:no-underline">Retry</button>
        </div>
      ) : (
        <div className="space-y-3">
          {ticketTypes.length === 0 && !showAddForm && (
            <div className="text-center py-6 text-gray-500">
              <svg className="w-8 h-8 mx-auto mb-2 text-gray-300" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 5v2m0 4v2m0 4v2M5 5a2 2 0 00-2 2v3a2 2 0 110 4v3a2 2 0 002 2h14a2 2 0 002-2v-3a2 2 0 110-4V7a2 2 0 00-2-2H5z" />
              </svg>
              <p className="text-sm">No ticket types yet.</p>
              <button
                onClick={() => setShowAddForm(true)}
                className="mt-2 text-sm text-blue-600 hover:text-blue-800 font-medium"
              >
                Add your first ticket type
              </button>
            </div>
          )}

          {ticketTypes.map(tt => (
            <TicketTypeCard
              key={tt.id}
              ticketType={tt}
              eventId={eventId}
              onUpdated={handleUpdated}
              onDeleted={handleDeleted}
            />
          ))}

          {showAddForm && (
            <AddTicketTypeForm
              eventId={eventId}
              onAdded={handleAdded}
              onCancel={() => setShowAddForm(false)}
            />
          )}
        </div>
      )}
    </section>
  )
}
