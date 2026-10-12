import { useEffect, useRef, useState } from 'react'
import { recheckAdminAuthority } from '../hooks/usePlatformContext'

export default function AdminAccessRecovery({ identity }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const active = useRef(false)
  useEffect(() => { active.current = true; return () => { active.current = false } }, [])
  const retry = async () => {
    if (busy) return
    setBusy(true); setError('')
    try { await recheckAdminAuthority(identity.authContext, identity.authorityGeneration) }
    catch (failure) { if (active.current) setError(failure.response?.data?.error || failure.message || 'Administrator access could not be verified. Please try again.') }
    finally { if (active.current) setBusy(false) }
  }
  return <section className="mx-auto max-w-lg px-4 py-8" role="alert">
    <h2 className="text-lg font-semibold text-neutral-900">Administrator access needs to be verified</h2>
    <p className="mt-2 text-neutral-600">Private records and review controls have been closed. Verify your current access before continuing.</p>
    <button type="button" disabled={busy} onClick={retry} className="btn-primary mt-4">{busy ? 'Checking administrator access…' : 'Retry administrator access'}</button>
    {error && <p className="mt-3 text-sm text-red-700">{error}</p>}
  </section>
}
