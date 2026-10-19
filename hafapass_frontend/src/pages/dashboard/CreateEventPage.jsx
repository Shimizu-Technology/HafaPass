import { validEventCapacity } from '../../utils/eventCapacity'
import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import apiClient from '../../api/client'
import EventAccessNotice from '../../components/EventAccessNotice'
import { BackLink, PageHeader, WorkspacePage } from '../../components/WorkspacePage'
import CoverImageUpload from '../../components/CoverImageUpload'
import { ClipboardList } from 'lucide-react'
import useEventCategories from '../../hooks/useEventCategories'
import { compareLocalDateTimes } from '../../utils/eventTime'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import useDraftProtection from '../../hooks/useDraftProtection'
import FormErrorSummary from '../../components/FormErrorSummary'
import { emptyEventForm, hasNewEventDraft, newEventDraftKey, readNewEventDraft } from '../../utils/newEventDraft'

const AGE_RESTRICTIONS = [
 { value: 'all_ages', label: 'All Ages' },
 { value: 'eighteen_plus', label: '18+' },
 { value: 'twenty_one_plus', label: '21+' }
]

export default function CreateEventPage() {
 const identity = useOrganizerIdentity()
 const visit = useOrganizerPageVisit('/dashboard/events/new')
 if (!visit.active) return null
 if (!identity.ready) return <p role="status" className="p-6">Preparing your account…</p>
 return <CreateEventSession key={`${identity.accountKey}:${identity.organizationId}:${visit.generation}`} identity={identity} />
}

function CreateEventSession({ identity }) {
 const navigate = useNavigate()
 const { current, beginRequest } = useOrganizerRequests(identity, '/dashboard/events/new')
 const created = useRef(false)
 const [draftKey, setDraftKey] = useState('')
 const [recoveryAvailable, setRecoveryAvailable] = useState(true)
 const [restored, setRestored] = useState(false)
 const categories = useEventCategories()
 const [access, setAccess] = useState(null)
 const [accessError, setAccessError] = useState('')
 useEffect(() => {
  const request = beginRequest()
  if (!request) return
  apiClient.get('/organizer/organization', request.config).then(response => {
   if (!request.current()) return
   if (identity.organizationId != null && String(response.data.id) !== String(identity.organizationId)) {
    setAccessError('Your organization changed. Return to your dashboard and select it again.'); return
   }
   const allowed = response.data.permissions?.manage_events === true
   if (allowed) {
    // The dashboard can turn an implicit default organization into an explicit
    // selection. Both must recover the same verified organization's draft.
    const key = newEventDraftKey({ authContext: identity.authContext, owner: identity.owner, organizationId: response.data.id == null ? identity.organizationId : String(response.data.id) })
    const saved = readNewEventDraft(key)
    setDraftKey(key); setForm(saved.form); setRestored(saved.restored)
   }
   setAccess(allowed)
  }).catch(() => {
   if (request.current()) setAccessError('Could not confirm event creation access. Return to your dashboard and try again.')
  }).finally(() => request.release())
  return () => request.controller.abort()
 }, [beginRequest, identity.organizationId, identity.owner, identity.authContext])
 const [submitting, setSubmitting] = useState(false)
 const [error, setError] = useState(null)
 const [formErrors, setFormErrors] = useState({})

 const [form, setForm] = useState(() => ({ ...emptyEventForm }))
 const dirty = hasNewEventDraft(form)
 const draftCurrent = useCallback(() => current() && !created.current, [current])
 useDraftProtection({ dirty, scope: draftKey, pathname: '/dashboard/events/new', isCurrent: draftCurrent })
 useEffect(() => {
  if (!access || !draftKey || !current() || created.current) return
  try {
   if (dirty) window.sessionStorage.setItem(draftKey, JSON.stringify(form))
   else window.sessionStorage.removeItem(draftKey)
   setRecoveryAvailable(true)
  } catch { setRecoveryAvailable(false) }
 }, [form, dirty, access, current, draftKey])

 const updateField = (field, value) => {
  if (!current()) return
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
   if (compareLocalDateTimes(form.ends_at, form.starts_at) <= 0) {
    errors.ends_at = 'End time must be after the start time'
   }
  }

  // Cross-field validation: doors open must be before start time
  if (form.doors_open_at && form.starts_at) {
   if (compareLocalDateTimes(form.doors_open_at, form.starts_at) > 0) {
    errors.doors_open_at = 'Doors open time must be before the start time'
   }
  }

  // Max capacity must be a positive integer
  if (form.max_capacity) {
   if (!validEventCapacity(form.max_capacity)) {
    errors.max_capacity = 'Max capacity must be a positive integer'
   }
  }

  setFormErrors(errors)
  if (Object.keys(errors).length) requestAnimationFrame(() => { if (current()) document.getElementById(Object.keys(errors)[0])?.focus() })
  return Object.keys(errors).length === 0
 }

 const handleSubmit = async (e) => {
  e.preventDefault()
  if (!current() || !access || submitting || !validate()) return
  const request = beginRequest()
  if (!request) return

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
    timezone: 'Pacific/Guam',
    starts_at: form.starts_at || undefined,
    ends_at: form.ends_at || undefined,
    doors_open_at: form.doors_open_at || undefined,
    max_capacity: form.max_capacity ? Number(form.max_capacity) : undefined,
    cover_image_url: form.cover_image_url.trim() || undefined
   }

   const res = await apiClient.post('/organizer/events', payload, request.config)
   if (!request.current()) return
   created.current = true
   try { window.sessionStorage.removeItem(draftKey) } catch { /* The saved event remains authoritative. */ }
   navigate(`/dashboard/events/${res.data.id}/edit`)
  } catch (err) {
   if (!request.current()) return
   const msg = err.response?.data?.errors?.join(', ') || err.response?.data?.error || 'Failed to create event'
   setError(msg)
  } finally {
   if (request.current()) setSubmitting(false)
   request.release()
  }
 }

 if (accessError) return <EventAccessNotice message={accessError} />
 if (access === null) return <p className="mx-auto max-w-3xl px-4 py-8 sm:px-6 lg:px-8" role="status">Checking event creation access…</p>
 if (!access) return <EventAccessNotice message="Your organization access does not include creating events. Open your assigned tasks from the dashboard." />

 return (
  <WorkspacePage width="form">
   <PageHeader back={<BackLink />} title="Create New Event" className="!mb-6" />

   {error && (
    <div role="alert" className="mb-6 p-4 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm">
     {error}
    </div>
   )}

   <div className="mb-6 rounded-xl border border-neutral-200 bg-white p-4 text-sm text-neutral-700">
    <p role="status">{!recoveryAvailable ? 'Draft recovery is unavailable in this browser. Stay here until you create the event.' : restored ? 'Your unfinished event was restored in this tab. It has not been created yet.' : 'Unfinished details are kept in this tab until you create the event. They are not saved to your organization yet.'}</p>
    {dirty && <button type="button" className="mt-2 min-h-11 font-semibold text-red-700 underline" disabled={submitting} onClick={() => {
     if (!window.confirm('Discard these unfinished event details?')) return
     setForm({ ...emptyEventForm }); setRestored(false); setFormErrors({}); setError(null)
    }}>Discard unfinished event</button>}
   </div>
   <FormErrorSummary errors={formErrors} />
   <form noValidate onSubmit={handleSubmit} className="space-y-8">
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
        aria-invalid={Boolean(formErrors.title)}
        aria-describedby={formErrors.title ? 'title-error' : undefined}
        required
        type="text"
        value={form.title}
        onChange={(e) => updateField('title', e.target.value)}
        className={`input ${formErrors.title ? 'input-error' : ''}`}
        placeholder="e.g., Full Moon Beach Party"
        disabled={submitting}
       />
       {formErrors.title && <p id="title-error" className="mt-1 text-sm text-red-600">{formErrors.title}</p>}
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
         {categories.map(cat => (
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
        aria-invalid={Boolean(formErrors.venue_name)}
        aria-describedby={formErrors.venue_name ? 'venue_name-error' : undefined}
        required
        type="text"
        value={form.venue_name}
        onChange={(e) => updateField('venue_name', e.target.value)}
        className={`input ${formErrors.venue_name ? 'input-error' : ''}`}
        placeholder="e.g., Tumon Beach Club"
        disabled={submitting}
       />
       {formErrors.venue_name && <p id="venue_name-error" className="mt-1 text-sm text-red-600">{formErrors.venue_name}</p>}
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
     <p className="text-sm text-neutral-500 mb-4">All event times are entered and displayed in Guam time (Pacific/Guam).</p>
     <div className="space-y-4">
      <div>
       <label htmlFor="starts_at" className="block text-sm font-medium text-neutral-700 mb-1">
        Start Date & Time <span className="text-red-500">*</span>
       </label>
       <input
        id="starts_at"
        aria-invalid={Boolean(formErrors.starts_at)}
        aria-describedby={formErrors.starts_at ? 'starts_at-error' : undefined}
        required
        type="datetime-local"
        value={form.starts_at}
        onChange={(e) => updateField('starts_at', e.target.value)}
        className={`input ${formErrors.starts_at ? 'input-error' : ''}`}
        disabled={submitting}
       />
       {formErrors.starts_at && <p id="starts_at-error" className="mt-1 text-sm text-red-600">{formErrors.starts_at}</p>}
      </div>

      <div>
       <label htmlFor="ends_at" className="block text-sm font-medium text-neutral-700 mb-1">
        End Date & Time
       </label>
       <input
        id="ends_at"
        aria-invalid={Boolean(formErrors.ends_at)}
        aria-describedby={formErrors.ends_at ? 'ends_at-error' : undefined}
        type="datetime-local"
        value={form.ends_at}
        onChange={(e) => updateField('ends_at', e.target.value)}
        className={`input ${formErrors.ends_at ? 'input-error' : ''}`}
        disabled={submitting}
       />
       {formErrors.ends_at && <p id="ends_at-error" className="mt-1 text-sm text-red-600">{formErrors.ends_at}</p>}
      </div>

      <div>
       <label htmlFor="doors_open_at" className="block text-sm font-medium text-neutral-700 mb-1">
        Doors Open At
       </label>
       <input
        id="doors_open_at"
        aria-invalid={Boolean(formErrors.doors_open_at)}
        aria-describedby={formErrors.doors_open_at ? 'doors_open_at-error' : undefined}
        type="datetime-local"
        value={form.doors_open_at}
        onChange={(e) => updateField('doors_open_at', e.target.value)}
        className={`input ${formErrors.doors_open_at ? 'input-error' : ''}`}
        disabled={submitting}
       />
       {formErrors.doors_open_at && <p id="doors_open_at-error" className="mt-1 text-sm text-red-600">{formErrors.doors_open_at}</p>}
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
        aria-invalid={Boolean(formErrors.max_capacity)}
        aria-describedby={formErrors.max_capacity ? 'max_capacity-error' : undefined}
        type="number"
        min="1"
        value={form.max_capacity}
        onChange={(e) => updateField('max_capacity', e.target.value)}
        className={`input ${formErrors.max_capacity ? 'input-error' : ''}`}
        placeholder="Leave blank for unlimited"
        disabled={submitting}
       />
       {formErrors.max_capacity && <p id="max_capacity-error" className="mt-1 text-sm text-red-600">{formErrors.max_capacity}</p>}
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
      <p className="text-sm text-brand-700 flex items-start gap-2"><ClipboardList className="w-4 h-4 mt-0.5 shrink-0" /> <span><strong>You&apos;ll add ticket types on the next step.</strong> After creating the event, you&apos;ll be taken to the edit page where you can set up ticket types, upload a cover image, and publish.</span></p>
     </div>
    </div>
   </form>
  </WorkspacePage>
 )
}
