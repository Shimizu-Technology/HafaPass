import { validEventCapacity } from '../../utils/eventCapacity'
import EventWorkspace from '../../components/EventWorkspace'
import { Loader2 } from 'lucide-react'
import { useState, useEffect, useCallback, useRef } from 'react'
import { useParams, Link, useNavigate } from 'react-router-dom'
import { AlertTriangle, Trash2, XCircle, CheckCircle2, Eye, Copy, RefreshCw, PauseCircle, Archive, Link2 } from 'lucide-react'
import EventAccessNotice from '../../components/EventAccessNotice'
import apiClient from '../../api/client'
import CoverImageUpload from '../../components/CoverImageUpload'
import TicketTypeCRUD from '../../components/TicketTypeCRUD'
import FeePolicyPanel from '../../components/FeePolicyPanel'
import useEventCategories from '../../hooks/useEventCategories'
import Dialog from '../../components/Dialog'
import FormErrorSummary from '../../components/FormErrorSummary'
import { organizerChecklist } from '../../utils/organizerChecklist'
import useLaunchCapabilities from '../../hooks/useLaunchCapabilities'
import { compareLocalDateTimes, formatEventDate, toEventLocalInput } from '../../utils/eventTime'
import { eventLinkFormatError, eventLinkUrl, normalizeEventLinkInput } from '../../utils/eventLink'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'

const AGE_RESTRICTIONS = [
  { value: 'all_ages', label: 'All Ages' },
  { value: 'eighteen_plus', label: '18+' },
  { value: 'twenty_one_plus', label: '21+' }
]

const eventForm = e => ({
  title: e.title || '',
  slug: e.slug || '',
  short_description: e.short_description || '',
  description: e.description || '',
  category: e.category || 'other',
  age_restriction: e.age_restriction || 'all_ages',
  venue_name: e.venue_name || '',
  venue_address: e.venue_address || '',
  venue_city: e.venue_city || 'Guam',
  starts_at: toEventLocalInput(e.starts_at, e.timezone),
  ends_at: toEventLocalInput(e.ends_at, e.timezone),
  doors_open_at: toEventLocalInput(e.doors_open_at, e.timezone),
  max_capacity: e.max_capacity ? String(e.max_capacity) : '',
  cover_image_url: e.cover_image_url || '',
  recurrence_rule: e.recurrence_rule || '',
  recurrence_end_date: e.recurrence_end_date || '',
  show_attendees: e.show_attendees !== false
})

function ConfirmModal({ title, message, confirmLabel, confirmClass, onConfirm, onCancel, loading, reason, onReasonChange, requireReason = false }) {
  return (
    <Dialog labelledBy="event-confirm-title" onClose={onCancel} busy={loading} className="max-w-md">
        <h3 id="event-confirm-title" className="text-lg font-semibold text-neutral-900 mb-2">{title}</h3>
        <p className="text-sm text-neutral-600 mb-4">{message}</p>
        {requireReason && (
          <div className="mb-4">
            <label htmlFor="lifecycle-reason" className="block text-sm font-medium text-neutral-700 mb-1">Reason <span className="text-red-500">*</span></label>
            <textarea id="lifecycle-reason" value={reason} onChange={event => onReasonChange(event.target.value)} className="input" rows={3} placeholder="Explain this change for attendees and the audit record" />
          </div>
        )}
        <div className="flex gap-3 justify-end">
          <button onClick={onCancel} disabled={loading} className="px-4 py-2 text-sm font-medium text-neutral-700 hover:text-neutral-900 disabled:opacity-50">Cancel</button>
          <button onClick={onConfirm} disabled={loading || (requireReason && !reason?.trim())} className={`px-4 py-2 text-sm font-medium rounded-xl text-white ${confirmClass || 'bg-action-danger hover:bg-action-danger-hover'} disabled:opacity-50`}>
            {loading ? 'Processing...' : confirmLabel}
          </button>
        </div>
    </Dialog>
  )
}

function EditEventSession({ id, identity }) {
  const { current, beginRequest } = useOrganizerRequests(identity, `/dashboard/events/${id}/edit`)
  const loadGeneration = useRef(0)
  const pendingLoad = useRef(null)
  const inventoryGeneration = useRef(0)
  const eventSaveGeneration = useRef(0)
  const pendingInventoryLoad = useRef(null)
  const [inventoryRefreshing, setInventoryRefreshing] = useState(false)
  const [inventoryError, setInventoryError] = useState(null)
  const navigate = useNavigate()
  const categories = useEventCategories()
  const capabilities = useLaunchCapabilities()
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [event, setEvent] = useState(null)
  const permissions = event?.permissions || {}
  const [feeChoiceDirty, setFeeChoiceDirty] = useState(false)
  const canManage = permissions.manage_events === true
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
  const [showPostponeConfirm, setShowPostponeConfirm] = useState(false)
  const [lifecycleReason, setLifecycleReason] = useState('')
  const [dangerLoading, setDangerLoading] = useState(false)
  const [cloning, setCloning] = useState(false)
  const [recurrenceCount, setRecurrenceCount] = useState(4)
  const [generatingRecurrences, setGeneratingRecurrences] = useState(false)
  const [recurrenceChildren, setRecurrenceChildren] = useState([])
  const [changeReason, setChangeReason] = useState('')

  const [form, setForm] = useState({
    title: '',
    slug: '',
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

  const savedForm = eventForm(event || {})
  const hasUnsavedChanges = Object.keys(form).some(field => {
    const value = typeof form[field] === 'string' ? form[field].trim() : form[field]
    const savedValue = typeof savedForm[field] === 'string' ? savedForm[field].trim() : savedForm[field]
    return value !== savedValue
  })


  const fetchEvent = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    pendingLoad.current?.controller.abort()
    pendingLoad.current = request
    const generation = ++loadGeneration.current
    const canApply = () => request.current() && generation === loadGeneration.current
    setLoading(true)
    setError(null)
    try {
      const res = await apiClient.get(`/organizer/events/${id}`, request.config)
      if (!canApply()) return
      const e = res.data
      setEvent(e)
      setForm(eventForm(e))
    } catch (err) {
      if (!canApply()) return
      if (err.response?.status === 401) {
        setError('Please sign in to access this page.')
      } else if (err.response?.status === 404) {
        setError('Event not found.')
      } else {
        setError('Failed to load event.')
      }
    } finally {
      request.release()
      if (canApply()) setLoading(false)
    }
  }, [id, beginRequest])

  // Ticket mutations refresh saved inventory, not the event draft or its
  // schedule baseline. Keep the editor mounted while this request is pending.
  const refreshInventory = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    pendingInventoryLoad.current?.controller.abort()
    pendingInventoryLoad.current = request
    const generation = ++inventoryGeneration.current
    const savedGeneration = eventSaveGeneration.current
    const canApply = () => request.current() && generation === inventoryGeneration.current
    setInventoryRefreshing(true)
    setInventoryError(null)
    try {
      const res = await apiClient.get(`/organizer/events/${id}`, request.config)
      if (!canApply()) return
      setEvent(saved => ({ ...saved, ticket_types: res.data.ticket_types || [],
        // A successful event save owns newer readiness and access metadata.
        // Still apply ticket data without reviving its pre-save checklist.
        ...(savedGeneration === eventSaveGeneration.current ? {
          publish_checklist: res.data.publish_checklist || [],
          permissions: res.data.permissions || saved.permissions,
        } : {}) }))
    } catch {
      if (canApply()) setInventoryError('Ticket changes were saved, but the latest ticket list could not be loaded. Retry to update the list. Your event draft is still here.')
    } finally {
      if (canApply()) setInventoryRefreshing(false)
      request.release()
    }
  }, [id, beginRequest])

  useEffect(() => {
    fetchEvent()
  }, [fetchEvent])

  const updateField = (field, value) => {
    if (!current()) return
    setForm(prev => ({ ...prev, [field]: value }))
    if (formErrors[field]) {
      setFormErrors(prev => ({ ...prev, [field]: null }))
    }
    setSuccessMessage(null)
  }

  // The link name is checked against the API (reserved words and links other
  // events use now or used before) shortly after the organizer stops typing.
  const [linkCheck, setLinkCheck] = useState(null)
  const linkSlug = form.slug.trim()
  const linkChanged = Boolean(event) && linkSlug !== (event.slug || '')
  const linkFormatError = linkChanged ? eventLinkFormatError(linkSlug) : null
  useEffect(() => {
    if (!linkChanged || linkFormatError) return undefined
    const request = beginRequest()
    if (!request) return undefined
    const timer = setTimeout(async () => {
      setLinkCheck({ slug: linkSlug, status: 'checking' })
      try {
        const res = await apiClient.get(`/organizer/events/${id}/slug_availability`, { ...request.config, params: { slug: linkSlug } })
        if (request.current()) setLinkCheck({ slug: linkSlug, status: res.data.available ? 'available' : 'taken', message: res.data.message })
      } catch {
        if (request.current()) setLinkCheck({ slug: linkSlug, status: 'unknown' })
      } finally {
        request.release()
      }
    }, 400)
    return () => { clearTimeout(timer); request.controller.abort(); request.release() }
  }, [id, linkSlug, linkChanged, linkFormatError, beginRequest])
  const currentLinkCheck = linkCheck?.slug === linkSlug ? linkCheck : null
  const linkError = formErrors.slug || linkFormatError || (currentLinkCheck?.status === 'taken' ? currentLinkCheck.message : null)

  // Keep seconds in untouched API timestamps instead of rewriting them from
  // minute-precision inputs. Null explicitly clears an edited optional time.
  const scheduleChanges = Object.fromEntries(
    ['starts_at', 'ends_at', 'doors_open_at']
      .filter(field => event && form[field] !== toEventLocalInput(event[field], event.timezone))
      .map(field => [field, form[field] || null]),
  )
  const scheduleChanged = Object.keys(scheduleChanges).length > 0

  const validate = () => {
    const errors = {}
    if (!form.title.trim()) errors.title = 'Title is required'
    if (linkChanged) {
      const linkProblem = linkFormatError || (currentLinkCheck?.status === 'taken' ? currentLinkCheck.message : null)
      if (linkProblem) errors.slug = linkProblem
    }
    if (canManage) {
      if (!form.venue_name.trim()) errors.venue_name = 'Venue name is required'
      if (!form.starts_at) errors.starts_at = 'Start date/time is required'
      if (form.ends_at && form.starts_at) {
        if (compareLocalDateTimes(form.ends_at, form.starts_at) <= 0) {
          errors.ends_at = 'End time must be after the start time'
        }
      }
      if (form.doors_open_at && form.starts_at) {
        if (compareLocalDateTimes(form.doors_open_at, form.starts_at) > 0) {
          errors.doors_open_at = 'Doors open time must be before the start time'
        }
      }
      if (form.max_capacity) {
        if (!validEventCapacity(form.max_capacity)) {
          errors.max_capacity = 'Max capacity must be a positive integer'
        }
      }
      if (scheduleChanged && ['published', 'postponed'].includes(event?.status) && !changeReason.trim()) {
        errors.change_reason = 'Explain the schedule change for ticket holders'
      }
    }
    setFormErrors(errors)
    if (Object.keys(errors).length) requestAnimationFrame(() => { if (current()) document.getElementById(Object.keys(errors)[0])?.focus() })
    return Object.keys(errors).length === 0
  }

  const handleSubmit = async (e) => {
    e.preventDefault()
    if (!current() || submitting || !permissions.edit_event_content || !validate()) return
    const request = beginRequest()
    if (!request) return
    const submittedForm = form
    setSubmitting(true)
    setSubmitError(null)
    setSuccessMessage(null)
    try {
      const payload = {
        title: form.title.trim(),
        ...(linkChanged ? { slug: linkSlug } : {}),
        short_description: form.short_description.trim() || null,
        description: form.description.trim() || null,
        category: form.category,
        age_restriction: form.age_restriction,
        venue_name: form.venue_name.trim(),
        venue_address: form.venue_address.trim() || null,
        venue_city: form.venue_city.trim() || 'Guam',
        timezone: event?.timezone || 'Pacific/Guam',
        ...scheduleChanges,
        max_capacity: form.max_capacity ? Number(form.max_capacity) : null,
        cover_image_url: form.cover_image_url.trim() || null,
        recurrence_rule: form.recurrence_rule || null,
        recurrence_end_date: form.recurrence_end_date || null,
        show_attendees: form.show_attendees
      }
      if (!canManage) {
        const presentationFields = ['title', 'slug', 'short_description', 'description', 'category', 'cover_image_url']
        Object.keys(payload).forEach(key => { if (!presentationFields.includes(key)) delete payload[key] })
      }
      if (canManage && scheduleChanged) payload.change_reason = changeReason.trim() || undefined
      const res = await apiClient.put(`/organizer/events/${id}`, payload, request.config)
      if (!request.current()) return
      eventSaveGeneration.current += 1
      setEvent(current => ({ ...current, ...res.data }))
      const canonicalForm = eventForm({ ...event, ...res.data })
      // Reconcile only fields the server returned, and only if they still
      // match the submitted snapshot. Partial responses and a later upload
      // callback must not erase the organizer's remaining draft.
      setForm(latest => Object.fromEntries(Object.entries(latest).map(([field, value]) => [field,
        Object.hasOwn(res.data, field) && value === submittedForm[field] ? canonicalForm[field] : value,
      ])))
      setChangeReason('')
      setSuccessMessage('Event updated successfully.')
    } catch (err) {
      if (!request.current()) return
      const errors = err.response?.data?.errors || []
      const linkMessage = errors.find(message => message.startsWith('Event link'))
      if (linkMessage) {
        setFormErrors(prev => ({ ...prev, slug: linkMessage }))
        requestAnimationFrame(() => { if (current()) document.getElementById('slug')?.focus() })
      }
      const otherErrors = errors.filter(message => message !== linkMessage)
      if (!linkMessage || otherErrors.length) {
        setSubmitError(otherErrors.join(', ') || err.response?.data?.error || 'Failed to update event')
      }
    } finally {
      request.release()
      if (request.current()) setSubmitting(false)
    }
  }

  const handlePublish = async () => {
    if (!current() || publishing || submitting || hasUnsavedChanges || !canManage) return
    const request = beginRequest()
    if (!request) return
    setPublishing(true)
    setSubmitError(null)
    try {
      const res = await apiClient.post(`/organizer/events/${id}/publish`, {}, request.config)
      if (!request.current()) return
      setEvent(current => ({ ...current, ...res.data }))
      setShowPublishConfirm(false)
      setSuccessMessage('Event published successfully!')
    } catch (err) {
      if (!request.current()) return
      const msg = err.response?.data?.error || 'Failed to publish event'
      setSubmitError(msg)
      setShowPublishConfirm(false)
    } finally {
      request.release()
      if (request.current()) setPublishing(false)
    }
  }

  // Danger zone actions
  const handleLifecycle = async (action, success) => {
    if (dangerLoading) return
    const request = beginRequest()
    if (!request) return
    setDangerLoading(true)
    setSubmitError(null)
    try {
      const res = await apiClient.post(`/organizer/events/${id}/${action}`, { reason: lifecycleReason.trim() || undefined }, request.config)
      if (!request.current()) return
      setEvent(current => ({ ...current, ...res.data }))
      setShowCancelConfirm(false)
      setShowCompleteConfirm(false)
      setShowPostponeConfirm(false)
      setLifecycleReason('')
      setSuccessMessage(success)
    } catch (err) {
      if (!request.current()) return
      setSubmitError(err.response?.data?.error || `Failed to ${action} event`)
      setShowCancelConfirm(false)
      setShowCompleteConfirm(false)
      setShowPostponeConfirm(false)
    } finally {
      request.release()
      if (request.current()) setDangerLoading(false)
    }
  }

  const handleDeleteEvent = async () => {
    if (dangerLoading) return
    const request = beginRequest()
    if (!request) return
    setDangerLoading(true)
    try {
      await apiClient.delete(`/organizer/events/${id}`, request.config)
      if (request.current()) navigate('/dashboard')
    } catch (err) {
      if (!request.current()) return
      setSubmitError(err.response?.data?.error || 'Failed to delete event')
      setShowDeleteConfirm(false)
    } finally {
      request.release()
      if (request.current()) setDangerLoading(false)
    }
  }

  const eventEndedInPast = event?.ends_at && new Date(event.ends_at) < new Date()
  const publishChecklist = event?.publish_checklist || []
  const remainingTicketCapacity = event?.max_capacity == null ? null : Math.max(0,
    Number(event.max_capacity) - (event.ticket_types || []).reduce((sum, ticket) => sum + Number(ticket.quantity_available || 0), 0))
  const organizerSteps = organizerChecklist(publishChecklist)
  const readyToPublish = publishChecklist.length > 0 && publishChecklist.every(item => item.complete)

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
        <Link to="/dashboard" className="mt-4 inline-block text-action-teal hover:text-action-teal-hover text-sm font-medium">Back to Dashboard</Link>
      </div>
    )
  }

  if (!permissions.edit_event_content) return <EventWorkspace eventId={id} event={event}><EventAccessNotice event={{ ...event, title: 'Your event tools' }} /></EventWorkspace>


  return (
    <EventWorkspace eventId={id} event={event} hasUnsavedChanges={hasUnsavedChanges || feeChoiceDirty}><div className="mx-auto max-w-3xl">
      <div className="mb-6 flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="flex flex-wrap items-center gap-x-4 gap-y-3 sm:justify-end">
          {event?.slug && (
            <a
              href={`/events/${event.slug}${event.status === 'published' || event.status === 'completed' ? '' : '?preview=true'}`}
              target="_blank"
              rel="noopener noreferrer"
              className="text-action-teal hover:text-action-teal-hover text-sm font-medium flex items-center gap-1"
            >
              <Eye className="w-4 h-4" /> Preview saved event
            </a>
          )}
          {canManage && <button
            onClick={async () => {
              if (cloning) return
              const request = beginRequest()
              if (!request) return
              setCloning(true)
              try {
                const res = await apiClient.post(`/organizer/events/${id}/clone`, {}, request.config)
                if (!request.current()) return
                setSuccessMessage('Event cloned! Update the details and publish when ready.')
                navigate(`/dashboard/events/${res.data.id}/edit`)
              } catch (err) {
                if (!request.current()) return
                setSubmitError(err.response?.data?.errors?.join(', ') || 'Failed to clone event')
              } finally {
                request.release()
                if (request.current()) setCloning(false)
              }
            }}
            disabled={cloning}
            className="text-action-teal hover:text-action-teal-hover text-sm font-medium flex items-center gap-1 disabled:opacity-50"
          >
            <Copy className="w-4 h-4" /> {cloning ? 'Cloning...' : 'Clone'}
          </button>}
        </div>
      </div>

      <h2 className="mb-6 text-xl font-semibold text-neutral-950">Event details</h2>

      {hasUnsavedChanges && <p role="status" className="mb-4 rounded-xl border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900">You have unsaved changes. Save Changes before publishing. Preview shows the last saved event.</p>}

      {/* Publish Button for Draft Events */}
      {canManage && event?.status === 'draft' && (
        <div className="mb-6 p-4 bg-brand-50 border border-brand-200 rounded-xl">
          <div className="flex flex-col items-start justify-between gap-3 sm:flex-row sm:items-center">
            <div>
              <p className="text-sm font-medium text-brand-800">Prepare your event for publishing</p>
              <p className="text-xs text-brand-600 mt-0.5">Complete the steps below, save your changes, and preview your event before publishing.</p>
            </div>
            <button onClick={() => setShowPublishConfirm(true)} disabled={!readyToPublish || hasUnsavedChanges || submitting || publishing} className="btn-primary text-sm px-4 py-2 disabled:opacity-50">Publish Event</button>
          </div>
          <ul className="grid sm:grid-cols-2 gap-2 mt-4" aria-label="Publishing checklist">
            {organizerSteps.map(item => (
              <li key={item.code} className={`flex items-center gap-2 text-xs ${item.complete ? 'text-emerald-700' : 'text-neutral-600'}`}>
                {item.complete ? <CheckCircle2 className="w-4 h-4 shrink-0" /> : <XCircle className="w-4 h-4 shrink-0" />}
                <div>{item.href && !item.complete ? <a href={item.href} className="underline underline-offset-2">{item.label}</a> : item.label}
                  {item.detail && <p className="mt-1 text-xs font-normal text-neutral-600">{item.detail}</p>}
                </div>
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* Publish Confirmation Dialog */}
      {showPublishConfirm && (
        <ConfirmModal
          title="Publish Event?"
          message={`Publish the saved event “${event.title}”? Attendees will be able to browse and purchase tickets.`}
          confirmLabel={publishing ? 'Publishing...' : 'Yes, Publish'}
          confirmClass="bg-action-teal hover:bg-action-teal-hover"
          onConfirm={handlePublish}
          onCancel={() => setShowPublishConfirm(false)}
          loading={publishing}
        />
      )}

      {/* Danger zone modals */}
      {showCancelConfirm && (
        <ConfirmModal
          title="Cancel Event?"
          message="Ticket sales and public discovery will stop immediately. The reason is retained in the event history."
          confirmLabel="Yes, Cancel Event"
          onConfirm={() => handleLifecycle('cancel', 'Event has been cancelled.')}
          onCancel={() => { setShowCancelConfirm(false); setLifecycleReason('') }}
          loading={dangerLoading}
          reason={lifecycleReason}
          onReasonChange={setLifecycleReason}
          requireReason
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
          onConfirm={() => handleLifecycle('complete', 'Event marked as completed.')}
          onCancel={() => setShowCompleteConfirm(false)}
          loading={dangerLoading}
        />
      )}
      {showPostponeConfirm && (
        <ConfirmModal
          title="Postpone Event?"
          message="Ticket sales will stop immediately. Update the schedule before resuming the event."
          confirmLabel="Yes, Postpone"
          confirmClass="bg-action-danger hover:bg-action-danger-hover"
          onConfirm={() => handleLifecycle('postpone', 'Event has been postponed and sales are paused.')}
          onCancel={() => { setShowPostponeConfirm(false); setLifecycleReason('') }}
          loading={dangerLoading}
          reason={lifecycleReason}
          onReasonChange={setLifecycleReason}
          requireReason
        />
      )}

      {successMessage && (
        <div className="mb-6 p-4 bg-green-50 border border-green-200 rounded-xl text-green-700 text-sm" role="status">{successMessage}</div>
      )}

      {submitError && (
        <div className="mb-6 p-4 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm" role="alert">{submitError}</div>
      )}

      <FormErrorSummary errors={formErrors} />
      <form noValidate onSubmit={handleSubmit} className="space-y-8">
        {/* Cover Image Upload */}
        <section>
          <h2 className="text-lg font-semibold text-neutral-900 mb-4 pb-2 border-b border-neutral-200">Cover Image</h2>
          <CoverImageUpload
            eventId={id}
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
              <input id="title" aria-invalid={Boolean(formErrors.title)} aria-describedby={formErrors.title ? 'title-error' : undefined} required type="text" value={form.title} onChange={(e) => updateField('title', e.target.value)} className={`input ${formErrors.title ? 'input-error' : ''}`} placeholder="e.g., Full Moon Beach Party" disabled={submitting} />
              {formErrors.title && <p id="title-error" className="mt-1 text-sm text-red-600">{formErrors.title}</p>}
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
                  {categories.map(cat => <option key={cat.value} value={cat.value}>{cat.label}</option>)}
                </select>
              </div>
              {canManage && <div>
                <label htmlFor="age_restriction" className="block text-sm font-medium text-neutral-700 mb-1">Age Restriction</label>
                <select id="age_restriction" value={form.age_restriction} onChange={(e) => updateField('age_restriction', e.target.value)} className="input" disabled={submitting}>
                  {AGE_RESTRICTIONS.map(ar => <option key={ar.value} value={ar.value}>{ar.label}</option>)}
                </select>
              </div>}
            </div>
          </div>
        </section>

        {/* Event Link Section */}
        <section aria-labelledby="event-link-heading">
          <h2 id="event-link-heading" className="text-lg font-semibold text-neutral-900 mb-4 pb-2 border-b border-neutral-200">Event Link</h2>
          <label htmlFor="slug" className="block text-sm font-medium text-neutral-700 mb-1">Link name</label>
          <input
            id="slug"
            type="text"
            inputMode="url"
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            maxLength={80}
            value={form.slug}
            onChange={(e) => updateField('slug', normalizeEventLinkInput(e.target.value))}
            aria-invalid={Boolean(linkError)}
            aria-describedby={`slug-preview${linkError ? ' slug-error' : ''} slug-help`}
            className={`input ${linkError ? 'input-error' : ''}`}
            placeholder="e.g., full-moon-beach-party"
            disabled={submitting}
          />
          <p id="slug-preview" className="mt-2 flex min-w-0 items-start gap-2 text-sm text-neutral-700">
            <Link2 aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-neutral-400" />
            <span className="min-w-0 break-all"><span className="sr-only">Full link: </span>{eventLinkUrl(linkSlug || event?.slug || '')}</span>
          </p>
          <div aria-live="polite">
            {linkError ? <p id="slug-error" className="mt-1 text-sm text-red-600">{linkError}</p>
              : linkChanged && currentLinkCheck?.status === 'checking' ? <p className="mt-1 text-sm text-neutral-500">Checking this link…</p>
              : linkChanged && currentLinkCheck?.status === 'available' ? <p className="mt-1 text-sm text-emerald-700">This link is available.</p>
              : linkChanged && currentLinkCheck?.status === 'unknown' ? <p className="mt-1 text-sm text-neutral-500">We couldn’t check this link yet. It will be checked when you save.</p>
              : null}
          </div>
          <p id="slug-help" className="mt-1 text-xs text-neutral-500">
            Lowercase letters, numbers, and hyphens. {event?.slug_follows_title
              ? 'Until you publish or change it, the link updates to match the title when you save.'
              : 'Renaming the event keeps this link.'}
          </p>
          {linkChanged && event?.ever_published && (
            <p role="status" className="mt-3 flex gap-2 rounded-xl border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
              <AlertTriangle aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" />
              <span className="min-w-0">This event is already public. After you save, the old link (<span className="break-all">{eventLinkUrl(event.slug)}</span>) keeps working and sends people to the new one. Update the link anywhere you can, like posters and social posts.</span>
            </p>
          )}
        </section>

        {canManage && <>
        {/* Venue Section */}
        <section>
          <h2 className="text-lg font-semibold text-neutral-900 mb-4 pb-2 border-b border-neutral-200">Venue</h2>
          <div className="space-y-4">
            <div>
              <label htmlFor="venue_name" className="block text-sm font-medium text-neutral-700 mb-1">
                Venue Name <span className="text-red-500">*</span>
              </label>
              <input id="venue_name" aria-invalid={Boolean(formErrors.venue_name)} aria-describedby={formErrors.venue_name ? 'venue_name-error' : undefined} required type="text" value={form.venue_name} onChange={(e) => updateField('venue_name', e.target.value)} className={`input ${formErrors.venue_name ? 'input-error' : ''}`} placeholder="e.g., Tumon Beach Club" disabled={submitting} />
              {formErrors.venue_name && <p id="venue_name-error" className="mt-1 text-sm text-red-600">{formErrors.venue_name}</p>}
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
          <p className="text-sm text-neutral-500 mb-4">All event times are entered and displayed in Guam time (Pacific/Guam).</p>
          <div className="space-y-4">
            <div>
              <label htmlFor="starts_at" className="block text-sm font-medium text-neutral-700 mb-1">
                Start Date & Time <span className="text-red-500">*</span>
              </label>
              <input id="starts_at" aria-invalid={Boolean(formErrors.starts_at)} aria-describedby={formErrors.starts_at ? 'starts_at-error' : undefined} required type="datetime-local" value={form.starts_at} onChange={(e) => updateField('starts_at', e.target.value)} className={`input ${formErrors.starts_at ? 'input-error' : ''}`} disabled={submitting} />
              {formErrors.starts_at && <p id="starts_at-error" className="mt-1 text-sm text-red-600">{formErrors.starts_at}</p>}
            </div>
            <div>
              <label htmlFor="ends_at" className="block text-sm font-medium text-neutral-700 mb-1">End Date & Time</label>
              <input id="ends_at" aria-invalid={Boolean(formErrors.ends_at)} aria-describedby={formErrors.ends_at ? 'ends_at-error' : undefined} type="datetime-local" value={form.ends_at} onChange={(e) => updateField('ends_at', e.target.value)} className={`input ${formErrors.ends_at ? 'input-error' : ''}`} disabled={submitting} />
              {formErrors.ends_at && <p id="ends_at-error" className="mt-1 text-sm text-red-600">{formErrors.ends_at}</p>}
            </div>
            <div>
              <label htmlFor="doors_open_at" className="block text-sm font-medium text-neutral-700 mb-1">Doors Open At</label>
              <input id="doors_open_at" aria-invalid={Boolean(formErrors.doors_open_at)} aria-describedby={formErrors.doors_open_at ? 'doors_open_at-error' : undefined} type="datetime-local" value={form.doors_open_at} onChange={(e) => updateField('doors_open_at', e.target.value)} className={`input ${formErrors.doors_open_at ? 'input-error' : ''}`} disabled={submitting} />
              {formErrors.doors_open_at && <p id="doors_open_at-error" className="mt-1 text-sm text-red-600">{formErrors.doors_open_at}</p>}
            </div>
            {scheduleChanged && ['published', 'postponed'].includes(event?.status) && (
              <div className="rounded-xl border border-amber-200 bg-amber-50 p-4">
                <label htmlFor="change_reason" className="block text-sm font-semibold text-amber-950">Reason for schedule change <span className="text-red-500">*</span></label>
                <p className="mb-2 mt-1 text-xs text-amber-800">Ticket holders will see this explanation and can keep their tickets or request a refund.</p>
                <textarea id="change_reason" aria-invalid={Boolean(formErrors.change_reason)} aria-describedby={formErrors.change_reason ? 'change_reason-error' : undefined} rows="3" value={changeReason} onChange={(e) => { setChangeReason(e.target.value); setFormErrors(prev => ({ ...prev, change_reason: null })) }} className={`input ${formErrors.change_reason ? 'input-error' : ''}`} placeholder="Explain what changed and why" disabled={submitting} />
                {formErrors.change_reason && <p id="change_reason-error" className="mt-1 text-sm text-red-600">{formErrors.change_reason}</p>}
              </div>
            )}
          </div>
        </section>

        {/* Settings Section */}
        <section>
          <h2 className="text-lg font-semibold text-neutral-900 mb-4 pb-2 border-b border-neutral-200">Settings</h2>
          <div className="space-y-4">
            <div>
              <label htmlFor="max_capacity" className="block text-sm font-medium text-neutral-700 mb-1">Max Capacity</label>
              <input id="max_capacity" aria-invalid={Boolean(formErrors.max_capacity)} aria-describedby={formErrors.max_capacity ? 'max_capacity-error' : undefined} type="number" min="1" value={form.max_capacity} onChange={(e) => updateField('max_capacity', e.target.value)} className={`input ${formErrors.max_capacity ? 'input-error' : ''}`} placeholder="Leave blank for unlimited" disabled={submitting} />
              {formErrors.max_capacity && <p id="max_capacity-error" className="mt-1 text-sm text-red-600">{formErrors.max_capacity}</p>}
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
        <section hidden={!capabilities.recurring_events}>
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
                    if (generatingRecurrences) return
                    const request = beginRequest()
                    if (!request) return
                    setGeneratingRecurrences(true)
                    setSubmitError(null)
                    try {
                      const res = await apiClient.post(`/organizer/events/${id}/generate_recurrences`, { count: recurrenceCount }, request.config)
                      if (!request.current()) return
                      setSuccessMessage(`Generated ${res.data.generated_count} recurring event(s).`)
                      setRecurrenceChildren(res.data.events || [])
                    } catch (err) {
                      if (!request.current()) return
                      setSubmitError(err.response?.data?.error || 'Failed to generate recurring events')
                    } finally {
                      request.release()
                      if (request.current()) setGeneratingRecurrences(false)
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
                    <Link to={`/dashboard/events/${event.recurrence_parent_id}/edit`} className="block text-sm text-action-teal hover:text-action-teal-hover">
                      ← View Parent Event
                    </Link>
                  )}
                  {recurrenceChildren.map(child => (
                    <Link key={child.id} to={`/dashboard/events/${child.id}/edit`} className="block p-2 rounded-lg bg-neutral-50 hover:bg-neutral-100 text-sm text-neutral-700 transition-colors">
                      {child.title} — {child.starts_at ? formatEventDate(child.starts_at, child.timezone) : 'No date set'}
                    </Link>
                  ))}
                </div>
              </div>
            )}
          </div>
        </section>

        </>}

        {/* Event-details save bar: sticks to the viewport bottom while the long
            form scrolls and stops at the form's end, above independently saved
            ticket types. */}
        <div data-testid="event-details-save-bar" className="sticky bottom-0 z-20 rounded-t-xl border border-b-0 border-neutral-200 bg-white px-4 pt-3 pb-[max(0.75rem,env(safe-area-inset-bottom))] shadow-[0_-4px_12px_rgba(0,0,0,0.06)] sm:px-5">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <p id="event-details-save-state" className={`text-sm ${hasUnsavedChanges ? 'font-medium text-amber-800' : 'text-neutral-500'}`} aria-live="polite">
              {submitting ? 'Saving event details…' : hasUnsavedChanges ? 'Unsaved event detail changes' : 'Event details are saved'}
            </p>
            <button type="submit" disabled={submitting} aria-describedby="event-details-save-state" className="btn-primary w-full sm:w-auto">
              {submitting ? 'Saving...' : 'Save Changes'}
            </button>
          </div>
        </div>
      </form>

      {/* Fee policy sits next to pricing so every organizer who can edit the
          event can choose it, whatever the launch scope. */}
      {event && <FeePolicyPanel eventId={id} event={event} canEdit={permissions.edit_event_content === true && permissions.manage_events === true}
        beginRequest={beginRequest} onDirtyChange={setFeeChoiceDirty}
        onSaved={saved => setEvent(currentEvent => ({ ...currentEvent, fee_policy: saved.fee_policy, buyer_fee_percent: saved.buyer_fee_percent }))} />}

      {/* Ticket Types CRUD */}
      {permissions.manage_inventory && <section id="ticket-types" tabIndex={-1} aria-label="Ticket types" className="mt-10 scroll-mt-24 border-t border-neutral-200 pt-6 focus-visible:outline focus-visible:outline-2 focus-visible:outline-focus" aria-busy={inventoryRefreshing}>
        <p className="rounded-xl bg-neutral-50 px-4 py-3 text-sm text-neutral-600"><span className="font-semibold text-neutral-800">Saved separately.</span> Ticket type changes save as soon as you add, edit or remove one. They are not part of Save Changes above.</p>
        {inventoryRefreshing && <p role="status" className="mt-6 text-sm text-neutral-600">Updating ticket list…</p>}
        {inventoryError && <div role="alert" className="mt-6 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">
          <p>{inventoryError}</p>
          <button type="button" onClick={refreshInventory} className="mt-2 min-h-11 font-semibold underline underline-offset-2">Retry ticket list</button>
        </div>}
        <TicketTypeCRUD beginRequest={beginRequest} remainingCapacity={remainingTicketCapacity} eventId={id} ticketTypes={event?.ticket_types || []} onRefresh={refreshInventory} eventTimezone={event?.timezone} />
      </section>}

      {/* Danger Zone — HP-28 */}
      {canManage && event && event.status !== 'archived' && (
        <div className="mt-8 border border-neutral-200 rounded-xl p-5 sm:p-6">
          <h2 className="text-lg font-semibold text-red-700 mb-1 flex items-center gap-2">
            <AlertTriangle className="w-5 h-5" /> Event actions
          </h2>
          <p className="text-sm text-neutral-500 mb-4">These actions affect sales and public visibility and are recorded in event history.</p>
          <div className="space-y-3">
            {(event.status === 'published' || event.status === 'postponed') && (
              <div className="flex items-center justify-between p-3 bg-red-50 rounded-xl">
                <div>
                  <p className="text-sm font-medium text-neutral-900">Cancel Event</p>
                  <p className="text-xs text-neutral-500">Stop sales and remove the event from public discovery.</p>
                </div>
                <button onClick={() => setShowCancelConfirm(true)} className="px-3 py-1.5 text-sm font-medium text-red-600 border border-red-300 rounded-lg hover:bg-red-100 transition-colors flex items-center gap-1.5">
                  <XCircle className="w-4 h-4" /> Cancel Event
                </button>
              </div>
            )}
            {event.status === 'published' && (
              <div className="flex items-center justify-between p-3 bg-orange-50 rounded-xl">
                <div>
                  <p className="text-sm font-medium text-neutral-900">Postpone Event</p>
                  <p className="text-xs text-neutral-500">Pause sales while a new date is arranged.</p>
                </div>
                <button onClick={() => setShowPostponeConfirm(true)} className="px-3 py-1.5 text-sm font-medium text-orange-700 border border-orange-300 rounded-lg hover:bg-orange-100 transition-colors flex items-center gap-1.5">
                  <PauseCircle className="w-4 h-4" /> Postpone
                </button>
              </div>
            )}
            {event.status === 'postponed' && (
              <div className="flex items-center justify-between p-3 bg-brand-50 rounded-xl">
                <div>
                  <p className="text-sm font-medium text-neutral-900">Resume Event</p>
                  <p className="text-xs text-neutral-500">Restore public visibility and ticket sales using the updated schedule.</p>
                </div>
                <button onClick={() => handleLifecycle('resume', 'Event resumed and ticket sales restored.')} className="btn-primary text-sm px-3 py-1.5">Resume</button>
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
            {['draft', 'cancelled', 'completed'].includes(event.status) && (
              <div className="flex items-center justify-between p-3 bg-neutral-50 rounded-xl">
                <div>
                  <p className="text-sm font-medium text-neutral-900">Archive Event</p>
                  <p className="text-xs text-neutral-500">Keep its record while removing it from active work.</p>
                </div>
                <button onClick={() => handleLifecycle('archive', 'Event archived.')} className="px-3 py-1.5 text-sm font-medium text-neutral-700 border border-neutral-300 rounded-lg hover:bg-neutral-100 transition-colors flex items-center gap-1.5">
                  <Archive className="w-4 h-4" /> Archive
                </button>
              </div>
            )}
          </div>
        </div>
      )}
    </div></EventWorkspace>
  )
}

export default function EditEventPage() {
  const { id } = useParams()
  const identity = useOrganizerIdentity()
  const visit = useOrganizerPageVisit(`/dashboard/events/${id}/edit`)
  if (!visit.active) return null
  if (!identity.ready) return <div className="grid min-h-screen place-items-center" role="status">Preparing your account…</div>
  return <EditEventSession key={`${identity.accountKey}:${identity.organizationId}:${id}:${visit.generation}`} id={id} identity={identity} />
}
