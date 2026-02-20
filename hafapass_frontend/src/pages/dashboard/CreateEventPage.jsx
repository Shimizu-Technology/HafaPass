import { useState } from 'react'
import { useNavigate, Link } from 'react-router-dom'
import apiClient from '../../api/client'
import CoverImageUpload from '../../components/CoverImageUpload'

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

export default function CreateEventPage() {
 const navigate = useNavigate()
 const [submitting, setSubmitting] = useState(false)
 const [error, setError] = useState(null)
 const [formErrors, setFormErrors] = useState({})

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

 const updateField = (field, value) => {
  setForm(prev => ({ ...prev, [field]: value }))
  if (formErrors[field]) {
   setFormErrors(prev => ({ ...prev, [field]: null }))
  }
 }

 const validate = () => {
  const errors = {}
  if (!form.title.trim()) errors.title = 'Title is required'
  if (!form.venue_name.trim()) errors.venue_name = 'Venue name is required'
  if (!form.starts_at) errors.starts_at = 'Start date/time is required'

  // Cross-field validation: end time must be after start time
  if (form.ends_at && form.starts_at) {
   const startsAt = new Date(form.starts_at)
   const endsAt = new Date(form.ends_at)
   if (Number.isFinite(startsAt.valueOf()) && Number.isFinite(endsAt.valueOf()) && endsAt <= startsAt) {
    errors.ends_at = 'End time must be after the start time'
   }
  }

  // Cross-field validation: doors open must be before start time
  if (form.doors_open_at && form.starts_at) {
   const doorsAt = new Date(form.doors_open_at)
   const startsAt = new Date(form.starts_at)
   if (Number.isFinite(doorsAt.valueOf()) && Number.isFinite(startsAt.valueOf()) && doorsAt > startsAt) {
    errors.doors_open_at = 'Doors open time must be before the start time'
   }
  }

  // Max capacity must be a positive integer
  if (form.max_capacity) {
   const cap = Number(form.max_capacity)
   if (!Number.isInteger(cap) || cap < 1) {
    errors.max_capacity = 'Max capacity must be a positive integer'
   }
  }

  setFormErrors(errors)
  return Object.keys(errors).length === 0
 }

 const handleSubmit = async (e) => {
  e.preventDefault()
  if (!validate()) return

  setSubmitting(true)
  setError(null)

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
    max_capacity: form.max_capacity ? parseInt(form.max_capacity, 10) : undefined,
    cover_image_url: form.cover_image_url.trim() || undefined
   }

   const res = await apiClient.post('/organizer/events', payload)
   navigate(`/dashboard/events/${res.data.id}/edit`)
  } catch (err) {
   const msg = err.response?.data?.errors?.join(', ') || err.response?.data?.error || 'Failed to create event'
   setError(msg)
  } finally {
   setSubmitting(false)
  }
 }

 return (
  <div className="max-w-2xl mx-auto px-4 py-8">
   <div className="mb-6">
    <Link to="/dashboard" className="text-brand-500 hover:text-brand-700 text-sm font-medium flex items-center gap-1">
     <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 19l-7-7 7-7" />
     </svg>
     Back to Dashboard
    </Link>
   </div>

   <h1 className="text-2xl font-bold text-neutral-900 mb-6">Create New Event</h1>

   {error && (
    <div className="mb-6 p-4 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm">
     {error}
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
        className={`input ${formErrors.ends_at ? 'input-error' : ''}`}
        disabled={submitting}
       />
       {formErrors.ends_at && <p className="mt-1 text-sm text-red-600">{formErrors.ends_at}</p>}
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
        className={`input ${formErrors.doors_open_at ? 'input-error' : ''}`}
        disabled={submitting}
       />
       {formErrors.doors_open_at && <p className="mt-1 text-sm text-red-600">{formErrors.doors_open_at}</p>}
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
        className={`input ${formErrors.max_capacity ? 'input-error' : ''}`}
        placeholder="Leave blank for unlimited"
        disabled={submitting}
       />
       {formErrors.max_capacity && <p className="mt-1 text-sm text-red-600">{formErrors.max_capacity}</p>}
      </div>

      <CoverImageUpload
       currentUrl={form.cover_image_url}
       onUploaded={(url) => updateField('cover_image_url', url)}
       disabled={submitting}
      />
     </div>
    </section>

    {/* Submit */}
    <div className="pt-4 border-t border-neutral-200">
     <button
      type="submit"
      disabled={submitting}
      className="btn-primary w-full sm:w-auto"
     >
      {submitting ? 'Creating Event...' : 'Create Event'}
     </button>
     <div className="mt-3 p-3 bg-brand-50 border border-brand-200 rounded-xl">
      <p className="text-sm text-brand-700">📋 <strong>You&apos;ll add ticket types on the next step.</strong> After creating the event, you&apos;ll be taken to the edit page where you can set up ticket types, upload a cover image, and publish.</p>
     </div>
    </div>
   </form>
  </div>
 )
}
