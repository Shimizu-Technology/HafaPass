import EventWorkspace from '../../components/EventWorkspace'
import { useCallback, useEffect, useRef, useState } from 'react'
import { useParams } from 'react-router-dom'
import { Download, Loader2, Plus, Send, Trash2 } from 'lucide-react'
import apiClient from '../../api/client'
import EventAccessNotice from '../../components/EventAccessNotice'
import useLaunchCapabilities from '../../hooks/useLaunchCapabilities'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'

const emptyCatalog = { name: '', kind: 'add_on', price: '', inventory: '' }
const emptyQuestion = { prompt: '', kind: 'short_text', required: false, options: '' }
const emptyWaiver = { title: '', version: '1.0', body: '', required: true }
const emptyPromoter = { name: '', email: '', code: '', commission: '10' }
const emptyCampaign = { name: '', subject: '', body: '', segment: 'all_attendees', scheduled_at: '' }

function Section({ title, description, children }) {
  return <section className="card p-5 sm:p-6"><h2 className="text-lg font-bold text-neutral-900">{title}</h2><p className="mb-5 mt-1 text-sm text-neutral-500">{description}</p>{children}</section>
}

function SalesToolsSession({ eventId, identity }) {
  const { current, beginRequest } = useOrganizerRequests(identity, `/dashboard/events/${eventId}/sales-tools`)
  const capabilities = useLaunchCapabilities()
  const loadState = useRef({ generation: 0, request: null })
  const initialized = useRef(false)
  const busyRef = useRef(false)
  const storageKey = `hafapass:sales-tools-outcome:${identity.owner}:${identity.organizationId}:${eventId}`
  const [pending, setPending] = useState(() => { try { return JSON.parse(window.sessionStorage.getItem(storageKey) || 'null') } catch { return { label: 'A previous sales change' } } })
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

  const permission = key => event?.permissions?.[key] === true
  const resourcePermissions = { catalog_items: 'manage_inventory', registration_questions: 'manage_events', event_waivers: 'manage_events', promoters: 'manage_marketing', communication_campaigns: 'manage_marketing' }
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
      const allowed = key => capabilities.advanced_sales_tools === true && saved.permissions?.[key] === true
      const resources = [['catalog_items', 'manage_inventory'], ['registration_questions', 'manage_events'], ['event_waivers', 'manage_events'], ['promoters', 'manage_marketing'], ['communication_campaigns', 'manage_marketing'], ['crm/segments', 'view_attendees']]
      const responses = await Promise.all(resources.map(([path, key]) => allowed(key) ? apiClient.get(`/organizer/events/${eventId}/${path}`, request.config) : Promise.resolve(null)))
      if (!canApply()) return
      setEvent(saved)
      setCatalog(responses[0]?.data.catalog_items || [])
      setQuestions(responses[1]?.data.registration_questions || [])
      setWaivers(responses[2]?.data.event_waivers || [])
      setPromoters(responses[3]?.data.promoters || [])
      setCampaigns(responses[4]?.data.communication_campaigns || [])
      setSegments(responses[5]?.data.segments || null)
      if (!initialized.current) {
        const initial = { fee_policy: saved.fee_policy, buyer_fee_percent: saved.buyer_fee_percent, transfers_enabled: saved.transfers_enabled, supported_locales: saved.supported_locales || [], localized_content: saved.localized_content || {} }
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
    if (!allowed || capabilities.advanced_sales_tools !== true || !current() || busyRef.current || pendingRef.current) return
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
  const create = (resource, payload, reset) => mutate('Save configuration', permission(resourcePermissions[resource]), config => apiClient.post(`/organizer/events/${eventId}/${resource}`, payload, config), reset)
  const remove = (resource, itemId) => {
    if (!current() || busyRef.current || pendingRef.current || !permission(resourcePermissions[resource])) return
    if (!window.confirm('Remove this configuration? Existing historical records will remain protected.')) return
    return mutate('Remove configuration', true, config => apiClient.delete(`/organizer/events/${eventId}/${resource}/${itemId}`, config))
  }
  const saveSettings = () => {
    const body = { ...settings, buyer_fee_percent: settings.fee_policy === 'buyer_pays' ? 100 : settings.fee_policy === 'organizer_absorbs' ? 0 : Number(settings.buyer_fee_percent) }
    return mutate('Sales settings', permission('edit_event_content'), config => apiClient.put(`/organizer/events/${eventId}`, body, config), () => setSavedSettings(settings))
  }
  const sendCampaign = item => mutate('Campaign submission', permission('manage_marketing') && ['draft', 'scheduled'].includes(item.status), config => apiClient.post(`/organizer/events/${eventId}/communication_campaigns/${item.id}/send_now`, undefined, config))
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
  if (loading) return <div role="status" aria-label="Loading sales tools" className="flex justify-center py-20"><Loader2 className="h-8 w-8 animate-spin text-brand-500" /></div>
  if (!event) return <div className="mx-auto max-w-xl p-8"><p role="alert" className="text-red-700">{error || 'Sales tools could not be loaded.'}</p><button disabled={refreshing} className="btn-secondary mt-4" onClick={load}>Retry sales tools</button></div>
  if (capabilities.advanced_sales_tools !== true) return <EventAccessNotice event={event} message="Advanced sales tools are not enabled for this platform." />
  if (!['edit_event_content', 'manage_events', 'manage_inventory', 'manage_marketing', 'view_attendees'].some(permission)) return <EventAccessNotice event={event} message="Your event access does not include sales tools or attendee communication." />
  const locked = busy || Boolean(pending)
  const hasDraft = JSON.stringify(settings) !== JSON.stringify(savedSettings) || [catalogForm.name, questionForm.prompt, waiverForm.title, waiverForm.body, promoterForm.name, campaignForm.name, campaignForm.subject, campaignForm.body].some(Boolean)

  return <EventWorkspace eventId={eventId} event={event} hasUnsavedChanges={hasDraft || Boolean(pending)}><div className="mx-auto max-w-5xl space-y-6">
    <div><h2 className="text-2xl font-bold text-neutral-900">Sales, registration and audience</h2><p className="mt-1 text-sm text-neutral-500">Configure revenue extras, policies, referrals and attendee communication for {event.title}.</p></div>
    {error && <div role="alert" className="rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{error}</div>}

    {notice && <p role="status" className="text-sm text-brand-800">{notice}</p>}
    <button disabled={busy || refreshing} className="btn-secondary" onClick={load}>{refreshing ? 'Refreshing saved data…' : 'Refresh saved data'}</button>
    {pending && <div role="status" className="rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950"><p>{pending.label} may have completed. Review the saved configuration or campaign status before making another change.</p><button disabled={busy || refreshing || !reviewed} className="btn-secondary mt-3" onClick={acknowledge}>I verified the saved data</button></div>}
    <fieldset disabled={locked} className="min-w-0 space-y-6"><legend className="sr-only">Sales and audience tools</legend>
    {(permission('edit_event_content')) && (<Section title="Ticket policy and languages" description="Choose who pays platform fees, whether tickets can transfer, and maintained public translations.">
      <div className="grid gap-4 sm:grid-cols-3">
        <label className="text-sm">Fee policy<select className="input mt-1" value={settings.fee_policy} onChange={e => setSettings({ ...settings, fee_policy: e.target.value })}><option value="buyer_pays">Buyer pays</option><option value="organizer_absorbs">Organizer absorbs</option><option value="split_fees">Split fees</option></select></label>
        <label className="text-sm">Buyer share (%)<input className="input mt-1" type="number" min="1" max="99" disabled={settings.fee_policy !== 'split_fees'} value={settings.fee_policy === 'buyer_pays' ? 100 : settings.fee_policy === 'organizer_absorbs' ? 0 : settings.buyer_fee_percent} onChange={e => setSettings({ ...settings, buyer_fee_percent: Number(e.target.value) })} /></label>
        <label className="mt-7 flex items-center gap-2 text-sm"><input type="checkbox" checked={settings.transfers_enabled} onChange={e => setSettings({ ...settings, transfers_enabled: e.target.checked })} /> Allow secure ticket transfers</label>
      </div>
      <div className="mt-4 flex gap-5 text-sm">{['ja', 'ch'].map(locale => <label key={locale} className="flex items-center gap-2"><input type="checkbox" checked={settings.supported_locales.includes(locale)} onChange={e => setSettings({ ...settings, supported_locales: e.target.checked ? [...settings.supported_locales, locale] : settings.supported_locales.filter(value => value !== locale) })} />{locale === 'ja' ? 'Japanese' : 'CHamoru'}</label>)}</div>
      {['ja', 'ch'].filter(locale => settings.supported_locales.includes(locale)).map(locale => <div key={locale} className="mt-4 grid gap-3 rounded-xl bg-neutral-50 p-4 sm:grid-cols-2"><p className="sm:col-span-2 text-sm font-semibold">{locale === 'ja' ? 'Japanese' : 'CHamoru'} public content</p><input className="input" placeholder="Translated title" value={settings.localized_content?.[locale]?.title || ''} onChange={e => setSettings({ ...settings, localized_content: { ...settings.localized_content, [locale]: { ...settings.localized_content?.[locale], title: e.target.value } } })} /><textarea className="input" placeholder="Translated description" value={settings.localized_content?.[locale]?.description || ''} onChange={e => setSettings({ ...settings, localized_content: { ...settings.localized_content, [locale]: { ...settings.localized_content?.[locale], description: e.target.value } } })} /></div>)}
      <button className="btn-primary mt-4" onClick={saveSettings}>Save sales settings</button>
    </Section>)}

    {(permission('manage_inventory')) && (<Section title="Extras, merchandise and donations" description="These items share the checkout and financial ledger with ticket revenue.">
      <div className="grid gap-2 sm:grid-cols-5"><input className="input" placeholder="Name" value={catalogForm.name} onChange={e => setCatalogForm({ ...catalogForm, name: e.target.value })} /><select className="input" value={catalogForm.kind} onChange={e => setCatalogForm({ ...catalogForm, kind: e.target.value })}><option value="add_on">Add-on</option><option value="merchandise">Merchandise</option><option value="concession">Concession</option><option value="donation">Donation</option></select><input className="input" type="number" placeholder="Price $" value={catalogForm.price} onChange={e => setCatalogForm({ ...catalogForm, price: e.target.value })} /><input className="input" type="number" placeholder="Inventory" value={catalogForm.inventory} onChange={e => setCatalogForm({ ...catalogForm, inventory: e.target.value })} /><button className="btn-primary" onClick={() => create('catalog_items', { name: catalogForm.name, kind: catalogForm.kind, price_cents: Math.round(Number(catalogForm.price) * 100), minimum_price_cents: catalogForm.kind === 'donation' ? Math.round(Number(catalogForm.price) * 100) : null, inventory_quantity: catalogForm.inventory ? Number(catalogForm.inventory) : null }, () => setCatalogForm(emptyCatalog))}><Plus className="h-4 w-4" /> Add</button></div>
      <div className="mt-4 divide-y divide-neutral-100">{catalog.map(item => <div key={item.id} className="flex items-center justify-between py-3 text-sm"><span><strong>{item.name}</strong> · {item.kind.replace('_', ' ')} · ${(item.price_cents / 100).toFixed(2)} · {item.quantity_remaining ?? 'unlimited'} left</span><button onClick={() => remove('catalog_items', item.id)}><Trash2 className="h-4 w-4 text-red-500" /></button></div>)}</div>
    </Section>)}

    {(permission('manage_events')) && (<Section title="Registration and waivers" description="Required answers and exact waiver versions are snapshotted on every order.">
      <div className="grid gap-2 sm:grid-cols-5"><input className="input sm:col-span-2" placeholder="Question" value={questionForm.prompt} onChange={e => setQuestionForm({ ...questionForm, prompt: e.target.value })} /><select className="input" value={questionForm.kind} onChange={e => setQuestionForm({ ...questionForm, kind: e.target.value })}><option value="short_text">Short text</option><option value="long_text">Long text</option><option value="selection">Selection</option><option value="checkbox">Checkbox</option></select><input className="input" placeholder="Choices, comma separated" disabled={questionForm.kind !== 'selection'} value={questionForm.options} onChange={e => setQuestionForm({ ...questionForm, options: e.target.value })} /><button className="btn-primary" onClick={() => create('registration_questions', { prompt: questionForm.prompt, kind: questionForm.kind, required: questionForm.required, options: questionForm.options.split(',').map(value => value.trim()).filter(Boolean) }, () => setQuestionForm(emptyQuestion))}>Add question</button></div>
      <label className="mt-2 flex items-center gap-2 text-sm"><input type="checkbox" checked={questionForm.required} onChange={e => setQuestionForm({ ...questionForm, required: e.target.checked })} /> Required question</label>
      <div className="mt-3 flex flex-wrap gap-2">{questions.map(item => <span key={item.id} className="rounded-full bg-neutral-100 px-3 py-1.5 text-xs">{item.prompt}{item.required ? ' *' : ''} <button onClick={() => remove('registration_questions', item.id)} className="ml-1 text-red-500">×</button></span>)}</div>
      <div className="mt-6 grid gap-2 sm:grid-cols-4"><input className="input" placeholder="Waiver title" value={waiverForm.title} onChange={e => setWaiverForm({ ...waiverForm, title: e.target.value })} /><input className="input" placeholder="Version" value={waiverForm.version} onChange={e => setWaiverForm({ ...waiverForm, version: e.target.value })} /><textarea className="input" placeholder="Waiver text" value={waiverForm.body} onChange={e => setWaiverForm({ ...waiverForm, body: e.target.value })} /><button className="btn-primary" onClick={() => create('event_waivers', waiverForm, () => setWaiverForm(emptyWaiver))}>Add waiver</button></div>
      <div className="mt-3 flex flex-wrap gap-2">{waivers.map(item => <span key={item.id} className="rounded-full bg-neutral-100 px-3 py-1.5 text-xs">{item.title} v{item.version} <button onClick={() => remove('event_waivers', item.id)} className="ml-1 text-red-500">×</button></span>)}</div>
    </Section>)}

    {(permission('manage_marketing')) && (<Section title="Promoters and referral commission" description="Referral codes attribute orders and commission entries reverse automatically with refunds.">
      <div className="grid gap-2 sm:grid-cols-5"><input className="input" placeholder="Name" value={promoterForm.name} onChange={e => setPromoterForm({ ...promoterForm, name: e.target.value })} /><input className="input" placeholder="Email" value={promoterForm.email} onChange={e => setPromoterForm({ ...promoterForm, email: e.target.value })} /><input className="input uppercase" placeholder="Code" value={promoterForm.code} onChange={e => setPromoterForm({ ...promoterForm, code: e.target.value.toUpperCase() })} /><input className="input" type="number" placeholder="Commission %" value={promoterForm.commission} onChange={e => setPromoterForm({ ...promoterForm, commission: e.target.value })} /><button className="btn-primary" onClick={() => create('promoters', { name: promoterForm.name, email: promoterForm.email, code: promoterForm.code, commission_bps: Math.round(Number(promoterForm.commission) * 100) }, () => setPromoterForm(emptyPromoter))}>Add promoter</button></div>
      <div className="mt-4 divide-y divide-neutral-100">{promoters.map(item => <div key={item.id} className="flex items-center justify-between py-3 text-sm"><span><strong>{item.name}</strong> · <code>{item.code}</code> · {item.attributed_orders} orders · ${(item.net_commission_cents / 100).toFixed(2)} net</span><button onClick={() => remove('promoters', item.id)}><Trash2 className="h-4 w-4 text-red-500" /></button></div>)}</div>
    </Section>)}

    {(permission('manage_marketing') || permission('view_attendees')) && (<Section title="CRM and attendee communication" description="Export current attendee data and send a durable, suppression-aware event message to a defined segment.">
      <div className="mb-4 flex flex-wrap items-center gap-3 text-sm">{segments ? <><span>{segments.all_attendees || 0} active recipients</span><span>{segments.checked_in || 0} checked in</span><span>{segments.not_checked_in || 0} not checked in</span></> : <span>{permission('view_attendees') ? 'Recipient counts unavailable.' : 'Recipient counts require attendee access.'}</span>}<button disabled={!permission('view_attendees')} className="btn-secondary ml-auto inline-flex" onClick={downloadExport}><Download className="h-4 w-4" /> Export CSV</button></div>
      {permission('manage_marketing') && <div className="grid gap-2 sm:grid-cols-2"><input className="input" placeholder="Internal campaign name" value={campaignForm.name} onChange={e => setCampaignForm({ ...campaignForm, name: e.target.value })} /><input className="input" placeholder="Email subject" value={campaignForm.subject} onChange={e => setCampaignForm({ ...campaignForm, subject: e.target.value })} /><select className="input" value={campaignForm.segment} onChange={e => setCampaignForm({ ...campaignForm, segment: e.target.value })}><option value="all_attendees">All attendees</option><option value="checked_in">Checked in</option><option value="not_checked_in">Not checked in</option></select><input className="input" type="datetime-local" value={campaignForm.scheduled_at} onChange={e => setCampaignForm({ ...campaignForm, scheduled_at: e.target.value })} /><textarea className="input sm:col-span-2" rows="4" placeholder="Message" value={campaignForm.body} onChange={e => setCampaignForm({ ...campaignForm, body: e.target.value })} /><button className="btn-primary sm:col-span-2" onClick={() => create('communication_campaigns', { name: campaignForm.name, subject: campaignForm.subject, body: campaignForm.body, segment: { type: campaignForm.segment }, scheduled_at: campaignForm.scheduled_at || null }, () => setCampaignForm(emptyCampaign))}>Save campaign</button></div>}
      <div className="mt-4 divide-y divide-neutral-100">{campaigns.map(item => <div key={item.id} className="flex items-center justify-between py-3 text-sm"><span><strong>{item.name}</strong> · {item.status} · {item.recipient_count} recipients</span>{['draft', 'scheduled'].includes(item.status) && <button className="inline-flex items-center gap-1 font-semibold text-brand-600" onClick={() => sendCampaign(item)}><Send className="h-4 w-4" /> Send now</button>}</div>)}</div>
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
