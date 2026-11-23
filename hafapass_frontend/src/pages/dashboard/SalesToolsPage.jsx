import EventWorkspace from '../../components/EventWorkspace'
import { useCallback, useEffect, useRef, useState } from 'react'
import { useParams } from 'react-router-dom'
import { ChevronDown, ChevronUp, Download, Loader2, Pencil, Plus, Send, Trash2 } from 'lucide-react'
import apiClient from '../../api/client'
import EventAccessNotice from '../../components/EventAccessNotice'
import { useLaunchCapabilityState } from '../../hooks/useLaunchCapabilities'
import CapabilityCheckFailed from '../../components/CapabilityCheckFailed'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import { LANGUAGES } from '../../utils/locale'

const emptyCatalog = { name: '', kind: 'add_on', price: '', inventory: '' }
const emptyQuestion = { prompt: '', kind: 'short_text', required: false, options: '', help_text: '', scope: 'order', ticket_type_ids: [], min: '', max: '', integer: false, show_on_scanner: false }
const emptyQuestionEdit = emptyQuestion
const QUESTION_KIND_LABELS = { short_text: 'Short text', long_text: 'Long text', selection: 'Choose one', multi_select: 'Choose several', checkbox: 'Checkbox', number: 'Number', phone: 'Phone number', email: 'Email address' }
const OPTION_KINDS = ['selection', 'multi_select']
// Server-defined starter sets (RegistrationQuestionsController::TEMPLATES).
const QUESTION_TEMPLATES = [
  { key: 'fd_team_registration', title: 'FD Team Registration', description: 'Class Name, Graduation Year (1950–2035), Division and Team Captain Phone.' },
  { key: 'alumni_door_verification', title: 'Alumni Door Verification', description: "Asks each alumni ticket for the attendee's name and Graduation Year, marked for door staff.", needsTicketType: true },
  { key: 'merch_shirt_size', title: 'Merch / T-Shirt Size', description: 'Shirt Size: S, M, L, XL or 2XL.' },
]

function formFromQuestion(item) {
  return {
    prompt: item.prompt || '', kind: item.kind || 'short_text', required: Boolean(item.required),
    options: Array.isArray(item.options) ? item.options.join(', ') : '', help_text: item.help_text || '',
    scope: item.scope || 'order', ticket_type_ids: (item.ticket_type_ids || []).map(Number),
    min: item.validation_rules?.min ?? '', max: item.validation_rules?.max ?? '', integer: item.validation_rules?.integer === true,
    show_on_scanner: Boolean(item.show_on_scanner),
  }
}

function questionPayload(form) {
  const rules = form.kind === 'number' ? {
    ...Object.fromEntries([['min', form.min], ['max', form.max]].filter(([, value]) => value !== '' && value != null).map(([key, value]) => [key, Number(value)])),
    ...(form.integer ? { integer: true } : {}),
  } : {}
  return {
    prompt: form.prompt.trim(), kind: form.kind, required: form.required, help_text: form.help_text.trim() || null,
    scope: form.scope, ticket_type_ids: form.ticket_type_ids, show_on_scanner: form.show_on_scanner,
    options: OPTION_KINDS.includes(form.kind) ? form.options.split(',').map(value => value.trim()).filter(Boolean) : [],
    validation_rules: rules,
  }
}

// Plain controls shared by the add and edit question forms.
function QuestionControls({ form, onChange, ticketTypes, idPrefix, editing = false }) {
  const set = changes => onChange({ ...form, ...changes })
  const optionKind = OPTION_KINDS.includes(form.kind)
  const allTypes = form.ticket_type_ids.length === 0
  const toggleType = id => set({ ticket_type_ids: form.ticket_type_ids.includes(id) ? form.ticket_type_ids.filter(value => value !== id) : [...form.ticket_type_ids, id] })
  return <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
    <Field label={editing ? 'Edit question' : 'Question'} className="sm:col-span-2"><input className="input font-normal" placeholder="e.g. Graduation year" value={form.prompt} onChange={e => set({ prompt: e.target.value })} /></Field>
    <Field label={editing ? 'Edit answer type' : 'Answer type'}><select className="input font-normal" value={form.kind} onChange={e => set({ kind: e.target.value })}>{Object.entries(QUESTION_KIND_LABELS).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></Field>
    {(optionKind || !editing) && <Field label={editing ? 'Edit choices (comma separated)' : 'Choices (comma separated)'}><input className="input font-normal" placeholder="e.g. S, M, L" disabled={!optionKind} value={form.options} onChange={e => set({ options: e.target.value })} /></Field>}
    <Field label="Help text (optional)" className="sm:col-span-2"><input className="input font-normal" maxLength={250} placeholder="e.g. 4-digit year, for example 1998" value={form.help_text} onChange={e => set({ help_text: e.target.value })} /></Field>
    {form.kind === 'number' && <>
      <Field label="Lowest number allowed"><input className="input font-normal" type="number" inputMode="numeric" placeholder="e.g. 1950" value={form.min} onChange={e => set({ min: e.target.value })} /></Field>
      <Field label="Highest number allowed"><input className="input font-normal" type="number" inputMode="numeric" placeholder="e.g. 2035" value={form.max} onChange={e => set({ max: e.target.value })} /></Field>
      <label className="inline-flex min-h-11 items-center gap-2 text-sm text-neutral-700 sm:col-span-2"><input type="checkbox" checked={form.integer} onChange={e => set({ integer: e.target.checked })} /> Whole numbers only (for example a year)</label>
    </>}
    <fieldset className="min-w-0 sm:col-span-2"><legend className="text-sm font-medium text-neutral-700">Ask this question</legend>
      <div className="mt-1 flex flex-wrap gap-x-5">{[['order', 'Once per order'], ['ticket', 'For each ticket']].map(([value, label]) => <label key={value} className="inline-flex min-h-11 items-center gap-2 text-sm text-neutral-700"><input type="radio" name={`${idPrefix}-scope`} value={value} checked={form.scope === value} onChange={() => set({ scope: value })} />{label}</label>)}</div>
    </fieldset>
    <fieldset className="min-w-0 sm:col-span-2"><legend className="text-sm font-medium text-neutral-700">Which tickets?</legend>
      <div className="mt-1 flex flex-wrap gap-x-5">
        <label className="inline-flex min-h-11 items-center gap-2 text-sm text-neutral-700"><input type="checkbox" checked={allTypes} onChange={() => set({ ticket_type_ids: [] })} />All ticket types</label>
        {ticketTypes.map(type => <label key={type.id} className="inline-flex min-h-11 items-center gap-2 text-sm text-neutral-700"><input type="checkbox" checked={form.ticket_type_ids.includes(Number(type.id))} onChange={() => toggleType(Number(type.id))} />{type.name}</label>)}
      </div>
    </fieldset>
    <div className="flex flex-wrap gap-x-5 sm:col-span-2 lg:col-span-4">
      <label className="inline-flex min-h-11 items-center gap-2 text-sm text-neutral-700"><input type="checkbox" checked={form.required} onChange={e => set({ required: e.target.checked })} /> {editing ? 'Required' : 'Required question'}</label>
      <label className="inline-flex min-h-11 items-center gap-2 text-sm text-neutral-700"><input type="checkbox" checked={form.show_on_scanner} onChange={e => set({ show_on_scanner: e.target.checked })} /> Show on door scanner</label>
    </div>
  </div>
}

function questionScopeSummary(item, ticketTypes) {
  const names = (item.ticket_type_ids || []).map(id => ticketTypes.find(type => Number(type.id) === Number(id))?.name).filter(Boolean)
  return [item.scope === 'ticket' ? 'For each ticket' : 'Once per order', names.length ? names.join(', ') : 'All ticket types'].join(' · ')
}
const emptyWaiver = { title: '', version: '1.0', body: '', required: true }
const emptyPromoter = { name: '', email: '', code: '', commission: '10' }
const emptyCampaign = { name: '', subject: '', body: '', segment: 'all_attendees', ticket_type_id: '', scheduled_at: '' }

function Section({ title, description, children }) {
  return <section className="card p-5 sm:p-6"><h2 className="text-lg font-bold text-neutral-900">{title}</h2><p className="mb-5 mt-1 text-sm text-neutral-500">{description}</p>{children}</section>
}

// Every input keeps a visible label; placeholders only show example values.
function Field({ label, className = '', children }) {
  return <label className={`flex min-w-0 flex-col gap-1 text-sm font-medium text-neutral-700 ${className}`}>{label}{children}</label>
}

// Languages organizers can write their own wording for. CHamoru stays listed
// only for events that already use it (human translation is planned).
const CONTENT_LANGUAGES = LANGUAGES.filter(language => language.code !== 'en').map(({ code, englishName }) => ({ code, label: englishName }))
const LEGACY_CONTENT_LANGUAGES = [{ code: 'ch', label: 'CHamoru' }]
const TRANSLATION_STATUS = {
  translated: 'Automatic translations are up to date.',
  pending: 'Translating your latest changes. This usually takes under a minute.',
  failed: 'Automatic translation did not finish. Try again.',
  untranslated: 'Not translated yet.',
  unavailable: 'Automatic translation is paused for now, so buyers see your English text. It stays paused until translation credit is restored.',
}
const TRANSLATION_POLL_MS = 5000

const addButtonClass = 'btn-secondary min-h-11 gap-1.5 self-end whitespace-nowrap px-4 py-2.5 text-sm'

function SalesToolsSession({ eventId, identity }) {
  const { current, beginRequest } = useOrganizerRequests(identity, `/dashboard/events/${eventId}/sales-tools`)
  const { capabilities, status: capabilityStatus, retry: retryCapabilities } = useLaunchCapabilityState()
  const loadState = useRef({ generation: 0, request: null })
  const initialized = useRef(false)
  const busyRef = useRef(false)
  const storageKey = `hafapass:sales-tools-outcome:${identity.owner}:${identity.organizationId}:${eventId}`
  const [pending, setPending] = useState(() => { try { const raw = window.sessionStorage.getItem(storageKey); if (raw === null) return null; const value = JSON.parse(raw); return value && typeof value.label === 'string' ? value : { label: 'A previous sales change' } } catch { return { label: 'A previous sales change' } } })
  const pendingRef = useRef(pending)
  const [reviewed, setReviewed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const [notice, setNotice] = useState('')
  const [settings, setSettings] = useState(null)
  const [savedSettings, setSavedSettings] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [event, setEvent] = useState(null)
  const [catalog, setCatalog] = useState([])
  const [questions, setQuestions] = useState([])
  const [waivers, setWaivers] = useState([])
  const [promoters, setPromoters] = useState([])
  const [campaigns, setCampaigns] = useState([])
  const [segments, setSegments] = useState(null)
  const [catalogForm, setCatalogForm] = useState(emptyCatalog)
  const [questionForm, setQuestionForm] = useState(emptyQuestion)
  const [waiverForm, setWaiverForm] = useState(emptyWaiver)
  const [promoterForm, setPromoterForm] = useState(emptyPromoter)
  const [campaignForm, setCampaignForm] = useState(emptyCampaign)
  const [editingCampaignId, setEditingCampaignId] = useState(null)
  const [editingQuestionId, setEditingQuestionId] = useState(null)
  const [editQuestionForm, setEditQuestionForm] = useState(emptyQuestionEdit)
  const [templateTicketTypeId, setTemplateTicketTypeId] = useState('')
  const campaignNameInput = useRef(null)

  const advancedSalesEnabled = capabilities.advanced_sales_tools === true
  const permission = key => event?.permissions?.[key] === true
  const resourcePermissions = { catalog_items: 'manage_inventory', registration_questions: 'manage_events', event_waivers: 'manage_events', promoters: 'manage_marketing', communication_campaigns: 'manage_marketing' }
  const resourceAllowed = resource => {
    const hasPerm = permission(resourcePermissions[resource])
    if (resource === 'registration_questions' || resource === 'event_waivers') return hasPerm
    return advancedSalesEnabled && hasPerm
  }
  const clearPending = () => {
    try { window.sessionStorage.removeItem(storageKey); pendingRef.current = null; setPending(null); return true }
    catch { setError('The saved recovery record could not be cleared. Check browser storage before another change.'); return false }
  }
  const load = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    loadState.current.request?.controller.abort()
    loadState.current.request = request
    const generation = ++loadState.current.generation
    const canApply = () => request.current() && generation === loadState.current.generation
    if (!initialized.current) setLoading(true)
    setRefreshing(true); setError(null)
    if (pendingRef.current) setReviewed(false)
    try {
      const eventRes = await apiClient.get(`/organizer/events/${eventId}`, request.config)
      if (!canApply()) return
      const saved = eventRes.data
      if (String(saved.id) !== String(eventId) || (identity.organizationId != null && saved.organization_id != null && String(saved.organization_id) !== String(identity.organizationId))) throw new Error('Wrong event context')
      const adv = capabilities.advanced_sales_tools === true
      const resources = [
        ['catalog_items', adv && saved.permissions?.manage_inventory === true],
        ['registration_questions', saved.permissions?.manage_events === true],
        ['event_waivers', saved.permissions?.manage_events === true],
        ['promoters', adv && saved.permissions?.manage_marketing === true],
        ['communication_campaigns', adv && saved.permissions?.manage_marketing === true],
        ['crm/segments', adv && saved.permissions?.view_attendees === true],
      ]
      const responses = await Promise.all(resources.map(([path, canLoad]) => canLoad ? apiClient.get(`/organizer/events/${eventId}/${path}`, request.config) : Promise.resolve(null)))
      if (!canApply()) return
      setEvent(saved)
      setCatalog(responses[0]?.data.catalog_items || [])
      setQuestions(responses[1]?.data.registration_questions || [])
      setWaivers(responses[2]?.data.event_waivers || [])
      setPromoters(responses[3]?.data.promoters || [])
      setCampaigns(responses[4]?.data.communication_campaigns || [])
      setSegments(responses[5]?.data.segments || null)
      if (!initialized.current) {
        const initial = { supported_locales: saved.supported_locales || [], localized_content: saved.localized_content || {} }
        setSettings(initial); setSavedSettings(initial)
      }
      initialized.current = true
      setReviewed(Boolean(pendingRef.current))
    } catch (requestError) {
      if (!canApply()) return
      if ([401, 403, 404].includes(requestError.response?.status)) setEvent(null)
      setError(requestError.response?.data?.error || 'Unable to load sales tools. Your drafts are retained.')
    } finally {
      if (canApply()) { setLoading(false); setRefreshing(false) }
      request.release()
    }
  }, [eventId, beginRequest, identity.organizationId, capabilities.advanced_sales_tools])

  useEffect(() => { load() }, [load])

  const mutate = async (label, allowed, send, complete = () => {}) => {
    if (!allowed || !current() || busyRef.current || pendingRef.current) return
    const request = beginRequest()
    if (!request) return
    const record = { label, started_at: new Date().toISOString() }
    try { window.sessionStorage.setItem(storageKey, JSON.stringify(record)) }
    catch { setError('The recovery record could not be saved. Enable browser storage before making a change.'); request.release(); return }
    pendingRef.current = record; setPending(record); setReviewed(false)
    busyRef.current = true; setBusy(true); setError(null); setNotice('')
    try {
      const response = await send(request.config)
      if (!request.current()) return
      if (!clearPending()) return
      complete(response)
      setNotice(`${label} confirmed. Refreshing saved data.`)
      await load()
    } catch (requestError) {
      if (!request.current()) return
      const uncertain = !requestError.response || requestError.response.status >= 500 || [408, 409, 429].includes(requestError.response.status)
      if (!uncertain) clearPending()
      if ([401, 403, 404].includes(requestError.response?.status)) setEvent(null)
      setError(uncertain ? 'The response was not confirmed. Refresh saved data and verify the outcome before making another change.' : requestError.response?.data?.errors?.join(', ') || requestError.response?.data?.error || 'Unable to save. Your draft is retained.')
    } finally {
      if (request.current()) { busyRef.current = false; setBusy(false) }
      request.release()
    }
  }
  const create = (resource, payload, reset) => mutate('Save configuration', resourceAllowed(resource), config => apiClient.post(`/organizer/events/${eventId}/${resource}`, payload, config), reset)
  const remove = (resource, itemId) => {
    if (!current() || busyRef.current || pendingRef.current || !resourceAllowed(resource)) return
    if (!window.confirm('Remove this configuration? Existing historical records will remain protected.')) return
    return mutate('Remove configuration', true, config => apiClient.delete(`/organizer/events/${eventId}/${resource}/${itemId}`, config))
  }
  const startEditQuestion = item => {
    setEditingQuestionId(item.id)
    setEditQuestionForm(formFromQuestion(item))
  }
  const cancelEditQuestion = () => {
    setEditingQuestionId(null)
    setEditQuestionForm(emptyQuestionEdit)
  }
  const saveEditQuestion = item => {
    const payload = questionPayload(editQuestionForm)
    return mutate('Update question', permission('manage_events'), config => apiClient.patch(`/organizer/events/${eventId}/registration_questions/${item.id}`, payload, config), cancelEditQuestion)
  }
  const applyTemplate = template => {
    if (template.needsTicketType && !templateTicketTypeId) {
      setError('Choose the alumni ticket type in "Ask these questions for" first, so other tickets are not asked.')
      return
    }
    return mutate(`${template.title} template`, permission('manage_events'), config => apiClient.post(`/organizer/events/${eventId}/registration_questions/apply_template`,
      { template: template.key, ticket_type_id: templateTicketTypeId ? Number(templateTicketTypeId) : null }, config))
  }
  const toggleQuestionActive = item => {
    const nextActive = item.active === false
    return mutate(nextActive ? 'Resume question' : 'Pause question', permission('manage_events'), config => apiClient.patch(`/organizer/events/${eventId}/registration_questions/${item.id}`, { active: nextActive }, config))
  }
  const moveQuestion = (index, delta) => {
    const target = index + delta
    if (target < 0 || target >= questions.length) return
    const reordered = [...questions]
    ;[reordered[index], reordered[target]] = [reordered[target], reordered[index]]
    const updates = reordered
      .map((item, position) => ({ item, position }))
      .filter(({ item, position }) => item.position !== position || item.id === reordered[index].id || item.id === reordered[target].id)
    return mutate('Reorder questions', permission('manage_events'), config => Promise.all(
      updates.map(({ item, position }) => apiClient.patch(`/organizer/events/${eventId}/registration_questions/${item.id}`, { position }, config)),
    ))
  }
  const saveSettings = () => {
    return mutate('Sales settings', advancedSalesEnabled && permission('edit_event_content'), config => apiClient.put(`/organizer/events/${eventId}`, settings, config), () => setSavedSettings(settings))
  }
  const retranslate = () => mutate('Translation request', advancedSalesEnabled && permission('edit_event_content'), config => apiClient.post(`/organizer/events/${eventId}/retranslate`, undefined, config))
  const sendCampaign = item => mutate('Campaign submission', advancedSalesEnabled && permission('manage_marketing') && ['draft', 'scheduled'].includes(item.status), config => apiClient.post(`/organizer/events/${eventId}/communication_campaigns/${item.id}/send_now`, undefined, config))
  const reviewCampaign = item => {
    if (!current() || busyRef.current || pendingRef.current || !advancedSalesEnabled || !permission('manage_marketing')) return
    if (Object.keys(emptyCampaign).some(key => campaignForm[key] !== emptyCampaign[key]) &&
      !window.confirm('Replace the campaign form with this saved campaign? Unsaved campaign changes will be lost.')) return
    setEditingCampaignId(item.id)
    setCampaignForm({ name: item.name || '', subject: item.subject || '', body: item.body || '',
      segment: item.segment?.type || 'all_attendees', ticket_type_id: item.segment?.ticket_type_id || '', scheduled_at: '' })
    setNotice('Review the saved message and recipients below. Choose a new send time, or leave it blank to save a draft. Saving does not send email.')
    campaignNameInput.current?.focus()
    campaignNameInput.current?.scrollIntoView?.({ block: 'center', behavior: 'instant' })
  }
  const saveCampaign = () => {
    const payload = { name: campaignForm.name, subject: campaignForm.subject, body: campaignForm.body,
      segment: { type: campaignForm.segment, ...(campaignForm.segment === 'ticket_type' ? { ticket_type_id: campaignForm.ticket_type_id } : {}) },
      scheduled_at: campaignForm.scheduled_at || null }
    const reset = () => { setCampaignForm(emptyCampaign); setEditingCampaignId(null) }
    return editingCampaignId
      ? mutate('Campaign changes', advancedSalesEnabled && permission('manage_marketing'), config => apiClient.put(`/organizer/events/${eventId}/communication_campaigns/${editingCampaignId}`, payload, config), reset)
      : create('communication_campaigns', payload, reset)
  }
  const downloadExport = async () => {
    if (!permission('view_attendees') || busyRef.current || !current()) return
    const request = beginRequest()
    if (!request) return
    try {
      const response = await apiClient.get(`/organizer/events/${eventId}/crm/export`, { ...request.config, responseType: 'blob' })
      if (!request.current()) return
      const url = window.URL.createObjectURL(response.data)
      try { const link = document.createElement('a'); link.href = url; link.download = `${event.slug}-attendees.csv`; link.click() }
      finally { window.URL.revokeObjectURL(url) }
    } catch { if (request.current()) setError('Unable to export attendees. Try the export again when your connection is available.') }
    finally { request.release() }
  }
  const acknowledge = () => {
    if (!current() || busyRef.current || !reviewed) return
    if (clearPending()) setError(null)
  }
  // While a translation runs, check its status every few seconds (status only;
  // drafts on this page are untouched).
  const [statusPoll, setStatusPoll] = useState(0)
  const translating = event?.automatic_translation_available === true && event?.translation_status === 'pending'
  useEffect(() => {
    if (!translating) return undefined
    const timer = setTimeout(async () => {
      const request = beginRequest()
      if (!request) return
      try {
        const response = await apiClient.get(`/organizer/events/${eventId}`, request.config)
        if (request.current()) {
          setEvent(previous => previous && { ...previous, translation_status: response.data.translation_status,
            localized_content_stale: response.data.localized_content_stale })
        }
      } catch { /* The next check or a manual refresh shows the status. */ }
      finally {
        request.release()
        setStatusPoll(value => value + 1)
      }
    }, TRANSLATION_POLL_MS)
    return () => clearTimeout(timer)
  }, [translating, statusPoll, eventId, beginRequest])
  if (loading) return <div role="status" aria-label="Loading sales tools" className="flex justify-center py-20"><Loader2 className="h-8 w-8 animate-spin text-brand-500" /></div>
  if (!event) return <div className="mx-auto max-w-xl p-8"><p role="alert" className="text-red-700">{error || 'Sales tools could not be loaded.'}</p><button disabled={refreshing} className="btn-secondary mt-4" onClick={load}>Retry sales tools</button></div>
  const canUseRegistrationTools = permission('manage_events')
  if (!advancedSalesEnabled && !canUseRegistrationTools) {
    if (capabilityStatus === 'loading') return <div role="status" aria-label="Loading sales tools" className="flex justify-center py-20"><Loader2 className="h-8 w-8 animate-spin text-brand-500" /></div>
    if (capabilityStatus === 'error') return <CapabilityCheckFailed feature="advanced sales tools" onRetry={retryCapabilities} />
    return <EventAccessNotice event={event} message="Advanced sales tools are not enabled for this platform." />
  }
  if (advancedSalesEnabled && !['edit_event_content', 'manage_events', 'manage_inventory', 'manage_marketing', 'view_attendees'].some(permission)) return <EventAccessNotice event={event} message="Your event access does not include sales tools or attendee communication." />
  const locked = busy || Boolean(pending)
  const contentLanguages = [...CONTENT_LANGUAGES, ...LEGACY_CONTENT_LANGUAGES.filter(({ code }) => savedSettings?.supported_locales?.includes(code))]
  const hasDraft = Boolean(editingCampaignId) || Boolean(editingQuestionId) || JSON.stringify(settings) !== JSON.stringify(savedSettings) || [catalogForm.name, questionForm.prompt, waiverForm.title, waiverForm.body, promoterForm.name, campaignForm.name, campaignForm.subject, campaignForm.body].some(Boolean)

  return <EventWorkspace eventId={eventId} event={event} hasUnsavedChanges={hasDraft || Boolean(pending)}><div className="mx-auto max-w-5xl space-y-6">
    <div>
      <h2 className="text-2xl font-bold text-neutral-900">{advancedSalesEnabled ? 'Sales, registration and audience' : 'Registration & waivers'}</h2>
      <p className="mt-1 text-sm text-neutral-500">{advancedSalesEnabled ? `Configure revenue extras, policies, referrals and attendee communication for ${event.title}.` : `Configure registration questions and waivers for ${event.title}.`}</p>
    </div>
    {error && <div role="alert" className="rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{error}</div>}

    {notice && <p role="status" className="text-sm text-brand-800">{notice}</p>}
    <button disabled={busy || refreshing} className="btn-secondary" onClick={load}>{refreshing ? 'Refreshing saved data…' : 'Refresh saved data'}</button>
    {pending && <div role="status" className="rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950"><p>{pending.label} may have completed. Review the saved configuration or campaign status before making another change.</p><button disabled={busy || refreshing || !reviewed} className="btn-secondary mt-3" onClick={acknowledge}>I verified the saved data</button></div>}
    <fieldset disabled={locked} className="min-w-0 space-y-6"><legend className="sr-only">Sales and audience tools</legend>
    {(advancedSalesEnabled && permission('edit_event_content')) && (<Section title="Public languages" description="HåfaPass translates your title, descriptions and ticket names automatically for buyers using another language. To use your own wording in a language, turn it on below; anything left blank uses the automatic translation.">
      <div role="status" className="flex flex-wrap items-center gap-3 rounded-xl bg-neutral-50 p-4 text-sm text-neutral-700">
        <p className="min-w-0 flex-1">{event.automatic_translation_available ? TRANSLATION_STATUS[event.translation_status] || TRANSLATION_STATUS.untranslated : 'Automatic translation is not set up yet, so buyers see your English text.'}</p>
        {event.automatic_translation_available && <button type="button" className="btn-secondary min-h-11 px-4 py-2 text-sm" disabled={event.translation_status === 'pending'} onClick={retranslate}>Translate again</button>}
      </div>
      <fieldset className="mt-4 min-w-0"><legend className="text-sm font-medium text-neutral-700">Use your own wording for:</legend><div className="mt-1 flex flex-wrap gap-x-5 gap-y-2 text-sm">{contentLanguages.map(({ code, label }) => <label key={code} className="flex min-h-11 items-center gap-2"><input type="checkbox" checked={settings.supported_locales.includes(code)} onChange={e => setSettings({ ...settings, supported_locales: e.target.checked ? [...settings.supported_locales, code] : settings.supported_locales.filter(value => value !== code) })} />{label}</label>)}</div></fieldset>
      {contentLanguages.filter(({ code }) => settings.supported_locales.includes(code)).map(({ code, label }) => <div key={code} className="mt-4 grid gap-3 rounded-xl bg-neutral-50 p-4 sm:grid-cols-2"><p className="text-sm font-semibold sm:col-span-2">{label} public content</p>{[['title', 'Translated title', 'input'], ['short_description', 'Translated short description', 'input'], ['description', 'Translated description', 'textarea']].map(([field, fieldLabel, kind]) => { const props = { className: 'input font-normal', value: settings.localized_content?.[code]?.[field] || '', onChange: e => setSettings({ ...settings, localized_content: { ...settings.localized_content, [code]: { ...settings.localized_content?.[code], [field]: e.target.value } } }) }; const stale = event.localized_content_stale?.[code]?.includes(field) && props.value === (savedSettings?.localized_content?.[code]?.[field] || ''); return <Field key={field} label={fieldLabel} className={kind === 'textarea' ? 'sm:col-span-2' : ''}>{kind === 'textarea' ? <textarea rows={4} {...props} /> : <input {...props} />}{stale && <span className="text-xs font-normal text-amber-800">English changed since you wrote this. Review it before saving.</span>}</Field> })}</div>)}
      <button className="btn-primary mt-4" onClick={saveSettings}>Save languages</button>
    </Section>)}

    {(advancedSalesEnabled && permission('manage_inventory')) && (<Section title="Extras, merchandise and donations" description="These items share the checkout and financial ledger with ticket revenue.">
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5"><Field label="Item name"><input className="input font-normal" placeholder="e.g. Event T-shirt" value={catalogForm.name} onChange={e => setCatalogForm({ ...catalogForm, name: e.target.value })} /></Field><Field label="Type"><select className="input font-normal" value={catalogForm.kind} onChange={e => setCatalogForm({ ...catalogForm, kind: e.target.value })}><option value="add_on">Add-on</option><option value="merchandise">Merchandise</option><option value="concession">Concession</option><option value="donation">Donation</option></select></Field><Field label="Price ($)"><input className="input font-normal" type="number" placeholder="e.g. 25" value={catalogForm.price} onChange={e => setCatalogForm({ ...catalogForm, price: e.target.value })} /></Field><Field label="Inventory"><input className="input font-normal" type="number" placeholder="Leave blank for unlimited" value={catalogForm.inventory} onChange={e => setCatalogForm({ ...catalogForm, inventory: e.target.value })} /></Field><button className={addButtonClass} onClick={() => create('catalog_items', { name: catalogForm.name, kind: catalogForm.kind, price_cents: Math.round(Number(catalogForm.price) * 100), minimum_price_cents: catalogForm.kind === 'donation' ? Math.round(Number(catalogForm.price) * 100) : null, inventory_quantity: catalogForm.inventory ? Number(catalogForm.inventory) : null }, () => setCatalogForm(emptyCatalog))}><Plus className="h-4 w-4" /> Add item</button></div>
      <div className="mt-4 divide-y divide-neutral-100">{catalog.map(item => <div key={item.id} className="flex items-center justify-between py-3 text-sm"><span><strong>{item.name}</strong> · {item.kind.replace('_', ' ')} · ${(item.price_cents / 100).toFixed(2)} · {item.quantity_remaining ?? 'unlimited'} left</span><button className="inline-flex min-h-11 min-w-11 items-center justify-center" aria-label={`Remove ${item.name}`} onClick={() => remove('catalog_items', item.id)}><Trash2 aria-hidden="true" className="h-4 w-4 text-red-500" /></button></div>)}</div>
    </Section>)}

    {(permission('manage_events')) && (<Section title="Registration and waivers" description="Required answers and exact waiver versions are snapshotted on every order.">
      <div className="mb-6 rounded-xl border border-neutral-200 bg-neutral-50 p-4">
        <h3 className="text-base font-semibold text-neutral-900">Start from a template</h3>
        <p className="mt-1 text-sm text-neutral-600">One click adds a ready-made set of questions. You can edit, pause or remove any of them afterwards.</p>
        <Field label="Ask these questions for" className="mt-3 max-w-sm"><select className="input font-normal" value={templateTicketTypeId} onChange={e => setTemplateTicketTypeId(e.target.value)}><option value="">All ticket types</option>{(event.ticket_types || []).map(type => <option key={type.id} value={type.id}>{type.name}</option>)}</select></Field>
        <ul className="mt-3 grid gap-3 sm:grid-cols-3">{QUESTION_TEMPLATES.map(template => <li key={template.key} className="flex flex-col rounded-lg border border-neutral-200 bg-white p-3">
          <p className="text-sm font-semibold text-neutral-900">{template.title}</p>
          <p className="mt-1 flex-1 text-sm text-neutral-600">{template.description}</p>
          <button type="button" className="btn-secondary mt-3 min-h-11 px-4 py-2 text-sm" aria-label={`Add ${template.title} template`} onClick={() => applyTemplate(template)}><Plus aria-hidden="true" className="h-4 w-4" /> Add template</button>
        </li>)}</ul>
      </div>
      <QuestionControls form={questionForm} onChange={setQuestionForm} ticketTypes={event.ticket_types || []} idPrefix="new-question" />
      <button type="button" className={`${addButtonClass} mt-3`} onClick={() => create('registration_questions', { ...questionPayload(questionForm), position: questions.length }, () => setQuestionForm(emptyQuestion))}>Add question</button>
      {questions.length === 0 ? (
        <p className="mt-3 text-sm text-neutral-500">No registration questions yet. Add questions above to collect team names, divisions, or attendee details at checkout.</p>
      ) : (
        <ol aria-label="Registration questions" className="mt-4 divide-y divide-neutral-200 rounded-xl border border-neutral-200 bg-white">
          {questions.map((item, index) => {
            const inactive = item.active === false
            const isEditing = editingQuestionId === item.id
            return (
              <li key={item.id} className={`p-4 ${inactive ? 'bg-neutral-50/70' : ''}`}>
                {isEditing ? (
                  <div className="space-y-3">
                    <QuestionControls form={editQuestionForm} onChange={setEditQuestionForm} ticketTypes={event.ticket_types || []} idPrefix={`edit-question-${item.id}`} editing />
                    <div className="flex flex-wrap items-center justify-end gap-3">
                      <div className="flex items-center gap-2">
                        <button type="button" className="btn-secondary min-h-11 px-4 py-2 text-sm" onClick={cancelEditQuestion}>Cancel</button>
                        <button type="button" className="btn-primary min-h-11 px-4 py-2 text-sm" onClick={() => saveEditQuestion(item)}>Save question</button>
                      </div>
                    </div>
                  </div>
                ) : (
                  <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <span className={`text-sm font-semibold ${inactive ? 'text-neutral-500 line-through' : 'text-neutral-900'}`}>{item.prompt}</span>
                        {item.required && <span className="rounded-full bg-brand-50 px-2 py-0.5 text-xs font-medium text-brand-800">Required</span>}
                        {inactive && <span className="rounded-full bg-neutral-200 px-2 py-0.5 text-xs font-medium text-neutral-700">Paused</span>}
                        {item.show_on_scanner && <span className="rounded-full bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-900">Door scanner</span>}
                      </div>
                      <p className="mt-1 text-xs text-neutral-500">
                        {QUESTION_KIND_LABELS[item.kind] || item.kind}
                        {OPTION_KINDS.includes(item.kind) && Array.isArray(item.options) && item.options.length > 0 ? ` · Choices: ${item.options.join(', ')}` : ''}
                        {item.kind === 'number' && (item.validation_rules?.min != null || item.validation_rules?.max != null) ? ` · ${item.validation_rules?.min ?? 'any'} to ${item.validation_rules?.max ?? 'any'}` : ''}
                        {item.kind === 'number' && item.validation_rules?.integer ? ' · Whole numbers' : ''}
                        {` · ${questionScopeSummary(item, event.ticket_types || [])}`}
                      </p>
                      {item.help_text && <p className="mt-1 text-xs text-neutral-500">Hint: {item.help_text}</p>}
                    </div>
                    <div className="flex flex-wrap items-center gap-1.5">
                      <button type="button" className="btn-ghost inline-flex min-h-11 min-w-11 items-center justify-center p-2" aria-label={`Move ${item.prompt} up`} disabled={index === 0} onClick={() => moveQuestion(index, -1)}><ChevronUp aria-hidden="true" className="h-4 w-4" /></button>
                      <button type="button" className="btn-ghost inline-flex min-h-11 min-w-11 items-center justify-center p-2" aria-label={`Move ${item.prompt} down`} disabled={index === questions.length - 1} onClick={() => moveQuestion(index, 1)}><ChevronDown aria-hidden="true" className="h-4 w-4" /></button>
                      <button type="button" className="btn-secondary min-h-11 gap-1.5 px-3 py-2 text-sm" aria-label={`Edit ${item.prompt}`} onClick={() => startEditQuestion(item)}><Pencil aria-hidden="true" className="h-3.5 w-3.5" /> Edit</button>
                      <button type="button" className="btn-secondary min-h-11 px-3 py-2 text-sm" aria-label={inactive ? `Resume ${item.prompt}` : `Pause ${item.prompt}`} onClick={() => toggleQuestionActive(item)}>{inactive ? 'Resume' : 'Pause'}</button>
                      <button type="button" className="inline-flex min-h-11 min-w-11 items-center justify-center rounded-lg text-red-600 hover:bg-red-50" aria-label={`Remove ${item.prompt}`} onClick={() => remove('registration_questions', item.id)}><Trash2 aria-hidden="true" className="h-4 w-4" /></button>
                    </div>
                  </div>
                )}
              </li>
            )
          })}
        </ol>
      )}
      <div className="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4"><Field label="Waiver title"><input className="input font-normal" placeholder="e.g. Beach activity release" value={waiverForm.title} onChange={e => setWaiverForm({ ...waiverForm, title: e.target.value })} /></Field><Field label="Version"><input className="input font-normal" placeholder="e.g. 1.0" value={waiverForm.version} onChange={e => setWaiverForm({ ...waiverForm, version: e.target.value })} /></Field><Field label="Waiver text"><textarea className="input font-normal" placeholder="Full text attendees agree to" value={waiverForm.body} onChange={e => setWaiverForm({ ...waiverForm, body: e.target.value })} /></Field><button type="button" className={addButtonClass} onClick={() => create('event_waivers', waiverForm, () => setWaiverForm(emptyWaiver))}>Add waiver</button></div>
      <div className="mt-3 flex flex-wrap gap-2">{waivers.map(item => <span key={item.id} className="rounded-full bg-neutral-100 px-3 py-1.5 text-xs">{item.title} v{item.version} <button type="button" aria-label={`Remove ${item.title}`} onClick={() => remove('event_waivers', item.id)} className="ml-1 text-red-500">×</button></span>)}</div>
    </Section>)}

    {(advancedSalesEnabled && permission('manage_marketing')) && (<Section title="Promoters and referral commission" description="Referral codes attribute orders and commission entries reverse automatically with refunds.">
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5"><Field label="Promoter name"><input className="input font-normal" placeholder="e.g. Maria Cruz" value={promoterForm.name} onChange={e => setPromoterForm({ ...promoterForm, name: e.target.value })} /></Field><Field label="Promoter email"><input className="input font-normal" type="email" placeholder="e.g. maria@example.com" value={promoterForm.email} onChange={e => setPromoterForm({ ...promoterForm, email: e.target.value })} /></Field><Field label="Referral code"><input className="input font-normal uppercase" placeholder="e.g. MARIA10" value={promoterForm.code} onChange={e => setPromoterForm({ ...promoterForm, code: e.target.value.toUpperCase() })} /></Field><Field label="Commission (%)"><input className="input font-normal" type="number" placeholder="e.g. 10" value={promoterForm.commission} onChange={e => setPromoterForm({ ...promoterForm, commission: e.target.value })} /></Field><button className={addButtonClass} onClick={() => create('promoters', { name: promoterForm.name, email: promoterForm.email, code: promoterForm.code, commission_bps: Math.round(Number(promoterForm.commission) * 100) }, () => setPromoterForm(emptyPromoter))}>Add promoter</button></div>
      <div className="mt-4 divide-y divide-neutral-100">{promoters.map(item => <div key={item.id} className="flex items-center justify-between py-3 text-sm"><span><strong>{item.name}</strong> · <code>{item.code}</code> · {item.attributed_orders} orders · ${(item.net_commission_cents / 100).toFixed(2)} net</span><button onClick={() => remove('promoters', item.id)}><Trash2 className="h-4 w-4 text-red-500" /></button></div>)}</div>
    </Section>)}

    {(advancedSalesEnabled && (permission('manage_marketing') || permission('view_attendees'))) && (<Section title="CRM and attendee communication" description="Export current attendee data and send a durable, suppression-aware event message to a defined segment.">
      <div className="mb-4 flex flex-wrap items-center gap-3 text-sm">{segments ? <><span>{segments.all_attendees || 0} active recipients</span><span>{segments.checked_in || 0} checked in</span><span>{segments.not_checked_in || 0} not checked in</span></> : <span>{permission('view_attendees') ? 'Recipient counts unavailable.' : 'Recipient counts require attendee access.'}</span>}<button disabled={!permission('view_attendees')} className="btn-secondary ml-auto inline-flex" onClick={downloadExport}><Download className="h-4 w-4" /> Export CSV</button></div>
      {permission('manage_marketing') && <><p className="mb-3 text-sm text-neutral-700">Campaigns are promotional emails. Only buyers who opted in can receive them. Use an honest subject that describes the message. The sender is your organization via HåfaPass; the owner must certify its public postal address in Organization settings before sending.</p><div className="grid gap-3 sm:grid-cols-2">{editingCampaignId && <p className="font-semibold sm:col-span-2">Review saved campaign</p>}<Field label="Internal campaign name"><input ref={campaignNameInput} className="input font-normal" placeholder="e.g. Week-before reminder" value={campaignForm.name} onChange={e => setCampaignForm({ ...campaignForm, name: e.target.value })} /></Field><Field label="Email subject"><input className="input font-normal" placeholder="e.g. See you at the beach on Saturday" value={campaignForm.subject} onChange={e => setCampaignForm({ ...campaignForm, subject: e.target.value })} /></Field><Field label="Recipients"><select className="input font-normal" value={campaignForm.segment} onChange={e => setCampaignForm({ ...campaignForm, segment: e.target.value })}><option value="all_attendees">All attendees</option><option value="checked_in">Checked in</option><option value="not_checked_in">Not checked in</option><option value="ticket_type">Ticket type</option></select></Field>{campaignForm.segment === 'ticket_type' && <Field label="Ticket type"><select className="input font-normal" value={campaignForm.ticket_type_id} onChange={e => setCampaignForm({ ...campaignForm, ticket_type_id: e.target.value })}><option value="">Choose a ticket type</option>{(event.ticket_types || []).map(type => <option key={type.id} value={type.id}>{type.name}</option>)}</select></Field>}<Field label="Send at (optional)"><input className="input font-normal" type="datetime-local" value={campaignForm.scheduled_at} onChange={e => setCampaignForm({ ...campaignForm, scheduled_at: e.target.value })} /></Field><Field label="Message" className="sm:col-span-2"><textarea className="input font-normal" rows="4" placeholder="Write the email attendees will receive" value={campaignForm.body} onChange={e => setCampaignForm({ ...campaignForm, body: e.target.value })} /></Field><button className="btn-primary sm:col-span-2 sm:justify-self-start" onClick={saveCampaign}>{editingCampaignId ? 'Save campaign changes' : 'Save campaign'}</button>{editingCampaignId && <button className="btn-secondary sm:justify-self-start" onClick={() => { setEditingCampaignId(null); setCampaignForm(emptyCampaign) }}>Cancel editing</button>}</div></>}
      <div className="mt-4 divide-y divide-neutral-100">{campaigns.map(item => <div key={item.id} className="flex flex-wrap items-center justify-between gap-3 py-3 text-sm"><span className="min-w-0 flex-1 [overflow-wrap:anywhere]"><strong>{item.name}</strong> · {item.status} · {item.recipient_count} sent<br />{item.last_error && <span role="status" className="my-2 block max-w-xl text-amber-900">{item.last_error}</span>}{item.audience && <small>{item.audience.opted_in} of {item.audience.attendees} attendees opted in · {item.audience.excluded} excluded by consent, unsubscribe or suppression · {item.audience.eligible} eligible</small>}</span>{permission('manage_marketing') && item.status === 'failed' && <button className="btn-secondary min-h-11 shrink-0" onClick={() => reviewCampaign(item)}>Review and reschedule</button>}{permission('manage_marketing') && ['draft', 'scheduled'].includes(item.status) && <button className="inline-flex items-center gap-1 font-semibold text-brand-600" onClick={() => sendCampaign(item)}><Send className="h-4 w-4" /> Send now</button>}</div>)}</div>
    </Section>)}
    </fieldset>
  </div></EventWorkspace>
}

export default function SalesToolsPage() {
  const { id: eventId } = useParams()
  const identity = useOrganizerIdentity()
  const visit = useOrganizerPageVisit(`/dashboard/events/${eventId}/sales-tools`)
  if (!visit.active) return null
  if (!identity.ready) return <p role="status" className="p-6">Preparing your account…</p>
  return <SalesToolsSession key={`${identity.accountKey}:${identity.organizationId}:${eventId}:${visit.generation}`} eventId={eventId} identity={identity} />
}
