import { CheckCircle2, Loader2 } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import { Link, useLocation, useSearchParams } from 'react-router-dom'
import apiClient, { getApiAuthContext } from '../../api/client'
import { useOrganizerIdentity } from '../../hooks/useOrganizerContext'
import { resetOrganizerOrganizations } from '../../utils/organizerOrganizations'
import { roleDescription, roleLabel } from '../../utils/roles'

export default function InvitationAcceptPage() {
  const [searchParams] = useSearchParams()
  const location = useLocation()
  const identity = useOrganizerIdentity()
  const token = searchParams.get('token')
  const visitKey = `${location.key}:${location.pathname}:${token}:${identity.accountKey}`
  const [result, setResult] = useState(null)
  const [error, setError] = useState(null)
  // A token is single use: StrictMode replays effects, so submit it once.
  const submitted = useRef(null)

  useEffect(() => {
    let active = true
    setResult(null)
    setError(null)
    if (!token) {
      setError('This invitation link is missing its secure token. Open the link from your invitation email again.')
      return
    }
    if (!identity.ready || location.pathname !== '/organization-invitations/accept') return
    const authContext = identity.authContext
    if (submitted.current?.visitKey !== visitKey) {
      const organizationId = window.localStorage.getItem('hafapass_organization_id')
      submitted.current = { visitKey, organizationId,
        promise: apiClient.post('/organization_invitations/accept', { token }, { authContext, organizationId }) }
    }
    const submission = submitted.current
    const current = () => {
      if (!active || getApiAuthContext() !== authContext) return false
      if (window.localStorage.getItem('hafapass_organization_id') !== submission.organizationId) {
        setError('You switched organizations while this invitation was being accepted. Open the invitation link again if you still need to join.')
        return false
      }
      return true
    }
    submission.promise.then(response => {
      if (!current()) return
      window.localStorage.setItem('hafapass_organization_id', response.data.organization_id.toString())
      window.dispatchEvent(new StorageEvent('storage', { key: 'hafapass_organization_id' }))
      resetOrganizerOrganizations()
      setResult(response.data)
    }).catch(requestError => {
      if (current()) setError(requestError.response?.data?.error || 'This invitation is invalid or expired.')
    })
    return () => { active = false }
  }, [token, visitKey, identity.authContext, identity.ready, location.pathname])

  const events = result?.events || []
  const eventOnly = ['box_office', 'scanner'].includes(result?.role)
  return (
    <main className="mx-auto max-w-lg px-4 py-20">
      <div className="rounded-2xl border border-neutral-200 bg-white p-8 text-center shadow-sm">
        {!result && !error && <><Loader2 aria-hidden="true" className="mx-auto h-8 w-8 animate-spin text-brand-600 motion-reduce:animate-none" /><h1 className="mt-4 text-xl font-bold" role="status">Accepting invitation…</h1></>}
        {error && <>
          <h1 className="text-xl font-bold text-neutral-900">Invitation unavailable</h1>
          <p role="alert" className="mt-2 text-sm text-red-700">{error}</p>
          <p className="mt-3 text-sm text-neutral-600">Invitations work only for the email they were sent to and expire after 7 days. Ask the person who invited you to resend it.</p>
        </>}
        {result && <>
          <CheckCircle2 aria-hidden="true" className="mx-auto h-10 w-10 text-emerald-600" />
          <h1 className="mt-4 text-xl font-bold text-neutral-900">You joined {result.organization_name}</h1>
          <p className="mt-2 text-sm text-neutral-700">Your role: <strong>{result.role_label || roleLabel(result.role)}</strong> — {result.role_description || roleDescription(result.role)}</p>
          {events.length > 0 && <p className="mt-2 text-sm text-neutral-700">You can work: {events.map(event => event.title).join(', ')}.</p>}
        </>}
        <div className="mt-6 flex flex-wrap justify-center gap-3">
          {result && eventOnly && events.length > 0 && <Link to={result.role === 'box_office' ? `/dashboard/events/${events[0].id}/box-office` : `/dashboard/scanner?event=${events[0].id}`} className="btn-primary">{result.role === 'box_office' ? 'Open box office' : 'Start scanning'}</Link>}
          <Link to="/dashboard" className={result && eventOnly && events.length > 0 ? 'btn-secondary' : 'btn-primary'}>Go to dashboard</Link>
        </div>
      </div>
    </main>
  )
}
