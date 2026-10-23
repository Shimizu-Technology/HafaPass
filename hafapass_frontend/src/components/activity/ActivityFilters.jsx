import { useEffect, useState } from 'react'
import OperationalSearch from '../OperationalSearch'

const label = value => String(value).replaceAll('_', ' ').replace(/^./, letter => letter.toUpperCase())
const allLabels = { By: 'people', Organization: 'organizations', Event: 'events', Action: 'actions', Area: 'areas', Outcome: 'outcomes', Source: 'sources' }

function Select({ title, value, options, onChange }) {
  // A deep-linked exact filter stays visible even before options are loaded.
  const choices = value && !options.some(option => String(option.value) === value)
    ? [{ value, label: `Selected: ${value}` }, ...options] : options
  return <label className="block min-w-0 text-sm font-medium text-neutral-900">{title}
    <select aria-label={title} className="input mt-1 min-w-0 !py-2" value={value} onChange={event => onChange(event.target.value)}>
      <option value="">All {allLabels[title]}</option>
      {choices.map(option => <option key={option.value} value={option.value}>{option.label}</option>)}
    </select>
  </label>
}

export default function ActivityFilters({ filters, options = {}, onChange, onClear, busy = false, admin = false, areas = [] }) {
  const [organizationSearch, setOrganizationSearch] = useState('')
  const [open, setOpen] = useState(() => window.matchMedia?.('(min-width: 768px)').matches ?? true)
  useEffect(() => {
    const media = window.matchMedia?.('(min-width: 768px)')
    if (!media) return undefined
    const changed = () => setOpen(media.matches)
    media.addEventListener('change', changed)
    return () => media.removeEventListener('change', changed)
  }, [])
  const set = name => value => onChange({ [name]: value })
  const organizations = (options.organizations || []).filter(item => item.name.toLowerCase().includes(organizationSearch.toLowerCase()))
  const filtered = Object.values(filters).some(Boolean)
  const controls = <>
    <OperationalSearch label={admin ? 'Search the audit log' : 'Search activity'} hint={admin ? 'Search activity, records or request IDs.' : 'Search what happened across your organization.'} query={filters.q || ''} onSearch={set('q')} busy={busy} />
    <div className="grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
      {admin && <div className="min-w-0 space-y-2">
        <label className="block text-sm font-medium text-neutral-900">Find organization<input type="search" className="input mt-1" value={organizationSearch} onChange={event => setOrganizationSearch(event.target.value)} placeholder="Filter organization options" /></label>
        <Select title="Organization" value={filters.organization_id || ''} options={organizations.map(item => ({ value: item.id, label: item.name }))} onChange={set('organization_id')} />
      </div>}
      <Select title="By" value={filters.actor_user_id || ''} options={(options.actors || []).map(item => ({ value: item.id, label: item.name || item.email || `Person #${item.id}` }))} onChange={set('actor_user_id')} />
      <Select title="Area" value={filters.area || ''} options={(options.areas || areas).map(value => ({ value, label: label(value) }))} onChange={set('area')} />
      <Select title="Event" value={filters.event_id || ''} options={(options.events || []).map(item => ({ value: item.id, label: item.title }))} onChange={set('event_id')} />
      {admin && <Select title="Action" value={filters.action || ''} options={(options.actions || []).map(value => ({ value, label: value }))} onChange={set('action')} />}
      <Select title="Outcome" value={filters.outcome || ''} options={['succeeded', 'requested', 'failed', 'unknown'].map(value => ({ value, label: label(value) }))} onChange={set('outcome')} />
      {admin && <Select title="Source" value={filters.source || ''} options={['user', 'system', 'provider', 'admin'].map(value => ({ value, label: label(value) }))} onChange={set('source')} />}
      <label className="block min-w-0 text-sm font-medium text-neutral-900">From<input type="date" className="input mt-1 min-w-0 !py-2" value={filters.from || ''} max={filters.to || undefined} onChange={event => set('from')(event.target.value)} /></label>
      <label className="block min-w-0 text-sm font-medium text-neutral-900">To<input type="date" className="input mt-1 min-w-0 !py-2" value={filters.to || ''} min={filters.from || undefined} onChange={event => set('to')(event.target.value)} /></label>
    </div>
    {filtered && <button type="button" onClick={() => { setOrganizationSearch(''); onClear() }} className="btn-ghost mt-3 !px-3">Clear all filters</button>}
  </>
  // A single control tree preserves input focus and avoids duplicate labels.
  return <details open={open} onToggle={event => setOpen(event.currentTarget.open)} className="mb-6 rounded-xl border border-neutral-200 bg-white p-4">
    <summary className="min-h-11 cursor-pointer content-center font-semibold text-neutral-900">Filters{filtered ? ' · applied' : ''}</summary>
    <div className="min-w-0 pt-3">{controls}</div>
  </details>
}
