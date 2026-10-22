import { CheckCircle2, Loader2 } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import apiClient from '../api/client'
import { roleDescription, roleLabel } from '../utils/roles'

// Accepts a HåfaPass staff (Admin or Support) invitation. The API applies the
// role only when the signed-in account's verified email matches the invite.
export default function PlatformInvitationAcceptPage() {
  const [searchParams] = useSearchParams()
  const [result, setResult] = useState(null)
  const [error, setError] = useState(null)
  // A token is single use: StrictMode replays effects, so submit it once.
  const submitted = useRef(null)

  useEffect(() => {
    const token = searchParams.get('token')
    if (token && submitted.current === token) return
    submitted.current = token
    if (!token) {
      setError('This invitation link is missing its secure token. Open the link from your invitation email again.')
      return
    }
    apiClient.post('/platform_invitations/accept', { token })
      .then(response => setResult(response.data))
      .catch(requestError => setError(requestError.response?.data?.error || 'This invitation is invalid or expired.'))
  }, [searchParams])

  const role = result?.invited_role
  return (
    <main className="mx-auto max-w-lg px-4 py-20">
      <div className="rounded-2xl border border-neutral-200 bg-white p-8 text-center shadow-sm">
        {!result && !error && <><Loader2 aria-hidden="true" className="mx-auto h-8 w-8 animate-spin text-brand-600 motion-reduce:animate-none" /><h1 className="mt-4 text-xl font-bold" role="status">Accepting invitation…</h1></>}
        {error && <>
          <h1 className="text-xl font-bold text-neutral-900">Invitation unavailable</h1>
          <p role="alert" className="mt-2 text-sm text-red-700">{error}</p>
          <p className="mt-3 text-sm text-neutral-600">Sign in with the email address the invitation was sent to, or ask a HåfaPass admin to resend it.</p>
        </>}
        {result && <>
          <CheckCircle2 aria-hidden="true" className="mx-auto h-10 w-10 text-emerald-600" />
          <h1 className="mt-4 text-xl font-bold text-neutral-900">Welcome to the HåfaPass team</h1>
          <p className="mt-2 text-sm text-neutral-700">Your role: <strong>{result.role_label || roleLabel(role)}</strong> — {result.role_description || roleDescription(role)}</p>
        </>}
        {result && <Link to={result.role === 'admin' ? '/admin' : '/support'} className="btn-primary mt-6 inline-flex">{result.role === 'admin' ? 'Open admin' : 'Open support'}</Link>}
        {error && <Link to="/" className="btn-secondary mt-6 inline-flex">Back to HåfaPass</Link>}
      </div>
    </main>
  )
}
