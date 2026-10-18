import { useEffect, useState } from 'react'

export default function OperationalSearch({ label, hint, query, onSearch, busy = false, buttonLabel = 'Search' }) {
  const [input, setInput] = useState(query)
  useEffect(() => setInput(query), [query])
  return <form role="search" className="mb-4" onSubmit={event => { event.preventDefault(); if (!busy) onSearch(input) }}>
    <label className="mb-1 block font-medium text-neutral-900" htmlFor={`search-${label.replaceAll(' ', '-')}`}>{label}</label>
    <p id={`hint-${label.replaceAll(' ', '-')}`} className="mb-2 text-sm text-neutral-600">{hint}</p>
    <div className="flex flex-wrap gap-2">
      <input id={`search-${label.replaceAll(' ', '-')}`} aria-describedby={`hint-${label.replaceAll(' ', '-')}`} type="search" value={input} maxLength={200} onChange={event => setInput(event.target.value)} className="input min-w-0 flex-[1_1_16rem] !w-full sm:!w-auto" />
      <button type="submit" disabled={busy} className="btn-secondary">{buttonLabel}</button>
      {query && <button type="button" disabled={busy} onClick={() => { setInput(''); onSearch('') }} className="btn-secondary">Clear search</button>}
    </div>
  </form>
}
