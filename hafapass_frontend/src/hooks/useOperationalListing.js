import { useState } from 'react'

// Return links may omit query parameters. Keep each account/organization's
// operational list context for this tab without sharing it with another user.
export default function useOperationalListing(scope) {
  const key = `hafapass:listing:${scope}`
  const read = () => {
    try {
      const saved = JSON.parse(window.sessionStorage.getItem(key))
      if (typeof saved?.q === 'string' && Number.isSafeInteger(saved.page) && saved.page > 0) return { ...saved, key }
    } catch { /* An unavailable store only loses convenience, never authorization. */ }
    return { key, q: '', page: 1 }
  }
  const [state, setState] = useState(read)
  if (state.key !== key) setState(read())
  const update = next => {
    setState({ ...next, key })
    try { window.sessionStorage.setItem(key, JSON.stringify(next)) } catch { /* Keep the active list usable. */ }
  }
  return { ...state, search: q => update({ q: q.trim(), page: 1 }), goToPage: page => update({ ...state, page: Math.max(1, page) }) }
}
