import { useEffect, useId, useMemo, useState } from 'react'
import { ArrowDown, ArrowUp, Plus, X } from 'lucide-react'
import { adminLabel } from './adminLabels'

const resultLimit = 8
const searchDelayMs = 250
const iconButton = 'flex h-11 w-11 shrink-0 items-center justify-center rounded-lg text-neutral-600 transition-[background-color,transform] duration-150 ease-out hover:bg-neutral-200 active:scale-[0.97] disabled:opacity-30 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus'

// Builds the ordered event id list for a curated collection. `events` is the first page
// the admin page already loaded; typed queries go to the server through `searchEvents`,
// so events beyond that page can still be added.
export default function CollectionEventPicker({ events, value, onChange, searchEvents }) {
  const [query, setQuery] = useState('')
  const [found, setFound] = useState({ term: '', events: [], failed: false })
  const [picked, setPicked] = useState(() => new Map())
  const searchId = useId()
  const term = query.trim()

  useEffect(() => {
    if (!term) return undefined
    const controller = new AbortController()
    const timer = setTimeout(() => {
      searchEvents(term, controller.signal)
        .then(results => setFound({ term, events: results, failed: false }))
        .catch(() => { if (!controller.signal.aborted) setFound({ term, events: [], failed: true }) })
    }, searchDelayMs)
    return () => { clearTimeout(timer); controller.abort() }
  }, [term, searchEvents])

  // Titles for selected events come from anything seen so far, so they survive new searches.
  const known = useMemo(() => new Map([...events.map(event => [event.id, event]), ...picked]), [events, picked])
  const selected = value.map(id => known.get(id) || { id, title: `Event #${id}` })
  const searching = Boolean(term) && found.term !== term
  const candidates = term ? (searching ? [] : found.events) : events
  const matches = candidates.filter(event => !value.includes(event.id))

  const add = event => {
    setPicked(current => new Map(current).set(event.id, event))
    onChange([...value, event.id])
  }
  const remove = id => onChange(value.filter(item => item !== id))
  const move = (index, offset) => {
    const next = [...value]
    ;[next[index], next[index + offset]] = [next[index + offset], next[index]]
    onChange(next)
  }

  let emptyMessage = 'No matching events.'
  if (searching) emptyMessage = 'Searching…'
  else if (term && found.failed) emptyMessage = 'Search failed. Check your connection and try again.'
  else if (!term && events.length === 0) emptyMessage = 'No events are available yet.'

  return (
    <fieldset className="space-y-3">
      <legend className="text-sm font-medium">Events (in display order)</legend>
      {selected.length === 0 ? (
        <p className="rounded-lg border border-dashed border-neutral-300 px-3 py-4 text-sm text-content-muted">No events added yet. Search below and add them in the order buyers should see them.</p>
      ) : (
        <ol aria-label="Collection events" className="space-y-1">
          {selected.map((event, index) => (
            <li key={event.id} className="flex items-center gap-1 rounded-lg bg-neutral-50 py-1 pl-3 pr-1 text-sm">
              <span className="w-5 shrink-0 text-xs font-semibold text-content-muted">{index + 1}</span>
              <span className="min-w-0 flex-1 break-words font-medium text-neutral-900">{event.title}</span>
              <button type="button" aria-label={`Move ${event.title} up`} disabled={index === 0} onClick={() => move(index, -1)} className={iconButton}><ArrowUp aria-hidden="true" className="h-4 w-4" /></button>
              <button type="button" aria-label={`Move ${event.title} down`} disabled={index === selected.length - 1} onClick={() => move(index, 1)} className={iconButton}><ArrowDown aria-hidden="true" className="h-4 w-4" /></button>
              <button type="button" aria-label={`Remove ${event.title}`} onClick={() => remove(event.id)} className={iconButton}><X aria-hidden="true" className="h-4 w-4" /></button>
            </li>
          ))}
        </ol>
      )}
      <div>
        <label htmlFor={searchId} className="block text-sm font-medium">Search events to add</label>
        <input id={searchId} type="search" className="input mt-1" value={query} placeholder="Event title"
          onChange={event => setQuery(event.target.value)}
          onKeyDown={event => { if (event.key === 'Enter') { event.preventDefault(); if (matches[0]) add(matches[0]) } }} />
      </div>
      <ul aria-label="Events available to add" aria-busy={searching} className="max-h-56 space-y-1 overflow-auto">
        {matches.slice(0, resultLimit).map(event => (
          <li key={event.id} className="flex items-center gap-2 rounded-lg border border-neutral-200 py-1 pl-3 pr-1 text-sm">
            <span className="min-w-0 flex-1">
              <span className="block break-words font-medium text-neutral-900">{event.title}</span>
              <span className="block text-xs text-content-muted">{[event.organizer_name, adminLabel(event.status)].filter(Boolean).join(' · ')}</span>
            </span>
            <button type="button" aria-label={`Add ${event.title}`} onClick={() => add(event)} className={iconButton}><Plus aria-hidden="true" className="h-4 w-4" /></button>
          </li>
        ))}
        {matches.length === 0 && <li role="status" className="px-3 py-2 text-sm text-content-muted">{emptyMessage}</li>}
        {matches.length > resultLimit && <li className="px-3 py-1 text-xs text-content-muted">Showing {resultLimit} of {matches.length}. Refine the search to find more.</li>}
      </ul>
    </fieldset>
  )
}
