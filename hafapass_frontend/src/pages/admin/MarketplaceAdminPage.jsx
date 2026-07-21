import { useCallback, useEffect, useState } from 'react'
import { Copy, Loader2, Plus } from 'lucide-react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'

const blankCollection = { title: '', description: '', status: 'draft', event_ids: '' }
const blankVenue = { name: '', address: '', village: '', verified: false }
const blankPartner = { name: '', kind: 'hotel' }
const blankLink = { distribution_partner_id: '', event_id: '', campaign: '' }

export default function MarketplaceAdminPage() {
  const [data, setData] = useState(null); const [events, setEvents] = useState([])
  const [collections, setCollections] = useState([]); const [partners, setPartners] = useState([]); const [links, setLinks] = useState([]); const [venues, setVenues] = useState([])
  const [collection, setCollection] = useState(blankCollection); const [venue, setVenue] = useState(blankVenue); const [partner, setPartner] = useState(blankPartner); const [link, setLink] = useState(blankLink)
  const [message, setMessage] = useState('')
  const load = useCallback(() => Promise.all([
    apiClient.get('/admin/marketplace'), apiClient.get('/admin/events', { params: { per_page: 100 } }),
    apiClient.get('/admin/marketplace_collections'), apiClient.get('/admin/distribution_partners'),
    apiClient.get('/admin/distribution_links'), apiClient.get('/admin/venues'),
  ]).then(([summary, eventData, collectionData, partnerData, linkData, venueData]) => {
    setData(summary.data); setEvents(eventData.data.events); setCollections(collectionData.data.collections)
    setPartners(partnerData.data.distribution_partners); setLinks(linkData.data.distribution_links); setVenues(venueData.data.venues)
  }), [])
  useEffect(() => { load().catch(() => setMessage('Unable to load marketplace controls.')) }, [load])
  const submit = async (endpoint, payload, reset) => { try { await apiClient.post(endpoint, payload); reset(); setMessage('Saved.'); await load() } catch (error) { setMessage(error.response?.data?.errors?.join(', ') || 'Unable to save.') } }
  if (!data) return <AdminLayout><Loader2 className="mx-auto mt-16 h-8 w-8 animate-spin text-brand-500" /></AdminLayout>
  return <AdminLayout><div className="flex items-end justify-between"><div><h2 className="text-2xl font-bold">Marketplace & distribution</h2><p className="mt-1 text-neutral-500">Govern curated supply and measure partner conversion without customer identity data.</p></div></div>
    {message && <p role="status" className="mt-4 rounded-xl bg-neutral-100 px-4 py-3 text-sm">{message}</p>}
    <div className="mt-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">{[['Purchasable events', data.supply.purchasable_upcoming], ['Unavailable events', data.supply.sold_out_or_unavailable], ['Empty collections', data.supply.empty_collections], ['Checkout conversion', `${data.checkout_conversion_percent}%`]].map(([label, value]) => <div key={label} className="rounded-2xl border bg-white p-5"><p className="text-sm text-neutral-500">{label}</p><p className="mt-1 text-3xl font-bold">{value}</p></div>)}</div>
    <div className="mt-8 grid gap-6 lg:grid-cols-2">
      <AdminForm title="Curated collection" onSubmit={() => submit('/admin/marketplace_collections', { ...collection, event_ids: collection.event_ids.split(',').map(value => Number(value.trim())).filter(Boolean) }, () => setCollection(blankCollection))}><Field label="Title" value={collection.title} onChange={title => setCollection({ ...collection, title })} /><Field label="Description" value={collection.description} onChange={description => setCollection({ ...collection, description })} /><Field label="Event IDs (in order)" value={collection.event_ids} onChange={event_ids => setCollection({ ...collection, event_ids })} /><select className="input" value={collection.status} onChange={e => setCollection({ ...collection, status: e.target.value })}><option value="draft">Draft</option><option value="published">Published</option></select><RecordList items={collections} render={item => `${item.title} · ${item.status} · ${item.visible_event_count} events`} /></AdminForm>
      <AdminForm title="Verified venue" onSubmit={() => submit('/admin/venues', venue, () => setVenue(blankVenue))}><Field label="Name" value={venue.name} onChange={name => setVenue({ ...venue, name })} /><Field label="Address" value={venue.address} onChange={address => setVenue({ ...venue, address })} /><Field label="Village" value={venue.village} onChange={village => setVenue({ ...venue, village })} /><label className="flex gap-2 text-sm"><input type="checkbox" checked={venue.verified} onChange={e => setVenue({ ...venue, verified: e.target.checked })} />Verified</label><RecordList items={venues} render={item => `${item.name} · ${item.village} · ${item.upcoming_event_count} events`} /></AdminForm>
      <AdminForm title="Distribution partner" onSubmit={() => submit('/admin/distribution_partners', partner, () => setPartner(blankPartner))}><Field label="Name" value={partner.name} onChange={name => setPartner({ ...partner, name })} /><select className="input" value={partner.kind} onChange={e => setPartner({ ...partner, kind: e.target.value })}>{['hotel','concierge','tourism','ambros','promoter'].map(kind => <option key={kind}>{kind}</option>)}</select><RecordList items={partners} render={item => `${item.name} · ${item.kind}`} /></AdminForm>
      <AdminForm title="Trackable partner link" onSubmit={() => submit('/admin/distribution_links', link, () => setLink(blankLink))}><select className="input" value={link.distribution_partner_id} onChange={e => setLink({ ...link, distribution_partner_id: e.target.value })}><option value="">Choose partner</option>{partners.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select><select className="input" value={link.event_id} onChange={e => setLink({ ...link, event_id: e.target.value })}><option value="">Choose event</option>{events.map(item => <option key={item.id} value={item.id}>{item.title}</option>)}</select><Field label="Campaign" value={link.campaign} onChange={campaign => setLink({ ...link, campaign })} /><div className="space-y-2">{links.map(item => <button key={item.id} type="button" className="flex w-full items-center justify-between rounded-lg bg-neutral-50 p-2 text-left text-xs" onClick={() => navigator.clipboard.writeText(item.url)}><span>{item.partner.name} → {item.event.title}</span><Copy className="h-3.5 w-3.5" /></button>)}</div></AdminForm>
    </div>
    <section className="mt-8 rounded-2xl border bg-white p-6"><h3 className="font-bold">Privacy-safe attribution</h3><div className="mt-3 overflow-x-auto"><table className="w-full text-left text-sm"><thead><tr><th>Source</th><th>Medium</th><th>Campaign</th><th>Orders</th><th>Gross order value</th></tr></thead><tbody>{data.attribution.map((row, index) => <tr key={index} className="border-t"><td className="py-2">{row.source}</td><td>{row.medium}</td><td>{row.campaign || '—'}</td><td>{row.orders}</td><td>${(row.gross_order_value_cents / 100).toFixed(2)}</td></tr>)}</tbody></table></div></section>
  </AdminLayout>
}

function AdminForm({ title, onSubmit, children }) { return <form className="space-y-3 rounded-2xl border bg-white p-6" onSubmit={e => { e.preventDefault(); onSubmit() }}><h3 className="text-lg font-bold">{title}</h3>{children}<button className="btn-primary inline-flex items-center gap-2"><Plus className="h-4 w-4" />Add</button></form> }
function Field({ label, value, onChange }) { return <label className="block text-sm font-medium">{label}<input className="input mt-1" value={value} onChange={e => onChange(e.target.value)} required /></label> }
function RecordList({ items, render }) { return <div className="max-h-32 space-y-1 overflow-auto">{items.map(item => <div key={item.id} className="rounded-lg bg-neutral-50 px-3 py-2 text-xs">{render(item)}</div>)}</div> }
