import { useCallback, useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { ArrowLeft, Download, Loader2, Plus, Send, Trash2 } from 'lucide-react'
import apiClient from '../../api/client'

const emptyCatalog = { name: '', kind: 'add_on', price: '', inventory: '' }
const emptyQuestion = { prompt: '', kind: 'short_text', required: false, options: '' }
const emptyWaiver = { title: '', version: '1.0', body: '', required: true }
const emptyPromoter = { name: '', email: '', code: '', commission: '10' }
const emptyCampaign = { name: '', subject: '', body: '', segment: 'all_attendees', scheduled_at: '' }

function Section({ title, description, children }) {
  return <section className="card p-5 sm:p-6"><h2 className="text-lg font-bold text-neutral-900">{title}</h2><p className="mb-5 mt-1 text-sm text-neutral-500">{description}</p>{children}</section>
}

export default function SalesToolsPage() {
  const { id: eventId } = useParams()
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

  const load = useCallback(async () => {
    try {
      const [eventRes, catalogRes, questionRes, waiverRes, promoterRes, campaignRes, segmentRes] = await Promise.all([
        apiClient.get(`/organizer/events/${eventId}`),
        apiClient.get(`/organizer/events/${eventId}/catalog_items`),
        apiClient.get(`/organizer/events/${eventId}/registration_questions`),
        apiClient.get(`/organizer/events/${eventId}/event_waivers`),
        apiClient.get(`/organizer/events/${eventId}/promoters`),
        apiClient.get(`/organizer/events/${eventId}/communication_campaigns`),
        apiClient.get(`/organizer/events/${eventId}/crm/segments`),
      ])
      setEvent(eventRes.data); setCatalog(catalogRes.data.catalog_items); setQuestions(questionRes.data.registration_questions)
      setWaivers(waiverRes.data.event_waivers); setPromoters(promoterRes.data.promoters)
      setCampaigns(campaignRes.data.communication_campaigns); setSegments(segmentRes.data.segments)
    } catch (err) { setError(err.response?.data?.error || 'Unable to load sales tools.') }
    finally { setLoading(false) }
  }, [eventId])

  useEffect(() => { load() }, [load])

  const create = async (resource, payload, reset) => {
    setError(null)
    try { await apiClient.post(`/organizer/events/${eventId}/${resource}`, payload); reset(); await load() }
    catch (err) { setError(err.response?.data?.errors?.join(', ') || err.response?.data?.error || 'Unable to save.') }
  }
  const remove = async (resource, itemId) => {
    if (!window.confirm('Remove this configuration? Existing historical records will remain protected.')) return
    try { await apiClient.delete(`/organizer/events/${eventId}/${resource}/${itemId}`); await load() }
    catch (err) { setError(err.response?.data?.errors?.join(', ') || 'This item has history and cannot be removed; deactivate it instead.') }
  }

  async function saveSettings() {
    const buyerPercent = event.fee_policy === 'buyer_pays' ? 100 : event.fee_policy === 'organizer_absorbs' ? 0 : Number(event.buyer_fee_percent)
    try {
      await apiClient.put(`/organizer/events/${eventId}`, {
        fee_policy: event.fee_policy, buyer_fee_percent: buyerPercent, transfers_enabled: event.transfers_enabled,
        supported_locales: event.supported_locales, localized_content: event.localized_content,
      })
      await load()
    } catch (err) { setError(err.response?.data?.errors?.join(', ') || 'Unable to save event sales settings.') }
  }

  async function downloadExport() {
    try {
      const response = await apiClient.get(`/organizer/events/${eventId}/crm/export`, { responseType: 'blob' })
      const url = window.URL.createObjectURL(response.data)
      const link = document.createElement('a')
      link.href = url; link.download = `${event.slug}-attendees.csv`; link.click()
      window.URL.revokeObjectURL(url)
    } catch { setError('Unable to export attendees.') }
  }

  if (loading) return <div className="flex justify-center py-20"><Loader2 className="h-8 w-8 animate-spin text-brand-500" /></div>
  if (!event) return <div className="mx-auto max-w-xl p-8 text-red-700">{error}</div>

  return <div className="mx-auto max-w-5xl space-y-6 px-4 py-8 sm:px-6">
    <Link to={`/dashboard/events/${eventId}/edit`} className="inline-flex items-center gap-1.5 text-sm font-medium text-neutral-500"><ArrowLeft className="h-4 w-4" /> Back to event</Link>
    <div><h1 className="text-2xl font-bold text-neutral-900">Sales, registration and audience</h1><p className="mt-1 text-sm text-neutral-500">Configure revenue extras, policies, referrals and attendee communication for {event.title}.</p></div>
    {error && <div className="rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{error}</div>}

    <Section title="Ticket policy and languages" description="Choose who pays platform fees, whether tickets can transfer, and maintained public translations.">
      <div className="grid gap-4 sm:grid-cols-3">
        <label className="text-sm">Fee policy<select className="input mt-1" value={event.fee_policy} onChange={e => setEvent({ ...event, fee_policy: e.target.value })}><option value="buyer_pays">Buyer pays</option><option value="organizer_absorbs">Organizer absorbs</option><option value="split_fees">Split fees</option></select></label>
        <label className="text-sm">Buyer share (%)<input className="input mt-1" type="number" min="1" max="99" disabled={event.fee_policy !== 'split_fees'} value={event.fee_policy === 'buyer_pays' ? 100 : event.fee_policy === 'organizer_absorbs' ? 0 : event.buyer_fee_percent} onChange={e => setEvent({ ...event, buyer_fee_percent: Number(e.target.value) })} /></label>
        <label className="mt-7 flex items-center gap-2 text-sm"><input type="checkbox" checked={event.transfers_enabled} onChange={e => setEvent({ ...event, transfers_enabled: e.target.checked })} /> Allow secure ticket transfers</label>
      </div>
      <div className="mt-4 flex gap-5 text-sm">{['ja', 'ch'].map(locale => <label key={locale} className="flex items-center gap-2"><input type="checkbox" checked={event.supported_locales.includes(locale)} onChange={e => setEvent({ ...event, supported_locales: e.target.checked ? [...event.supported_locales, locale] : event.supported_locales.filter(value => value !== locale) })} />{locale === 'ja' ? 'Japanese' : 'CHamoru'}</label>)}</div>
      {['ja', 'ch'].filter(locale => event.supported_locales.includes(locale)).map(locale => <div key={locale} className="mt-4 grid gap-3 rounded-xl bg-neutral-50 p-4 sm:grid-cols-2"><p className="sm:col-span-2 text-sm font-semibold">{locale === 'ja' ? 'Japanese' : 'CHamoru'} public content</p><input className="input" placeholder="Translated title" value={event.localized_content?.[locale]?.title || ''} onChange={e => setEvent({ ...event, localized_content: { ...event.localized_content, [locale]: { ...event.localized_content?.[locale], title: e.target.value } } })} /><textarea className="input" placeholder="Translated description" value={event.localized_content?.[locale]?.description || ''} onChange={e => setEvent({ ...event, localized_content: { ...event.localized_content, [locale]: { ...event.localized_content?.[locale], description: e.target.value } } })} /></div>)}
      <button className="btn-primary mt-4" onClick={saveSettings}>Save sales settings</button>
    </Section>

    <Section title="Extras, merchandise and donations" description="These items share the checkout and financial ledger with ticket revenue.">
      <div className="grid gap-2 sm:grid-cols-5"><input className="input" placeholder="Name" value={catalogForm.name} onChange={e => setCatalogForm({ ...catalogForm, name: e.target.value })} /><select className="input" value={catalogForm.kind} onChange={e => setCatalogForm({ ...catalogForm, kind: e.target.value })}><option value="add_on">Add-on</option><option value="merchandise">Merchandise</option><option value="concession">Concession</option><option value="donation">Donation</option></select><input className="input" type="number" placeholder="Price $" value={catalogForm.price} onChange={e => setCatalogForm({ ...catalogForm, price: e.target.value })} /><input className="input" type="number" placeholder="Inventory" value={catalogForm.inventory} onChange={e => setCatalogForm({ ...catalogForm, inventory: e.target.value })} /><button className="btn-primary" onClick={() => create('catalog_items', { name: catalogForm.name, kind: catalogForm.kind, price_cents: Math.round(Number(catalogForm.price) * 100), minimum_price_cents: catalogForm.kind === 'donation' ? Math.round(Number(catalogForm.price) * 100) : null, inventory_quantity: catalogForm.inventory ? Number(catalogForm.inventory) : null }, () => setCatalogForm(emptyCatalog))}><Plus className="h-4 w-4" /> Add</button></div>
      <div className="mt-4 divide-y divide-neutral-100">{catalog.map(item => <div key={item.id} className="flex items-center justify-between py-3 text-sm"><span><strong>{item.name}</strong> · {item.kind.replace('_', ' ')} · ${(item.price_cents / 100).toFixed(2)} · {item.quantity_remaining ?? 'unlimited'} left</span><button onClick={() => remove('catalog_items', item.id)}><Trash2 className="h-4 w-4 text-red-500" /></button></div>)}</div>
    </Section>

    <Section title="Registration and waivers" description="Required answers and exact waiver versions are snapshotted on every order.">
      <div className="grid gap-2 sm:grid-cols-5"><input className="input sm:col-span-2" placeholder="Question" value={questionForm.prompt} onChange={e => setQuestionForm({ ...questionForm, prompt: e.target.value })} /><select className="input" value={questionForm.kind} onChange={e => setQuestionForm({ ...questionForm, kind: e.target.value })}><option value="short_text">Short text</option><option value="long_text">Long text</option><option value="selection">Selection</option><option value="checkbox">Checkbox</option></select><input className="input" placeholder="Choices, comma separated" disabled={questionForm.kind !== 'selection'} value={questionForm.options} onChange={e => setQuestionForm({ ...questionForm, options: e.target.value })} /><button className="btn-primary" onClick={() => create('registration_questions', { prompt: questionForm.prompt, kind: questionForm.kind, required: questionForm.required, options: questionForm.options.split(',').map(value => value.trim()).filter(Boolean) }, () => setQuestionForm(emptyQuestion))}>Add question</button></div>
      <label className="mt-2 flex items-center gap-2 text-sm"><input type="checkbox" checked={questionForm.required} onChange={e => setQuestionForm({ ...questionForm, required: e.target.checked })} /> Required question</label>
      <div className="mt-3 flex flex-wrap gap-2">{questions.map(item => <span key={item.id} className="rounded-full bg-neutral-100 px-3 py-1.5 text-xs">{item.prompt}{item.required ? ' *' : ''} <button onClick={() => remove('registration_questions', item.id)} className="ml-1 text-red-500">×</button></span>)}</div>
      <div className="mt-6 grid gap-2 sm:grid-cols-4"><input className="input" placeholder="Waiver title" value={waiverForm.title} onChange={e => setWaiverForm({ ...waiverForm, title: e.target.value })} /><input className="input" placeholder="Version" value={waiverForm.version} onChange={e => setWaiverForm({ ...waiverForm, version: e.target.value })} /><textarea className="input" placeholder="Waiver text" value={waiverForm.body} onChange={e => setWaiverForm({ ...waiverForm, body: e.target.value })} /><button className="btn-primary" onClick={() => create('event_waivers', waiverForm, () => setWaiverForm(emptyWaiver))}>Add waiver</button></div>
      <div className="mt-3 flex flex-wrap gap-2">{waivers.map(item => <span key={item.id} className="rounded-full bg-neutral-100 px-3 py-1.5 text-xs">{item.title} v{item.version} <button onClick={() => remove('event_waivers', item.id)} className="ml-1 text-red-500">×</button></span>)}</div>
    </Section>

    <Section title="Promoters and referral commission" description="Referral codes attribute orders and commission entries reverse automatically with refunds.">
      <div className="grid gap-2 sm:grid-cols-5"><input className="input" placeholder="Name" value={promoterForm.name} onChange={e => setPromoterForm({ ...promoterForm, name: e.target.value })} /><input className="input" placeholder="Email" value={promoterForm.email} onChange={e => setPromoterForm({ ...promoterForm, email: e.target.value })} /><input className="input uppercase" placeholder="Code" value={promoterForm.code} onChange={e => setPromoterForm({ ...promoterForm, code: e.target.value.toUpperCase() })} /><input className="input" type="number" placeholder="Commission %" value={promoterForm.commission} onChange={e => setPromoterForm({ ...promoterForm, commission: e.target.value })} /><button className="btn-primary" onClick={() => create('promoters', { name: promoterForm.name, email: promoterForm.email, code: promoterForm.code, commission_bps: Math.round(Number(promoterForm.commission) * 100) }, () => setPromoterForm(emptyPromoter))}>Add promoter</button></div>
      <div className="mt-4 divide-y divide-neutral-100">{promoters.map(item => <div key={item.id} className="flex items-center justify-between py-3 text-sm"><span><strong>{item.name}</strong> · <code>{item.code}</code> · {item.attributed_orders} orders · ${(item.net_commission_cents / 100).toFixed(2)} net</span><button onClick={() => remove('promoters', item.id)}><Trash2 className="h-4 w-4 text-red-500" /></button></div>)}</div>
    </Section>

    <Section title="CRM and attendee communication" description="Export current attendee data and send a durable, suppression-aware event message to a defined segment.">
      <div className="mb-4 flex flex-wrap items-center gap-3 text-sm"><span>{segments?.all_attendees || 0} active recipients</span><span>{segments?.checked_in || 0} checked in</span><span>{segments?.not_checked_in || 0} not checked in</span><button className="btn-secondary ml-auto inline-flex" onClick={downloadExport}><Download className="h-4 w-4" /> Export CSV</button></div>
      <div className="grid gap-2 sm:grid-cols-2"><input className="input" placeholder="Internal campaign name" value={campaignForm.name} onChange={e => setCampaignForm({ ...campaignForm, name: e.target.value })} /><input className="input" placeholder="Email subject" value={campaignForm.subject} onChange={e => setCampaignForm({ ...campaignForm, subject: e.target.value })} /><select className="input" value={campaignForm.segment} onChange={e => setCampaignForm({ ...campaignForm, segment: e.target.value })}><option value="all_attendees">All attendees</option><option value="checked_in">Checked in</option><option value="not_checked_in">Not checked in</option></select><input className="input" type="datetime-local" value={campaignForm.scheduled_at} onChange={e => setCampaignForm({ ...campaignForm, scheduled_at: e.target.value })} /><textarea className="input sm:col-span-2" rows="4" placeholder="Message" value={campaignForm.body} onChange={e => setCampaignForm({ ...campaignForm, body: e.target.value })} /><button className="btn-primary sm:col-span-2" onClick={() => create('communication_campaigns', { name: campaignForm.name, subject: campaignForm.subject, body: campaignForm.body, segment: { type: campaignForm.segment }, scheduled_at: campaignForm.scheduled_at || null }, () => setCampaignForm(emptyCampaign))}>Save campaign</button></div>
      <div className="mt-4 divide-y divide-neutral-100">{campaigns.map(item => <div key={item.id} className="flex items-center justify-between py-3 text-sm"><span><strong>{item.name}</strong> · {item.status} · {item.recipient_count} recipients</span>{['draft', 'scheduled'].includes(item.status) && <button className="inline-flex items-center gap-1 font-semibold text-brand-600" onClick={async () => { await apiClient.post(`/organizer/events/${eventId}/communication_campaigns/${item.id}/send_now`); await load() }}><Send className="h-4 w-4" /> Send now</button>}</div>)}</div>
    </Section>
  </div>
}
