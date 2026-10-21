import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import apiClient from '../api/client'

export default function UnsubscribePage() {
  const { token } = useParams()
  const [state, setState] = useState({ loading: true })
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    let active = true
    apiClient.get(`/marketing/unsubscribe/${encodeURIComponent(token)}`)
      .then(({ data }) => { if (active) setState({ organization: data.organization, unsubscribed: true }) })
      .catch(() => { if (active) setState({ error: 'This unsubscribe link could not be used.' }) })
    return () => { active = false }
  }, [token])

  async function resubscribe() {
    setBusy(true)
    try {
      await apiClient.delete(`/marketing/unsubscribe/${encodeURIComponent(token)}`)
      setState(previous => ({ ...previous, unsubscribed: false }))
    } catch {
      setState(previous => ({ ...previous, error: 'Could not resubscribe. Please try again.' }))
    } finally { setBusy(false) }
  }

  return <main className="mx-auto max-w-xl px-4 py-16 sm:py-24">
    <h1 className="text-2xl font-semibold text-neutral-900">Email preferences</h1>
    {state.loading ? <p role="status" className="mt-4">Updating your preference…</p>
      : state.error ? <p role="alert" className="mt-4 text-red-700">{state.error}</p>
        : state.unsubscribed ? <>
          <p role="status" className="mt-4">You are unsubscribed from promotional emails from {state.organization}. Ticket and order updates will still arrive.</p>
          <button type="button" disabled={busy} onClick={resubscribe} className="btn-secondary mt-6">{busy ? 'Saving…' : 'Resubscribe'}</button>
        </> : <p role="status" className="mt-4">You are resubscribed to promotional emails from {state.organization}.</p>}
  </main>
}
