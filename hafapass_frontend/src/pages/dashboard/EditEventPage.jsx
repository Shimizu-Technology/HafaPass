import { Loader2 } from 'lucide-react'
import { useState, useEffect, useCallback } from 'react'
import { useParams, Link } from 'react-router-dom'
import apiClient from '../../api/client'
const CATEGORIES = [
 { value: 'nightlife', label: 'Nightlife' },
 { value: 'concert', label: 'Concert' },
 { value: 'festival', label: 'Festival' },
 { value: 'dining', label: 'Dining' },
 { value: 'sports', label: 'Sports' },
 { value: 'other', label: 'Other' }
]

const AGE_RESTRICTIONS = [
 { value: 'all_ages', label: 'All Ages' },
 { value: 'eighteen_plus', label: '18+' },
 { value: 'twenty_one_plus', label: '21+' }
]

const STATUS_BADGES = {
 draft: { label: 'Draft', className: 'bg-yellow-100 text-yellow-800' },
 published: { label: 'Published', className: 'bg-green-100 text-green-800' },
 cancelled: { label: 'Cancelled', className: 'bg-red-100 text-red-800' },
 completed: { label: 'Completed', className: 'bg-neutral-100 text-neutral-800' }
}

function formatDatetimeLocal(isoString) {
 if (!isoString) return ''
 const date = new Date(isoString)
 const year = date.getFullYear()
 const month = String(date.getMonth() + 1).padStart(2, '0')
 const day = String(date.getDate()).padStart(2, '0')
 const hours = String(date.getHours()).padStart(2, '0')
 const minutes = String(date.getMinutes()).padStart(2, '0')
 return `${year}-${month}-${day}T${hours}:${minutes}`
}

export default function EditEventPage() {
 const { id } = useParams()
 const [loading, setLoading] = useState(true)
 const [error, setError] = useState(null)
 const [event, setEvent] = useState(null)
 const [submitting, setSubmitting] = useState(false)
 const [submitError, setSubmitError] = useState(null)
 const [successMessage, setSuccessMessage] = useState(null)
 const [formErrors, setFormErrors] = useState({})
 const [showPublishConfirm, setShowPublishConfirm] = useState(false)
 const [publishing, setPublishing] = useState(false)

 const [form, setForm] = useState({
  title: '',
  short_description: '',
  description: '',
  category: 'other',
  age_restriction: 'all_ages',
  venue_name: '',
  venue_address: '',
  venue_city: 'Guam',
  starts_at: '',
  ends_at: '',
  doors_open_at: '',
  max_capacity: '',
  cover_image_url: ''
 })

 const fetchEvent = useCallback(async () => {
  setLoading(true)
  setError(null)
  try {
   const res = await apiClient.get(`/organizer/events/${id}`)
   const e = res.data
   setEvent(e)
   setForm({
    title: e.title || '',
    short_description: e.short_description || '',
    description: e.description || '',
    category: e.category || 'other',
    age_restriction: e.age_restriction || 'all_ages',
    venue_name: e.venue_name || '',
    venue_address: e.venue_address || '',
    venue_city: e.venue_city || 'Guam',
    starts_at: formatDatetimeLocal(e.starts_at),
    ends_at: formatDatetimeLocal(e.ends_at),
    doors_open_at: formatDatetimeLocal(e.doors_open_at),
    max_capacity: e.max_capacity ? String(e.max_capacity) : '',
    cover_image_url: e.cover_image_url || ''
   })
  } catch (err) {
   if (err.response?.status === 401) {
    setError('Please sign in to access this page.')
   } else if (err.response?.status === 404) {
    setError('Event not found.')
   } else {
    setError('Failed to load event.')
   }
  } finally {
   setLoading(false)
  }
 }, [id])

 useEffect(() => {
  fetchEvent()
 }, [fetchEvent])

 const updateField = (field, value) => {
  setForm(prev => ({ ...prev, [field]: value }))
  if (formErrors[field]) {
   setFormErrors(prev => ({ ...prev, [field]: null }))
  }
  setSuccessMessage(null)
 }

 const validate = () => {
  const errors = {}
  if (!form.title.trim()) errors.title = 'Title is required'
  if (!form.venue_name.trim()) errors.venue_name = 'Venue name is required'
  if (!form.starts_at) errors.starts_at = 'Start date/time is required'
  setFormErrors(errors)
  return Object.keys(errors).length === 0
 }

 const handleSubmit = async (e) => {
  e.preventDefault()
  if (!validate()) return

  setSubmitting(true)
  setSubmitError(null)
  setSuccessMessage(null)

  try {
   const payload = {
    title: form.title.trim(),
    short_description: form.short_description.trim() || undefined,
    description: form.description.trim() || undefined,
    category: form.category,
    age_restriction: form.age_restriction,
    venue_name: form.venue_name.trim(),
    venue_address: form.venue_address.trim() || undefined,
    venue_city: form.venue_city.trim() || 'Guam',
    starts_at: form.starts_at || undefined,
    ends_at: form.ends_at || undefined,
    doors_open_at: form.doors_open_at || undefined,
    max_capacity: form.max_capacity ? parseInt(form.max_capacity, 10) : null,
    cover_image_url: form.cover_image_url.trim() || undefined
   }

   const res = await apiClient.put(`/organizer/events/${id}`, payload)
   setEvent(res.data)
   setSuccessMessage('Event updated successfully.')
  } catch (err) {
   const msg = err.response?.data?.errors?.join(', ') || err.response?.data?.error || 'Failed to update event'
   setSubmitError(msg)
  } finally {
   setSubmitting(false)
  }
 }

 const handlePublish = async () => {
  setPublishing(true)
  setSubmitError(null)
  try {
   const res = await apiClient.post(`/organizer/events/${id}/publish`)
   setEvent(res.data)
   setShowPublishConfirm(false)
   setSuccessMessage('Event published successfully!')
  } catch (err) {
   const msg = err.response?.data?.error || 'Failed to publish event'
   setSubmitError(msg)
   setShowPublishConfirm(false)
  } finally {
   setPublishing(false)
  }
 }

 if (loading) {
  return (
   <div className="flex justify-center items-center py-20">
    <Loader2 className="w-8 h-8 text-brand-500 animate-spin" />
   </div>
  )
 }

 if (error) {
  return (
   <div className="max-w-2xl mx-auto px-4 py-8">
    <div className="p-4 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm">
     {error}
    </div>
    <Link to="/dashboard" className="mt-4 inline-block text-brand-500 hover:text-brand-700 text-sm font-medium">
     Back to Dashboard
    </Link>
   </div>
  )
 }

 const statusBadge = STATUS_BADGES[event?.status] || STATUS_BADGES.draft

 return (
  <div className="max-w-2xl mx-auto px-4 py-8">
   <div className="mb-6 flex items-center justify-between">
    <Link to="/dashboard" className="text-brand-500 hover:text-brand-700 text-sm font-medium flex items-center gap-1">
     <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 19l-7-7 7-7" />
     </svg>
     Back to Dashboard
    </Link>
    {event?.status === 'published' && (
     <Link
      to={`/dashboard/events/${id}/analytics`}
      className="text-brand-500 hover:text-brand-700 text-sm font-medium flex items-center gap-1"
     >
      View Analytics
      <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
       <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 19V6l12-3v13M9 19c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zm12-3c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zM9 10l12-3" />
      </svg>
     </Link>
    )}
   </div>

   <div className="flex items-center gap-3 mb-6">
    <h1 className="text-2xl font-bold text-neutral-900">Edit Event</h1>
    <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${statusBadge.className}`}>
     {statusBadge.label}
    </span>
   </div>

   {/* Publish Button for Draft Events */}
   {event?.status === 'draft' && (
    <div className="mb-6 p-4 bg-brand-50 border border-brand-200 rounded-xl">
     <div className="flex items-center justify-between">
      <div>
       <p className="text-sm font-medium text-brand-800">Ready to go live?</p>
       <p className="text-xs text-brand-600 mt-0.5">Publishing will make this event visible to the public.</p>
      </div>
      <button
       onClick={() => setShowPublishConfirm(true)}
       className="btn-primary text-sm px-4 py-2"
      >
       Publish Event
      </button>
     </div>
    </div>
   )}

   {/* Publish Confirmation Dialog */}
   {showPublishConfirm && (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 px-4">
     <div className="bg-white rounded-xl shadow-xl max-w-md w-full p-6">
      <h3 className="text-lg font-semibold text-neutral-900 mb-2">Publish Event?</h3>
      <p className="text-sm text-neutral-600 mb-4">
       This will make your event visible to the public. Attendees will be able to browse and purchase tickets.
      </p>
      <div className="flex gap-3 justify-end">
       <button
        onClick={() => setShowPublishConfirm(false)}
        disabled={publishing}
        className="px-4 py-2 text-sm font-medium text-neutral-700 hover:text-neutral-900 disabled:opacity-50"
       >
        Cancel
       </button>
       <button
        onClick={handlePublish}
        disabled={publishing}
        className="btn-primary text-sm px-4 py-2"
       >
        {publishing ? 'Publishing...' : 'Yes, Publish'}
       </button>
      </div>
     </div>
    </div>
   )}

   {successMessage && (
    <div className="mb-6 p-4 bg-green-50 border border-green-200 rounded-xl text-green-700 text-sm">
     {successMessage}
    </div>
   )}

   {submitError && (
    <div className="mb-6 p-4 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm">
     {submitError}
    </div>
   )}

   <form onSubmit={handleSubmit} className="space-y-8">
    {/* Basic Info Section */}
    <section>
     <h2 className="text-lg font-semibold text-neutral-900 mb-4 pb-2 border-b border-neutral-200">Basic Info</h2>
     <div className="space-y-4">
      <div>
       <label htmlFor="title" className="block text-sm font-medium text-neutral-700 mb-1">
        Event Title <span className="text-red-500">*</span>
       </label>
       <input
        id="title"
        type="text"
        value={form.title}
        onChange={(e) => updateField('title', e.target.value)}
        className={`input ${formErrors.title ? 'input-error' : ''}`}
        placeholder="e.g., Full Moon Beach Party"
        disabled={submitting}
       />
       {formErrors.title && <p className="mt-1 text-sm text-red-600">{formErrors.title}</p>}
      </div>

      <div>
       <label htmlFor="short_description" className="block text-sm font-medium text-neutral-700 mb-1">
        Short Description
       </label>
       <input
        id="short_description"
        type="text"
        value={form.short_description}
        onChange={(e) => updateField('short_description', e.target.value)}
        className="input"
        placeholder="A brief tagline for your event"
        maxLength={200}
        disabled={submitting}
       />
      </div>

      <div>
       <label htmlFor="description" className="block text-sm font-medium text-neutral-700 mb-1">
        Description
       </label>
       <textarea
        id="description"
        value={form.description}
        onChange={(e) => updateField('description', e.target.value)}
        rows={4}
        className="input"
        placeholder="Full event description..."
        disabled={submitting}
       />
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
       <div>
        <label htmlFor="category" className="block text-sm font-medium text-neutral-700 mb-1">
         Category
        </label>
        <select
         id="category"
         value={form.category}
         onChange={(e) => updateField('category', e.target.value)}
         className="input"
         disabled={submitting}
        >
         {CATEGORIES.map(cat => (
          <option key={cat.value} value={cat.value}>{cat.label}</option>
         ))}
        </select>
       </div>

       <div>
        <label htmlFor="age_restriction" className="block text-sm font-medium text-neutral-700 mb-1">
         Age Restriction
        </label>
        <select
         id="age_restriction"
         value={form.age_restriction}
         onChange={(e) => updateField('age_restriction', e.target.value)}
         className="input"
         disabled={submitting}
        >
         {AGE_RESTRICTIONS.map(ar => (
          <option key={ar.value} value={ar.value}>{ar.label}</option>
         ))}
        </select>
       </div>
      </div>
     </div>
    </section>

    {/* Venue Section */}
    <section>
     <h2 className="text-lg font-semibold text-neutral-900 mb-4 pb-2 border-b border-neutral-200">Venue</h2>
     <div className="space-y-4">
      <div>
       <label htmlFor="venue_name" className="block text-sm font-medium text-neutral-700 mb-1">
        Venue Name <span className="text-red-500">*</span>
       </label>
       <input
        id="venue_name"
        type="text"
        value={form.venue_name}
        onChange={(e) => updateField('venue_name', e.target.value)}
        className={`input ${formErrors.venue_name ? 'input-error' : ''}`}
        placeholder="e.g., Tumon Beach Club"
        disabled={submitting}
       />
       {formErrors.venue_name && <p className="mt-1 text-sm text-red-600">{formErrors.venue_name}</p>}
      </div>

      <div>
       <label htmlFor="venue_address" className="block text-sm font-medium text-neutral-700 mb-1">
        Venue Address
       </label>
       <input
        id="venue_address"
        type="text"
        value={form.venue_address}
        onChange={(e) => updateField('venue_address', e.target.value)}
        className="input"
        placeholder="123 Pale San Vitores Rd, Tumon"
        disabled={submitting}
       />
      </div>

      <div>
       <label htmlFor="venue_city" className="block text-sm font-medium text-neutral-700 mb-1">
        City
       </label>
       <input
        id="venue_city"
        type="text"
        value={form.venue_city}
        onChange={(e) => updateField('venue_city', e.target.value)}
        className="input"
        placeholder="Guam"
        disabled={submitting}
       />
      </div>
     </div>
    </section>

    {/* Date/Time Section */}
    <section>
     <h2 className="text-lg font-semibold text-neutral-900 mb-4 pb-2 border-b border-neutral-200">Date & Time</h2>
     <div className="space-y-4">
      <div>
       <label htmlFor="starts_at" className="block text-sm font-medium text-neutral-700 mb-1">
        Start Date & Time <span className="text-red-500">*</span>
       </label>
       <input
        id="starts_at"
        type="datetime-local"
        value={form.starts_at}
        onChange={(e) => updateField('starts_at', e.target.value)}
        className={`input ${formErrors.starts_at ? 'input-error' : ''}`}
        disabled={submitting}
       />
       {formErrors.starts_at && <p className="mt-1 text-sm text-red-600">{formErrors.starts_at}</p>}
      </div>

      <div>
       <label htmlFor="ends_at" className="block text-sm font-medium text-neutral-700 mb-1">
        End Date & Time
       </label>
       <input
        id="ends_at"
        type="datetime-local"
        value={form.ends_at}
        onChange={(e) => updateField('ends_at', e.target.value)}
        className="input"
        disabled={submitting}
       />
      </div>

      <div>
       <label htmlFor="doors_open_at" className="block text-sm font-medium text-neutral-700 mb-1">
        Doors Open At
       </label>
       <input
        id="doors_open_at"
        type="datetime-local"
        value={form.doors_open_at}
        onChange={(e) => updateField('doors_open_at', e.target.value)}
        className="input"
        disabled={submitting}
       />
      </div>
     </div>
    </section>

    {/* Settings Section */}
    <section>
     <h2 className="text-lg font-semibold text-neutral-900 mb-4 pb-2 border-b border-neutral-200">Settings</h2>
     <div className="space-y-4">
      <div>
       <label htmlFor="max_capacity" className="block text-sm font-medium text-neutral-700 mb-1">
        Max Capacity
       </label>
       <input
        id="max_capacity"
        type="number"
        min="1"
        value={form.max_capacity}
        onChange={(e) => updateField('max_capacity', e.target.value)}
        className="input"
        placeholder="Leave blank for unlimited"
        disabled={submitting}
       />
      </div>

      <div>
       <label htmlFor="cover_image_url" className="block text-sm font-medium text-neutral-700 mb-1">
        Cover Image URL
       </label>
       <input
        id="cover_image_url"
        type="url"
        value={form.cover_image_url}
        onChange={(e) => updateField('cover_image_url', e.target.value)}
        className="input"
        placeholder="https://example.com/image.jpg"
        disabled={submitting}
       />
       <p className="mt-1 text-xs text-neutral-500">Paste a URL for your event cover image</p>
      </div>
     </div>
    </section>

    {/* Submit */}
    <div className="pt-4 border-t border-neutral-200">
     <button
      type="submit"
      disabled={submitting}
      className="btn-primary w-full sm:w-auto"
     >
      {submitting ? 'Saving...' : 'Save Changes'}
     </button>
    </div>
   </form>

   {/* Ticket Types — managed via the event's ticket types API */}
   {event?.ticket_types?.length > 0 && (
    <div className="card p-5 sm:p-6 mt-6">
     <h2 className="text-lg font-semibold text-neutral-900 mb-4">Ticket Types</h2>
     <div className="space-y-3">
      {event.ticket_types.map(tt => (
       <div key={tt.id} className="flex items-center justify-between p-3 bg-neutral-50 rounded-xl">
        <div>
         <p className="font-medium text-neutral-900">{tt.name}</p>
         {tt.description && <p className="text-sm text-neutral-500">{tt.description}</p>}
        </div>
        <div className="text-right">
         <p className="font-semibold text-neutral-900">${(tt.price_cents / 100).toFixed(2)}</p>
         <p className="text-xs text-neutral-500">{tt.quantity_sold}/{tt.quantity_available} sold</p>
        </div>
       </div>
      ))}
     </div>
    </div>
   )}
  </div>
 )
}
