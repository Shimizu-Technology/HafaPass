import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { Archive, Calendar, Copy, Layers, Pencil, Plus, Trash2, X } from 'lucide-react'
import apiClient from '../../api/client'
import Dialog from '../../components/Dialog'
import NoAccessNotice from '../../components/NoAccessNotice'
import PageLoading from '../../components/PageLoading'
import { BackLink, PageHeader, WorkspacePage } from '../../components/WorkspacePage'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import { formatEventDate } from '../../utils/eventTime'
import { loadOrganizerOrganizations, selectedOrganization } from '../../utils/organizerOrganizations'

const SERIES_STATUSES = [
  { value: 'draft', label: 'Draft' },
  { value: 'active', label: 'Active' },
  { value: 'completed', label: 'Completed' },
  { value: 'archived', label: 'Archived' },
]

const SERIES_ROLES = [
  { value: 'regular_night', label: 'Regular Nights' },
  { value: 'championship_night', label: 'Championship Nights' },
  { value: 'pass_sale', label: 'Pass Sales' },
  { value: 'registration', label: 'Registration' },
  { value: 'other', label: 'Other' },
]

const STATUS_STYLES = {
  draft: 'bg-amber-100 text-amber-900',
  active: 'bg-emerald-100 text-emerald-900',
  completed: 'bg-neutral-100 text-neutral-800',
  archived: 'bg-neutral-200 text-neutral-700',
}

const MAX_BULK_OCCURRENCES = 25

function StatusBadge({ status }) {
  return (
    <span className={`inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium ${STATUS_STYLES[status] || 'bg-neutral-100 text-neutral-800'}`}>
      {status ? status.charAt(0).toUpperCase() + status.slice(1) : 'Draft'}
    </span>
  )
}

function SeriesFormDialog({ series, onClose, onSaved, beginRequest }) {
  const titleId = useId()
  const nameRef = useRef(null)
  const [name, setName] = useState(series?.name || '')
  const [slug, setSlug] = useState(series?.slug || '')
  const [description, setDescription] = useState(series?.description || '')
  const [status, setStatus] = useState(series?.status || 'draft')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState(null)

  const handleSubmit = async (e) => {
    e.preventDefault()
    if (!name.trim()) {
      setError('Series name is required.')
      return
    }
    const request = beginRequest()
    if (!request) return
    setSaving(true)
    setError(null)
    try {
      const payload = {
        name: name.trim(),
        description: description.trim(),
        status,
        ...(slug.trim() ? { slug: slug.trim() } : {}),
      }
      const res = series
        ? await apiClient.patch(`/organizer/event_series/${series.id}`, payload, request.config)
        : await apiClient.post('/organizer/event_series', payload, request.config)
      if (!request.current()) return
      onSaved(res.data)
    } catch (err) {
      if (!request.current()) return
      const msg = err.response?.data?.errors?.[0] || err.response?.data?.error || 'Could not save event series.'
      setError(msg)
    } finally {
      request.release()
      if (request.current()) setSaving(false)
    }
  }

  return (
    <Dialog labelledBy={titleId} onClose={onClose} busy={saving} initialFocusRef={nameRef} className="max-w-lg">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 id={titleId} className="text-xl font-bold text-neutral-950">
            {series ? 'Edit event series' : 'New event series'}
          </h2>
          <p className="mt-1 text-sm text-neutral-600">
            Group multi-night tournaments, festivals, or pass sales under one series.
          </p>
        </div>
        <button
          type="button"
          onClick={onClose}
          disabled={saving}
          aria-label="Close dialog"
          className="inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-lg text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900"
        >
          <X className="h-5 w-5" />
        </button>
      </div>

      {error && (
        <div role="alert" className="mt-4 rounded-xl border border-red-200 bg-red-50 px-3.5 py-2.5 text-sm text-red-800">
          {error}
        </div>
      )}

      <form onSubmit={handleSubmit} className="mt-5 space-y-4">
        <div>
          <label htmlFor="series-name" className="mb-1 block text-sm font-medium text-neutral-800">
            Series name <span className="text-red-600">*</span>
          </label>
          <input
            ref={nameRef}
            id="series-name"
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="e.g. FD Alumni Basketball Tournament 2026"
            className="input"
            disabled={saving}
            required
          />
        </div>

        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div>
            <label htmlFor="series-slug" className="mb-1 block text-sm font-medium text-neutral-800">
              URL slug
            </label>
            <input
              id="series-slug"
              type="text"
              value={slug}
              onChange={(e) => setSlug(e.target.value)}
              placeholder="Auto-generated if blank"
              className="input font-mono text-sm"
              disabled={saving}
            />
          </div>

          <div>
            <label htmlFor="series-status" className="mb-1 block text-sm font-medium text-neutral-800">
              Status
            </label>
            <select
              id="series-status"
              value={status}
              onChange={(e) => setStatus(e.target.value)}
              className="input"
              disabled={saving}
            >
              {SERIES_STATUSES.map((opt) => (
                <option key={opt.value} value={opt.value}>{opt.label}</option>
              ))}
            </select>
          </div>
        </div>

        <div>
          <label htmlFor="series-description" className="mb-1 block text-sm font-medium text-neutral-800">
            Description
          </label>
          <textarea
            id="series-description"
            rows={3}
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            placeholder="Notes about this tournament or multi-night series..."
            className="input"
            disabled={saving}
          />
        </div>

        <div className="flex flex-wrap justify-end gap-2 pt-2">
          <button type="button" onClick={onClose} disabled={saving} className="btn-secondary min-h-11 px-4 text-sm">
            Cancel
          </button>
          <button type="submit" disabled={saving} className="btn-primary min-h-11 px-5 text-sm">
            {saving ? 'Saving…' : series ? 'Save changes' : 'Create series'}
          </button>
        </div>
      </form>
    </Dialog>
  )
}

function BulkCloneDialog({ series, allEvents, onClose, onCloned, beginRequest }) {
  const titleId = useId()
  const templateRef = useRef(null)
  const defaultTemplateId = useMemo(() => {
    const memberEventId = series.events?.[0]?.event_id
    if (memberEventId) return String(memberEventId)
    return allEvents[0] ? String(allEvents[0].id) : ''
  }, [series, allEvents])

  const [templateEventId, setTemplateEventId] = useState(defaultTemplateId)
  const [seriesRole, setSeriesRole] = useState('regular_night')
  const [rows, setRows] = useState([
    { title: '', starts_at: '', ends_at: '', doors_open_at: '' },
  ])
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState(null)

  const updateRow = (index, field, value) => {
    setRows((prev) => prev.map((row, idx) => (idx === index ? { ...row, [field]: value } : row)))
  }

  const addRow = () => {
    if (rows.length >= MAX_BULK_OCCURRENCES) return
    setRows((prev) => [...prev, { title: '', starts_at: '', ends_at: '', doors_open_at: '' }])
  }

  const removeRow = (index) => {
    if (rows.length <= 1) return
    setRows((prev) => prev.filter((_, idx) => idx !== index))
  }

  const handleSubmit = async (e) => {
    e.preventDefault()
    if (!templateEventId) {
      setError('Select a template event to clone from.')
      return
    }
    const invalidIndex = rows.findIndex((row) => !row.title.trim() || !row.starts_at || !row.ends_at)
    if (invalidIndex !== -1) {
      setError(`Night ${invalidIndex + 1} needs a title, start time, and end time.`)
      return
    }
    const request = beginRequest()
    if (!request) return
    setSubmitting(true)
    setError(null)
    try {
      const occurrences = rows.map((row) => ({
        title: row.title.trim(),
        starts_at: row.starts_at,
        ends_at: row.ends_at,
        ...(row.doors_open_at ? { doors_open_at: row.doors_open_at } : {}),
      }))
      const res = await apiClient.post(
        `/organizer/events/${templateEventId}/bulk_clone`,
        {
          event_series_id: series.id,
          series_role: seriesRole,
          occurrences,
        },
        request.config
      )
      if (!request.current()) return
      onCloned(res.data)
    } catch (err) {
      if (!request.current()) return
      const msg = err.response?.data?.errors?.[0] || err.response?.data?.error || 'Could not bulk clone nights.'
      setError(msg)
    } finally {
      request.release()
      if (request.current()) setSubmitting(false)
    }
  }

  return (
    <Dialog labelledBy={titleId} onClose={onClose} busy={submitting} initialFocusRef={templateRef} className="max-w-2xl">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 id={titleId} className="text-xl font-bold text-neutral-950">
            Bulk clone nights
          </h2>
          <p className="mt-1 text-sm text-neutral-600">
            Clone a template event into up to {MAX_BULK_OCCURRENCES} draft nights and attach them to{' '}
            <span className="font-medium text-neutral-900">{series.name}</span>.
          </p>
        </div>
        <button
          type="button"
          onClick={onClose}
          disabled={submitting}
          aria-label="Close dialog"
          className="inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-lg text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900"
        >
          <X className="h-5 w-5" />
        </button>
      </div>

      {error && (
        <div role="alert" className="mt-4 rounded-xl border border-red-200 bg-red-50 px-3.5 py-2.5 text-sm text-red-800">
          {error}
        </div>
      )}

      <form onSubmit={handleSubmit} className="mt-5 space-y-5">
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div>
            <label htmlFor="bulk-template-event" className="mb-1 block text-sm font-medium text-neutral-800">
              Template event <span className="text-red-600">*</span>
            </label>
            <select
              ref={templateRef}
              id="bulk-template-event"
              value={templateEventId}
              onChange={(e) => setTemplateEventId(e.target.value)}
              className="input"
              disabled={submitting}
              required
            >
              <option value="">Choose an event…</option>
              {allEvents.map((ev) => (
                <option key={ev.id} value={ev.id}>{ev.title}</option>
              ))}
            </select>
          </div>

          <div>
            <label htmlFor="bulk-series-role" className="mb-1 block text-sm font-medium text-neutral-800">
              Series role
            </label>
            <select
              id="bulk-series-role"
              value={seriesRole}
              onChange={(e) => setSeriesRole(e.target.value)}
              className="input"
              disabled={submitting}
            >
              {SERIES_ROLES.map((opt) => (
                <option key={opt.value} value={opt.value}>{opt.label}</option>
              ))}
            </select>
          </div>
        </div>

        <div className="space-y-3">
          <div className="flex items-center justify-between">
            <h3 className="text-sm font-semibold text-neutral-900">
              Occurrences ({rows.length}/{MAX_BULK_OCCURRENCES})
            </h3>
            <button
              type="button"
              onClick={addRow}
              disabled={submitting || rows.length >= MAX_BULK_OCCURRENCES}
              className="inline-flex min-h-10 items-center gap-1.5 rounded-lg border border-neutral-200 bg-white px-3 text-sm font-medium text-neutral-700 hover:bg-neutral-50 disabled:opacity-50"
            >
              <Plus className="h-4 w-4" />
              Add night
            </button>
          </div>

          <div className="space-y-3">
            {rows.map((row, index) => (
              <div key={index} className="rounded-xl border border-neutral-200 bg-neutral-50/70 p-3.5">
                <div className="mb-2.5 flex items-center justify-between">
                  <span className="text-xs font-semibold uppercase tracking-wide text-neutral-500">
                    Night {index + 1}
                  </span>
                  {rows.length > 1 && (
                    <button
                      type="button"
                      onClick={() => removeRow(index)}
                      disabled={submitting}
                      className="text-xs font-medium text-red-700 hover:underline"
                    >
                      Remove
                    </button>
                  )}
                </div>

                <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                  <div className="sm:col-span-2">
                    <label htmlFor={`occ-title-${index}`} className="mb-1 block text-xs font-medium text-neutral-700">
                      Title <span className="text-red-600">*</span>
                    </label>
                    <input
                      id={`occ-title-${index}`}
                      type="text"
                      value={row.title}
                      onChange={(e) => updateRow(index, 'title', e.target.value)}
                      placeholder={`e.g. Night ${index + 1} - Pool Play`}
                      className="input"
                      disabled={submitting}
                      required
                    />
                  </div>
                  <div>
                    <label htmlFor={`occ-start-${index}`} className="mb-1 block text-xs font-medium text-neutral-700">
                      Starts at <span className="text-red-600">*</span>
                    </label>
                    <input
                      id={`occ-start-${index}`}
                      type="datetime-local"
                      value={row.starts_at}
                      onChange={(e) => updateRow(index, 'starts_at', e.target.value)}
                      className="input"
                      disabled={submitting}
                      required
                    />
                  </div>
                  <div>
                    <label htmlFor={`occ-end-${index}`} className="mb-1 block text-xs font-medium text-neutral-700">
                      Ends at <span className="text-red-600">*</span>
                    </label>
                    <input
                      id={`occ-end-${index}`}
                      type="datetime-local"
                      value={row.ends_at}
                      onChange={(e) => updateRow(index, 'ends_at', e.target.value)}
                      className="input"
                      disabled={submitting}
                      required
                    />
                  </div>
                  <div className="sm:col-span-2">
                    <label htmlFor={`occ-doors-${index}`} className="mb-1 block text-xs font-medium text-neutral-700">
                      Doors open at (optional)
                    </label>
                    <input
                      id={`occ-doors-${index}`}
                      type="datetime-local"
                      value={row.doors_open_at}
                      onChange={(e) => updateRow(index, 'doors_open_at', e.target.value)}
                      className="input"
                      disabled={submitting}
                    />
                  </div>
                </div>
              </div>
            ))}
          </div>
        </div>

        <div className="flex flex-wrap justify-end gap-2 pt-2">
          <button type="button" onClick={onClose} disabled={submitting} className="btn-secondary min-h-11 px-4 text-sm">
            Cancel
          </button>
          <button type="submit" disabled={submitting || !allEvents.length} className="btn-primary min-h-11 px-5 text-sm">
            {submitting ? 'Cloning nights…' : `Create ${rows.length} ${rows.length === 1 ? 'night' : 'nights'}`}
          </button>
        </div>
      </form>
    </Dialog>
  )
}

export default function EventSeriesPage() {
  const identity = useOrganizerIdentity()
  const { authContext, organizationId, ready } = identity
  const { active } = useOrganizerPageVisit('/dashboard/series')
  const { beginRequest } = useOrganizerRequests(identity, '/dashboard/series')

  const [loading, setLoading] = useState(true)
  const [organization, setOrganization] = useState(null)
  const [seriesList, setSeriesList] = useState([])
  const [orgEvents, setOrgEvents] = useState([])
  const [selectedSeriesId, setSelectedSeriesId] = useState(null)
  const [error, setError] = useState(null)
  const [notice, setNotice] = useState(null)

  const [showSeriesDialog, setShowSeriesDialog] = useState(false)
  const [editingSeries, setEditingSeries] = useState(null)
  const [showBulkCloneDialog, setShowBulkCloneDialog] = useState(false)

  const [addEventId, setAddEventId] = useState('')
  const [addEventRole, setAddEventRole] = useState('regular_night')
  const [mutating, setMutating] = useState(false)

  const loadData = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    setLoading(true)
    setError(null)
    try {
      const orgRes = await loadOrganizerOrganizations(authContext)
      if (!request.current()) return
      const orgs = Array.isArray(orgRes.data) ? orgRes.data : []
      const currentOrg = selectedOrganization(orgs, organizationId)
      setOrganization(currentOrg)

      const canView = Boolean(currentOrg?.permissions?.view_events || currentOrg?.permissions?.manage_events)
      if (!currentOrg || !canView) {
        setSeriesList([])
        setOrgEvents([])
        setLoading(false)
        return
      }

      const [seriesRes, eventsRes] = await Promise.all([
        apiClient.get('/organizer/event_series', request.config),
        apiClient.get('/organizer/events?per_page=100', request.config),
      ])
      if (!request.current()) return
      const loadedSeries = seriesRes.data?.event_series || []
      setSeriesList(loadedSeries)
      setOrgEvents(eventsRes.data?.events || [])
      setSelectedSeriesId((prev) => {
        if (prev && loadedSeries.some((item) => item.id === prev)) return prev
        return loadedSeries[0]?.id ?? null
      })
    } catch (err) {
      if (!request.current()) return
      setError(err.response?.data?.error || 'Could not load event series.')
    } finally {
      request.release()
      if (request.current()) setLoading(false)
    }
  }, [authContext, beginRequest, organizationId])

  useEffect(() => {
    if (!ready || !active) return
    loadData()
  }, [ready, active, loadData])

  const selectedSeries = useMemo(
    () => seriesList.find((item) => item.id === selectedSeriesId) || null,
    [seriesList, selectedSeriesId]
  )

  const canViewEvents = Boolean(organization?.permissions?.view_events || organization?.permissions?.manage_events)
  const canManageEvents = Boolean(organization?.permissions?.manage_events)

  const availableEventsToAdd = useMemo(() => {
    if (!selectedSeries) return []
    const memberIds = new Set((selectedSeries.events || []).map((ev) => ev.event_id))
    return orgEvents.filter((ev) => !memberIds.has(ev.id))
  }, [orgEvents, selectedSeries])

  const groupedEvents = useMemo(() => {
    if (!selectedSeries) return []
    const events = selectedSeries.events || []
    return SERIES_ROLES.map((roleDef) => ({
      ...roleDef,
      items: events.filter((ev) => ev.role === roleDef.value),
    })).filter((group) => group.items.length > 0)
  }, [selectedSeries])

  const replaceSeriesInList = (updated) => {
    setSeriesList((prev) => {
      const exists = prev.some((item) => item.id === updated.id)
      return exists ? prev.map((item) => (item.id === updated.id ? updated : item)) : [updated, ...prev]
    })
    setSelectedSeriesId(updated.id)
  }

  const handleArchiveSeries = async (series) => {
    const request = beginRequest()
    if (!request) return
    setMutating(true)
    setError(null)
    setNotice(null)
    try {
      const res = await apiClient.patch(`/organizer/event_series/${series.id}`, { status: 'archived' }, request.config)
      if (!request.current()) return
      replaceSeriesInList(res.data)
      setNotice(`Archived "${res.data.name}".`)
    } catch (err) {
      if (!request.current()) return
      setError(err.response?.data?.error || 'Could not archive event series.')
    } finally {
      request.release()
      if (request.current()) setMutating(false)
    }
  }

  const handleDeleteSeries = async (series) => {
    const request = beginRequest()
    if (!request) return
    setMutating(true)
    setError(null)
    setNotice(null)
    try {
      await apiClient.delete(`/organizer/event_series/${series.id}`, request.config)
      if (!request.current()) return
      setSeriesList((prev) => {
        const next = prev.filter((item) => item.id !== series.id)
        setSelectedSeriesId(next[0]?.id ?? null)
        return next
      })
      setNotice(`Deleted "${series.name}".`)
    } catch (err) {
      if (!request.current()) return
      setError(err.response?.data?.error || 'Could not delete event series.')
    } finally {
      request.release()
      if (request.current()) setMutating(false)
    }
  }

  const handleAddEvent = async (e) => {
    e.preventDefault()
    if (!selectedSeries || !addEventId) return
    const request = beginRequest()
    if (!request) return
    setMutating(true)
    setError(null)
    setNotice(null)
    try {
      const res = await apiClient.post(
        `/organizer/event_series/${selectedSeries.id}/events`,
        { event_id: Number(addEventId), role: addEventRole },
        request.config
      )
      if (!request.current()) return
      replaceSeriesInList(res.data)
      setAddEventId('')
      setNotice('Added event to series.')
    } catch (err) {
      if (!request.current()) return
      setError(err.response?.data?.errors?.[0] || err.response?.data?.error || 'Could not add event.')
    } finally {
      request.release()
      if (request.current()) setMutating(false)
    }
  }

  const handleChangeRole = async (eventId, nextRole) => {
    if (!selectedSeries) return
    const request = beginRequest()
    if (!request) return
    setMutating(true)
    setError(null)
    try {
      const res = await apiClient.patch(
        `/organizer/event_series/${selectedSeries.id}/events/${eventId}`,
        { role: nextRole },
        request.config
      )
      if (!request.current()) return
      replaceSeriesInList(res.data)
    } catch (err) {
      if (!request.current()) return
      setError(err.response?.data?.error || 'Could not update event role.')
    } finally {
      request.release()
      if (request.current()) setMutating(false)
    }
  }

  const handleRemoveEvent = async (eventId) => {
    if (!selectedSeries) return
    const request = beginRequest()
    if (!request) return
    setMutating(true)
    setError(null)
    setNotice(null)
    try {
      await apiClient.delete(`/organizer/event_series/${selectedSeries.id}/events/${eventId}`, request.config)
      if (!request.current()) return
      setSeriesList((prev) =>
        prev.map((item) => {
          if (item.id !== selectedSeries.id) return item
          const remaining = (item.events || []).filter((ev) => ev.event_id !== eventId)
          return { ...item, events: remaining, events_count: remaining.length }
        })
      )
      setNotice('Removed event from series.')
    } catch (err) {
      if (!request.current()) return
      setError(err.response?.data?.error || 'Could not remove event from series.')
    } finally {
      request.release()
      if (request.current()) setMutating(false)
    }
  }

  if (!ready || loading) {
    return (
      <WorkspacePage>
        <PageLoading label="Loading event series…" />
      </WorkspacePage>
    )
  }

  if (!canViewEvents) {
    return (
      <WorkspacePage>
        <PageHeader
          title="Event series"
          back={<BackLink />}
        />
        <NoAccessNotice
          title="You don’t have access to event series"
          detail="Viewing event series requires event access in this organization."
        />
      </WorkspacePage>
    )
  }

  return (
    <WorkspacePage>
      <PageHeader
        title="Event series"
        description="Organize multi-night tournaments, festivals, and pass sales, and clone nights in bulk."
        back={<BackLink />}
        actions={canManageEvents ? (
          <button
            type="button"
            onClick={() => { setEditingSeries(null); setShowSeriesDialog(true) }}
            className="btn-primary inline-flex min-h-11 items-center gap-2 px-4 text-sm"
          >
            <Plus className="h-4 w-4" />
            New series
          </button>
        ) : null}
      />

      {error && (
        <div role="alert" className="mb-6 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
          {error}
        </div>
      )}

      {notice && (
        <div role="status" className="mb-6 rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-900">
          {notice}
        </div>
      )}

      {seriesList.length === 0 ? (
        <section className="rounded-2xl border border-neutral-200 bg-white p-8 text-center">
          <Layers aria-hidden="true" className="mx-auto h-10 w-10 text-brand-600" />
          <h2 className="mt-3 text-lg font-semibold text-neutral-900">No event series yet</h2>
          <p className="mx-auto mt-1 max-w-md text-sm text-neutral-600">
            Create a series to group regular nights, championship nights, and season pass sales together.
          </p>
          {canManageEvents && (
            <button
              type="button"
              onClick={() => { setEditingSeries(null); setShowSeriesDialog(true) }}
              className="btn-primary mt-5 inline-flex min-h-11 items-center gap-2 px-5 text-sm"
            >
              <Plus className="h-4 w-4" />
              Create your first series
            </button>
          )}
        </section>
      ) : (
        <div className="grid grid-cols-1 gap-6 lg:grid-cols-12">
          {/* Left column: Series list */}
          <aside className="space-y-2.5 lg:col-span-4" aria-label="Event series list">
            {seriesList.map((series) => {
              const isSelected = series.id === selectedSeries?.id
              return (
                <button
                  key={series.id}
                  type="button"
                  onClick={() => setSelectedSeriesId(series.id)}
                  aria-current={isSelected ? 'true' : undefined}
                  className={`w-full rounded-xl border p-4 text-left transition-colors ${
                    isSelected
                      ? 'border-brand-500 bg-brand-50/50 ring-1 ring-brand-500'
                      : 'border-neutral-200 bg-white hover:border-brand-200 hover:bg-neutral-50'
                  }`}
                >
                  <div className="flex items-start justify-between gap-2">
                    <span className="break-words text-base font-semibold text-neutral-950">{series.name}</span>
                    <StatusBadge status={series.status} />
                  </div>
                  <p className="mt-1 font-mono text-xs text-neutral-500">/{series.slug}</p>
                  <p className="mt-2 text-xs font-medium text-neutral-600">
                    {series.events_count} {series.events_count === 1 ? 'event' : 'events'}
                  </p>
                </button>
              )
            })}
          </aside>

          {/* Right column: Selected series details */}
          {selectedSeries && (
            <section className="space-y-6 lg:col-span-8">
              <div className="rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6">
                <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <h2 className="break-words text-xl font-bold text-neutral-950">{selectedSeries.name}</h2>
                      <StatusBadge status={selectedSeries.status} />
                    </div>
                    <p className="mt-1 font-mono text-xs text-neutral-500">Slug: {selectedSeries.slug}</p>
                    {selectedSeries.description && (
                      <p className="mt-2 text-sm text-neutral-600">{selectedSeries.description}</p>
                    )}
                  </div>

                  {canManageEvents && (
                    <div className="flex flex-wrap items-center gap-2">
                      <button
                        type="button"
                        onClick={() => setShowBulkCloneDialog(true)}
                        disabled={mutating || orgEvents.length === 0}
                        className="btn-primary inline-flex min-h-10 items-center gap-1.5 px-3.5 text-sm"
                      >
                        <Copy className="h-4 w-4" />
                        Bulk clone nights
                      </button>
                      <button
                        type="button"
                        onClick={() => { setEditingSeries(selectedSeries); setShowSeriesDialog(true) }}
                        disabled={mutating}
                        className="btn-secondary inline-flex min-h-10 items-center gap-1.5 px-3 text-sm"
                      >
                        <Pencil className="h-4 w-4" />
                        Edit
                      </button>
                      {selectedSeries.status !== 'archived' && (
                        <button
                          type="button"
                          onClick={() => handleArchiveSeries(selectedSeries)}
                          disabled={mutating}
                          className="btn-secondary inline-flex min-h-10 items-center gap-1.5 px-3 text-sm"
                        >
                          <Archive className="h-4 w-4" />
                          Archive
                        </button>
                      )}
                      {selectedSeries.events_count === 0 && (
                        <button
                          type="button"
                          onClick={() => handleDeleteSeries(selectedSeries)}
                          disabled={mutating}
                          className="inline-flex min-h-10 items-center gap-1.5 rounded-lg border border-red-200 bg-white px-3 text-sm font-medium text-red-700 hover:bg-red-50 disabled:opacity-50"
                        >
                          <Trash2 className="h-4 w-4" />
                          Delete
                        </button>
                      )}
                    </div>
                  )}
                </div>

                {/* Add existing event to series */}
                {canManageEvents && (
                  <form onSubmit={handleAddEvent} className="mt-6 border-t border-neutral-200 pt-5">
                    <h3 className="text-sm font-semibold text-neutral-900">Add event to series</h3>
                    <div className="mt-2.5 grid grid-cols-1 gap-3 sm:grid-cols-12">
                      <div className="sm:col-span-6">
                        <label htmlFor="add-series-event" className="sr-only">Select event</label>
                        <select
                          id="add-series-event"
                          value={addEventId}
                          onChange={(e) => setAddEventId(e.target.value)}
                          className="input"
                          disabled={mutating || availableEventsToAdd.length === 0}
                        >
                          <option value="">
                            {availableEventsToAdd.length === 0 ? 'All organization events are already in this series' : 'Select an event…'}
                          </option>
                          {availableEventsToAdd.map((ev) => (
                            <option key={ev.id} value={ev.id}>{ev.title}</option>
                          ))}
                        </select>
                      </div>
                      <div className="sm:col-span-4">
                        <label htmlFor="add-series-role" className="sr-only">Role</label>
                        <select
                          id="add-series-role"
                          value={addEventRole}
                          onChange={(e) => setAddEventRole(e.target.value)}
                          className="input"
                          disabled={mutating}
                        >
                          {SERIES_ROLES.map((opt) => (
                            <option key={opt.value} value={opt.value}>{opt.label}</option>
                          ))}
                        </select>
                      </div>
                      <div className="sm:col-span-2">
                        <button
                          type="submit"
                          disabled={mutating || !addEventId}
                          className="btn-secondary min-h-11 w-full text-sm"
                        >
                          Add
                        </button>
                      </div>
                    </div>
                  </form>
                )}
              </div>

              {/* Member events grouped by role */}
              <div className="space-y-4">
                {groupedEvents.length === 0 ? (
                  <div className="rounded-2xl border border-dashed border-neutral-300 bg-white p-6 text-center text-sm text-neutral-600">
                    No events in this series yet. Add an existing event above or use <strong>Bulk clone nights</strong>.
                  </div>
                ) : (
                  groupedEvents.map((group) => (
                    <div key={group.value} className="rounded-2xl border border-neutral-200 bg-white p-5">
                      <div className="mb-3 flex items-center justify-between">
                        <h3 className="text-sm font-semibold uppercase tracking-wide text-neutral-700">
                          {group.label}
                        </h3>
                        <span className="text-xs font-medium text-neutral-500">
                          {group.items.length} {group.items.length === 1 ? 'event' : 'events'}
                        </span>
                      </div>
                      <ul className="divide-y divide-neutral-100">
                        {group.items.map((ev) => (
                          <li key={ev.event_id} className="flex flex-col gap-3 py-3 first:pt-0 last:pb-0 sm:flex-row sm:items-center sm:justify-between">
                            <div className="min-w-0 flex-1">
                              <Link
                                to={`/dashboard/events/${ev.event_id}`}
                                className="font-semibold text-neutral-950 hover:text-brand-700 hover:underline"
                              >
                                {ev.title}
                              </Link>
                              <div className="mt-0.5 flex flex-wrap items-center gap-2 text-xs text-neutral-500">
                                <span className="inline-flex items-center gap-1">
                                  <Calendar aria-hidden="true" className="h-3.5 w-3.5" />
                                  {ev.starts_at ? formatEventDate(ev.starts_at, ev.timezone) : 'Date TBD'}
                                </span>
                                {ev.venue_name && <span>· {ev.venue_name}</span>}
                                <StatusBadge status={ev.status} />
                              </div>
                            </div>

                            {canManageEvents && (
                              <div className="flex flex-wrap items-center gap-2">
                                <label htmlFor={`role-${ev.event_id}`} className="sr-only">
                                  Role for {ev.title}
                                </label>
                                <select
                                  id={`role-${ev.event_id}`}
                                  value={ev.role}
                                  onChange={(e) => handleChangeRole(ev.event_id, e.target.value)}
                                  disabled={mutating}
                                  className="rounded-lg border border-neutral-200 bg-white px-2.5 py-2 text-xs font-medium text-neutral-700"
                                >
                                  {SERIES_ROLES.map((opt) => (
                                    <option key={opt.value} value={opt.value}>{opt.label}</option>
                                  ))}
                                </select>
                                <button
                                  type="button"
                                  onClick={() => handleRemoveEvent(ev.event_id)}
                                  disabled={mutating}
                                  className="inline-flex min-h-10 items-center rounded-lg px-2.5 text-xs font-medium text-red-700 hover:bg-red-50 disabled:opacity-50"
                                >
                                  Remove
                                </button>
                              </div>
                            )}
                          </li>
                        ))}
                      </ul>
                    </div>
                  ))
                )}
              </div>
            </section>
          )}
        </div>
      )}

      {showSeriesDialog && (
        <SeriesFormDialog
          series={editingSeries}
          onClose={() => { setShowSeriesDialog(false); setEditingSeries(null) }}
          onSaved={(saved) => {
            replaceSeriesInList(saved)
            setShowSeriesDialog(false)
            setEditingSeries(null)
            setNotice(editingSeries ? `Updated "${saved.name}".` : `Created "${saved.name}".`)
          }}
          beginRequest={beginRequest}
        />
      )}

      {showBulkCloneDialog && selectedSeries && (
        <BulkCloneDialog
          series={selectedSeries}
          allEvents={orgEvents}
          onClose={() => setShowBulkCloneDialog(false)}
          onCloned={(data) => {
            setShowBulkCloneDialog(false)
            setNotice(`Created ${data.created_count} ${data.created_count === 1 ? 'night' : 'nights'} and added them to "${selectedSeries.name}".`)
            loadData()
          }}
          beginRequest={beginRequest}
        />
      )}
    </WorkspacePage>
  )
}
