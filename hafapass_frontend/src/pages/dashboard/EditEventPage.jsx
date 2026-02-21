import { Loader2 } from 'lucide-react'
import { useState, useEffect, useCallback } from 'react'
import { useParams, Link, useNavigate } from 'react-router-dom'
import { AlertTriangle, Trash2, XCircle, CheckCircle2, Users, Eye, ShoppingCart, Copy, RefreshCw, ClipboardList } from 'lucide-react'
import apiClient from '../../api/client'
import CoverImageUpload from '../../components/CoverImageUpload'
import TicketTypeCRUD from '../../components/TicketTypeCRUD'

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
  if (Number.isNaN(date.valueOf())) return ''
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  const hours = String(date.getHours()).padStart(2, '0')
  const minutes = String(date.getMinutes()).padStart(2, '0')
  return `${year}-${month}-${day}T${hours}:${minutes}`
}

function ConfirmModal({ title, message, confirmLabel, confirmClass, onConfirm, onCancel, loading }) {
  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 px-4">
      <div className="bg-white rounded-xl shadow-xl max-w-md w-full p-6">
        <h3 className="text-lg font-semibold text-neutral-900 mb-2">{title}</h3>
        <p className="text-sm text-neutral-600 mb-4">{message}</p>
        <div className="flex gap-3 justify-end">
          <button onClick={onCancel} disabled={loading} className="px-4 py-2 text-sm font-medium text-neutral-700 hover:text-neutral-900 disabled:opacity-50">Cancel</button>
          <button onClick={onConfirm} disabled={loading} className={`px-4 py-2 text-sm font-medium rounded-xl text-white ${confirmClass || 'bg-red-600 hover:bg-red-700'} disabled:opacity-50`}>
            {loading ? 'Processing...' : confirmLabel}
          </button>
        </div>
      </div>
    </div>
  )
}

export default function EditEventPage() {
  const { id } = useParams()
  const navigate = useNavigate()
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [event, setEvent] = useState(null)
  const [submitting, setSubmitting] = useState(false)
  const [submitError, setSubmitError] = useState(null)
  const [successMessage, setSuccessMessage] = useState(null)
  const [formErrors, setFormErrors] = useState({})
  const [showPublishConfirm, setShowPublishConfirm] = useState(false)
  const [publishing, setPublishing] = useState(false)

  // Danger zone modals
  const [showCancelConfirm, setShowCancelConfirm] = useState(false)
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false)
  const [showCompleteConfirm, setShowCompleteConfirm] = useState(false)
  const [dangerLoading, setDangerLoading] = useState(false)
  const [cloning, setCloning] = useState(false)
  const [recurrenceCount, setRecurrenceCount] = useState(4)
  const [generatingRecurrences, setGeneratingRecurrences] = useState(false)
  const [recurrenceChildren, setRecurrenceChildren] = useState([])

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
    cover_image_url: '',
    recurrence_rule: '',
    recurrence_end_date: '',
    show_attendees: true
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
        cover_image_url: e.cover_image_url || '',
        recurrence_rule: e.recurrence_rule || '',
        recurrence_end_date: e.recurrence_end_date || '',
        show_attendees: e.show_attendees !== false
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
    if (form.ends_at && form.starts_at) {
      const startsAt = new Date(form.starts_at)
      const endsAt = new Date(form.ends_at)
      if (Number.isFinite(startsAt.valueOf()) && Number.isFinite(endsAt.valueOf()) && endsAt <= startsAt) {
        errors.ends_at = 'End time must be after the start time'
      }
    }
    if (form.doors_open_at && form.starts_at) {
      const doorsAt = new Date(form.doors_open_at)
      const startsAt = new Date(form.starts_at)
      if (Number.isFinite(doorsAt.valueOf()) && Number.isFinite(startsAt.valueOf()) && doorsAt > startsAt) {
        errors.doors_open_at = 'Doors open time must be before the start time'
      }
    }
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
    setSubmitError(null)
    setSuccessMessage(null)
    try {
      const payload = {
        title: form.title.trim(),
        short_description: form.short_description.trim() || null,
        description: form.description.trim() || null,
        category: form.category,
        age_restriction: form.age_restriction,
        venue_name: form.venue_name.trim(),
        venue_address: form.venue_address.trim() || null,
        venue_city: form.venue_city.trim() || 'Guam',
        starts_at: form.starts_at || undefined,
        ends_at: form.ends_at || undefined,
        doors_open_at: form.doors_open_at || undefined,
        max_capacity: form.max_capacity ? parseInt(form.max_capacity, 10) : null,
        cover_image_url: form.cover_image_url.trim() || null,
        recurrence_rule: form.recurrence_rule || null,
        recurrence_end_date: form.recurrence_end_date || null,
        show_attendees: form.show_attendees
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

  // Danger zone actions
  const handleCancelEvent = async () => {
    setDangerLoading(true)
    try {
      const res = await apiClient.put(`/organizer/events/${id}`, { status: 'cancelled' })
      setEvent(res.data)
      setShowCancelConfirm(false)
      setSuccessMessage('Event has been cancelled.')
    } catch (err) {
      setSubmitError(err.response?.data?.errors?.join(', ') || 'Failed to cancel event')
      setShowCancelConfirm(false)
    } finally {
      setDangerLoading(false)
    }
  }

  const handleDeleteEvent = async () => {
    setDangerLoading(true)
    try {
      await apiClient.delete(`/organizer/events/${id}`)
      navigate('/dashboard')
    } catch (err) {
      setSubmitError(err.response?.data?.error || 'Failed to delete event')
      setShowDeleteConfirm(false)
    } finally {
      setDangerLoading(false)
    }
  }

  const handleCompleteEvent = async () => {
    setDangerLoading(true)
    try {
      const res = await apiClient.put(`/organizer/events/${id}`, { status: 'completed' })
      setEvent(res.data)
      setShowCompleteConfirm(false)
      setSuccessMessage('Event marked as completed.')
    } catch (err) {
      setSubmitError(err.response?.data?.errors?.join(', ') || 'Failed to complete event')
      setShowCompleteConfirm(false)
    } finally {
      setDangerLoading(false)
    }
  }

  const eventEndedInPast = event?.ends_at && new Date(event.ends_at) < new Date()

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
        <div className="p-4 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm">{error}</div>
        <Link to="/dashboard" className="mt-4 inline-block text-brand-500 hover:text-brand-700 text-sm font-medium">Back to Dashboard</Link>
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
        <div className="flex items-center gap-3">
          {event?.slug && (
            <a
              href={`/events/${event.slug}${event.status === 'draft' ? '?preview=true' : ''}`}
              target="_blank"
              rel="noopener noreferrer"
              className="text-brand-500 hover:text-brand-700 text-sm font-medium flex items-center gap-1"
            >
              <Eye className="w-4 h-4" /> Preview
            </a>
          )}
          <button
            onClick={async () => {
              setCloning(true)
              try {
                const res = await apiClient.post(`/organizer/events/${id}/clone`)
                setSuccessMessage('Event cloned! Update the details and publish when ready.')
                navigate(`/dashboard/events/${res.data.id}/edit`)
              } catch (err) {
                setSubmitError(err.response?.data?.errors?.join(', ') || 'Failed to clone event')
              } finally {
                setCloning(false)
              }
            }}
            disabled={cloning}
            className="text-brand-500 hover:text-brand-700 text-sm font-medium flex items-center gap-1 disabled:opacity-50"
          >
            <Copy className="w-4 h-4" /> {cloning ? 'Cloning...' : 'Clone'}
          </button>
          <Link to={`/dashboard/events/${id}/box-office`} className="text-brand-500 hover:text-brand-700 text-sm font-medium flex items-center gap-1">
            <ShoppingCart className="w-4 h-4" /> Box Office
          </Link>
          <Link to={`/dashboard/events/${id}/attendees`} className="text-brand-500 hover:text-brand-700 text-sm font-medium flex items-center gap-1">
            <Users className="w-4 h-4" /> Attendees
          </Link>
          <Link to={`/dashboard/events/${id}/waitlist`} className="text-brand-500 hover:text-brand-700 text-sm font-medium flex items-center gap-1">
            <ClipboardList className="w-4 h-4" /> Waitlist
          </Link>
          {event?.status === 'published' && (
            <Link to={`/dashboard/events/${id}/analytics`} className="text-brand-500 hover:text-brand-700 text-sm font-medium flex items-center gap-1">
              View Analytics
              <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 19V6l12-3v13M9 19c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zm12-3c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zM9 10l12-3" />
              </svg>
            </Link>
          )}
        </div>
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
            <button onClick={() => setShowPublishConfirm(true)} className="btn-primary text-sm px-4 py-2">Publish Event</button>
          </div>
        </div>
      )}

      {/* Publish Confirmation Dialog */}
      {showPublishConfirm && (
        <ConfirmModal
          title="Publish Event?"
          message="This will make your event visible to the public. Attendees will be able to browse and purchase tickets."
          confirmLabel={publishing ? 'Publishing...' : 'Yes, Publish'}
          confirmClass="bg-brand-500 hover:bg-brand-600"
          onConfirm={handlePublish}
          onCancel={() => setShowPublishConfirm(false)}
          loading={publishing}
        />
      )}

      {/* Danger zone modals */}
      {showCancelConfirm && (
        <ConfirmModal
          title="Cancel Event?"
          message="This will cancel the event and notify ticket holders. This action cannot be undone."
          confirmLabel="Yes, Cancel Event"
          onConfirm={handleCancelEvent}
          onCancel={() => setShowCancelConfirm(false)}
          loading={dangerLoading}
        />
      )}
      {showDeleteConfirm && (
        <ConfirmModal
          title="Delete Event?"
          message="This will permanently delete this draft event and all its data. This cannot be undone."
          confirmLabel="Yes, Delete"
          onConfirm={handleDeleteEvent}
          onCancel={() => setShowDeleteConfirm(false)}
          loading={dangerLoading}
        />
      )}
      {showCompleteConfirm && (
        <ConfirmModal
          title="Mark as Completed?"
          message="This will mark the event as completed. No more ticket sales will be allowed."
          confirmLabel="Yes, Complete"
          confirmClass="bg-neutral-700 hover:bg-neutral-800"
          onConfirm={handleCompleteEvent}
          onCancel={() => setShowCompleteConfirm(false)}
          loading={dangerLoading}
        />
      )}

      {successMessage && (
        <div className="mb-6 p-4 bg-green-50 border border-green-200 rounded-xl text-green-700 text-sm">{successMessage}</div>
      )}

      {submitError && (
        <div className="mb-6 p-4 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm">{submitError}</div>
      )}

      <form onSubmit={handleSubmit} className="space-y-8">
        {/* Cover Image Upload */}
        <section>
          <h2 className="text-lg font-semibold text-neutral-900 mb-4 pb-2 border-b border-neutral-200">Cover Image</h2>
          <CoverImageUpload
            currentUrl={form.cover_image_url}
            onUploaded={(url) => updateField('cover_image_url', url)}
            disabled={submitting}
          />
        </section>

        {/* Basic Info Section */}
        <section>
          <h2 className="text-lg font-semibold text-neutral-900 mb-4 pb-2 border-b border-neutral-200">Basic Info</h2>
          <div className="space-y-4">
            <div>
              <label htmlFor="title" className="block text-sm font-medium text-neutral-700 mb-1">
                Event Title <span className="text-red-500">*</span>
              </label>
              <input id="title" type="text" value={form.title} onChange={(e) => updateField('title', e.target.value)} className={`input ${formErrors.title ? 'input-error' : ''}`} placeholder="e.g., Full Moon Beach Party" disabled={submitting} />
              {formErrors.title && <p className="mt-1 text-sm text-red-600">{formErrors.title}</p>}
            </div>
            <div>
              <label htmlFor="short_description" className="block text-sm font-medium text-neutral-700 mb-1">Short Description</label>
              <input id="short_description" type="text" value={form.short_description} onChange={(e) => updateField('short_description', e.target.value)} className="input" placeholder="A brief tagline for your event" maxLength={200} disabled={submitting} />
            </div>
            <div>
              <label htmlFor="description" className="block text-sm font-medium text-neutral-700 mb-1">Description</label>
              <textarea id="description" value={form.description} onChange={(e) => updateField('description', e.target.value)} rows={4} className="input" placeholder="Full event description..." disabled={submitting} />
            </div>
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div>
                <label htmlFor="category" className="block text-sm font-medium text-neutral-700 mb-1">Category</label>
                <select id="category" value={form.category} onChange={(e) => updateField('category', e.target.value)} className="input" disabled={submitting}>
                  {CATEGORIES.map(cat => <option key={cat.value} value={cat.value}>{cat.label}</option>)}
                </select>
              </div>
              <div>
                <label htmlFor="age_restriction" className="block text-sm font-medium text-neutral-700 mb-1">Age Restriction</label>
                <select id="age_restriction" value={form.age_restriction} onChange={(e) => updateField('age_restriction', e.target.value)} className="input" disabled={submitting}>
                  {AGE_RESTRICTIONS.map(ar => <option key={ar.value} value={ar.value}>{ar.label}</option>)}
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
              <input id="venue_name" type="text" value={form.venue_name} onChange={(e) => updateField('venue_name', e.target.value)} className={`input ${formErrors.venue_name ? 'input-error' : ''}`} placeholder="e.g., Tumon Beach Club" disabled={submitting} />
              {formErrors.venue_name && <p className="mt-1 text-sm text-red-600">{formErrors.venue_name}</p>}
            </div>
            <div>
              <label htmlFor="venue_address" className="block text-sm font-medium text-neutral-700 mb-1">Venue Address</label>
              <input id="venue_address" type="text" value={form.venue_address} onChange={(e) => updateField('venue_address', e.target.value)} className="input" placeholder="123 Pale San Vitores Rd, Tumon" disabled={submitting} />
            </div>
            <div>
              <label htmlFor="venue_city" className="block text-sm font-medium text-neutral-700 mb-1">City</label>
              <input id="venue_city" type="text" value={form.venue_city} onChange={(e) => updateField('venue_city', e.target.value)} className="input" placeholder="Guam" disabled={submitting} />
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
              <input id="starts_at" type="datetime-local" value={form.starts_at} onChange={(e) => updateField('starts_at', e.target.value)} className={`input ${formErrors.starts_at ? 'input-error' : ''}`} disabled={submitting} />
              {formErrors.starts_at && <p className="mt-1 text-sm text-red-600">{formErrors.starts_at}</p>}
            </div>
            <div>
              <label htmlFor="ends_at" className="block text-sm font-medium text-neutral-700 mb-1">End Date & Time</label>
              <input id="ends_at" type="datetime-local" value={form.ends_at} onChange={(e) => updateField('ends_at', e.target.value)} className={`input ${formErrors.ends_at ? 'input-error' : ''}`} disabled={submitting} />
              {formErrors.ends_at && <p className="mt-1 text-sm text-red-600">{formErrors.ends_at}</p>}
            </div>
            <div>
              <label htmlFor="doors_open_at" className="block text-sm font-medium text-neutral-700 mb-1">Doors Open At</label>
              <input id="doors_open_at" type="datetime-local" value={form.doors_open_at} onChange={(e) => updateField('doors_open_at', e.target.value)} className={`input ${formErrors.doors_open_at ? 'input-error' : ''}`} disabled={submitting} />
              {formErrors.doors_open_at && <p className="mt-1 text-sm text-red-600">{formErrors.doors_open_at}</p>}
            </div>
          </div>
        </section>

        {/* Settings Section */}
        <section>
          <h2 className="text-lg font-semibold text-neutral-900 mb-4 pb-2 border-b border-neutral-200">Settings</h2>
          <div className="space-y-4">
            <div>
              <label htmlFor="max_capacity" className="block text-sm font-medium text-neutral-700 mb-1">Max Capacity</label>
              <input id="max_capacity" type="number" min="1" value={form.max_capacity} onChange={(e) => updateField('max_capacity', e.target.value)} className={`input ${formErrors.max_capacity ? 'input-error' : ''}`} placeholder="Leave blank for unlimited" disabled={submitting} />
              {formErrors.max_capacity && <p className="mt-1 text-sm text-red-600">{formErrors.max_capacity}</p>}
            </div>
            <div className="flex items-center gap-3">
              <input
                id="show_attendees"
                type="checkbox"
                checked={form.show_attendees}
                onChange={(e) => updateField('show_attendees', e.target.checked)}
                className="w-4 h-4 rounded border-neutral-300 text-brand-500 focus:ring-brand-500"
                disabled={submitting}
              />
              <label htmlFor="show_attendees" className="text-sm font-medium text-neutral-700">
                Show attendees on event page
              </label>
            </div>
          </div>
        </section>

        {/* Recurring Event Section */}
        <section>
          <h2 className="text-lg font-semibold text-neutral-900 mb-4 pb-2 border-b border-neutral-200">Recurring Event</h2>
          <div className="space-y-4">
            <div>
              <label htmlFor="recurrence_rule" className="block text-sm font-medium text-neutral-700 mb-1">Recurrence Pattern</label>
              <select id="recurrence_rule" value={form.recurrence_rule} onChange={(e) => updateField('recurrence_rule', e.target.value)} className="input" disabled={submitting}>
                <option value="">None (one-time event)</option>
                <option value="weekly">Weekly</option>
                <option value="biweekly">Bi-weekly</option>
                <option value="monthly">Monthly</option>
              </select>
            </div>
            {form.recurrence_rule && (
              <>
                <div>
                  <label htmlFor="recurrence_end_date" className="block text-sm font-medium text-neutral-700 mb-1">Recurrence End Date (optional)</label>
                  <input id="recurrence_end_date" type="date" value={form.recurrence_end_date} onChange={(e) => updateField('recurrence_end_date', e.target.value)} className="input" disabled={submitting} />
                </div>
                <div>
                  <label htmlFor="recurrence_count" className="block text-sm font-medium text-neutral-700 mb-1">Number of Instances to Generate</label>
                  <input id="recurrence_count" type="number" min="1" max="12" value={recurrenceCount} onChange={(e) => setRecurrenceCount(Math.min(12, Math.max(1, parseInt(e.target.value) || 1)))} className="input" disabled={submitting} />
                </div>
                <button
                  type="button"
                  onClick={async () => {
                    setGeneratingRecurrences(true)
                    setSubmitError(null)
                    try {
                      const res = await apiClient.post(`/organizer/events/${id}/generate_recurrences`, { count: recurrenceCount })
                      setSuccessMessage(`Generated ${res.data.generated_count} recurring event(s).`)
                      setRecurrenceChildren(res.data.events || [])
                    } catch (err) {
                      setSubmitError(err.response?.data?.error || 'Failed to generate recurring events')
                    } finally {
                      setGeneratingRecurrences(false)
                    }
                  }}
                  disabled={generatingRecurrences || !form.starts_at}
                  className="btn-primary text-sm px-4 py-2 flex items-center gap-2 disabled:opacity-50"
                >
                  <RefreshCw className={`w-4 h-4 ${generatingRecurrences ? 'animate-spin' : ''}`} />
                  {generatingRecurrences ? 'Generating...' : 'Generate Upcoming Events'}
                </button>
                {!form.starts_at && (
                  <p className="text-xs text-amber-600">Save the event with start/end dates first before generating recurring instances.</p>
                )}
              </>
            )}
            {/* Show linked recurring events */}
            {(recurrenceChildren.length > 0 || (event?.recurrence_parent_id)) && (
              <div className="mt-4">
                <h3 className="text-sm font-medium text-neutral-700 mb-2">Linked Recurring Events</h3>
                <div className="space-y-2">
                  {event?.recurrence_parent_id && (
                    <Link to={`/dashboard/events/${event.recurrence_parent_id}/edit`} className="block text-sm text-brand-500 hover:text-brand-700">
                      ← View Parent Event
                    </Link>
                  )}
                  {recurrenceChildren.map(child => (
                    <Link key={child.id} to={`/dashboard/events/${child.id}/edit`} className="block p-2 rounded-lg bg-neutral-50 hover:bg-neutral-100 text-sm text-neutral-700 transition-colors">
                      {child.title} — {child.starts_at ? new Date(child.starts_at).toLocaleDateString() : 'No date set'}
                    </Link>
                  ))}
                </div>
              </div>
            )}
          </div>
        </section>

        {/* Submit */}
        <div className="pt-4 border-t border-neutral-200">
          <button type="submit" disabled={submitting} className="btn-primary w-full sm:w-auto">
            {submitting ? 'Saving...' : 'Save Changes'}
          </button>
        </div>
      </form>

      {/* Ticket Types CRUD */}
      <TicketTypeCRUD eventId={id} ticketTypes={event?.ticket_types || []} onRefresh={fetchEvent} />

      {/* Danger Zone — HP-28 */}
      {event && event.status !== 'cancelled' && event.status !== 'completed' && (
        <div className="mt-8 border border-red-200 rounded-xl p-5 sm:p-6">
          <h2 className="text-lg font-semibold text-red-700 mb-1 flex items-center gap-2">
            <AlertTriangle className="w-5 h-5" /> Danger Zone
          </h2>
          <p className="text-sm text-neutral-500 mb-4">These actions are irreversible. Please proceed with caution.</p>
          <div className="space-y-3">
            {(event.status === 'draft' || event.status === 'published') && (
              <div className="flex items-center justify-between p-3 bg-red-50 rounded-xl">
                <div>
                  <p className="text-sm font-medium text-neutral-900">Cancel Event</p>
                  <p className="text-xs text-neutral-500">Cancel this event and notify ticket holders.</p>
                </div>
                <button onClick={() => setShowCancelConfirm(true)} className="px-3 py-1.5 text-sm font-medium text-red-600 border border-red-300 rounded-lg hover:bg-red-100 transition-colors flex items-center gap-1.5">
                  <XCircle className="w-4 h-4" /> Cancel Event
                </button>
              </div>
            )}
            {event.status === 'published' && eventEndedInPast && (
              <div className="flex items-center justify-between p-3 bg-neutral-50 rounded-xl">
                <div>
                  <p className="text-sm font-medium text-neutral-900">Mark Completed</p>
                  <p className="text-xs text-neutral-500">Mark this past event as completed.</p>
                </div>
                <button onClick={() => setShowCompleteConfirm(true)} className="px-3 py-1.5 text-sm font-medium text-neutral-700 border border-neutral-300 rounded-lg hover:bg-neutral-200 transition-colors flex items-center gap-1.5">
                  <CheckCircle2 className="w-4 h-4" /> Complete
                </button>
              </div>
            )}
            {event.status === 'draft' && (
              <div className="flex items-center justify-between p-3 bg-red-50 rounded-xl">
                <div>
                  <p className="text-sm font-medium text-neutral-900">Delete Event</p>
                  <p className="text-xs text-neutral-500">Permanently delete this draft event.</p>
                </div>
                <button onClick={() => setShowDeleteConfirm(true)} className="px-3 py-1.5 text-sm font-medium text-red-600 border border-red-300 rounded-lg hover:bg-red-100 transition-colors flex items-center gap-1.5">
                  <Trash2 className="w-4 h-4" /> Delete
                </button>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  )
}
