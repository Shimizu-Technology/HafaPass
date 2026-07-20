import { CheckCircle2, Loader2 } from 'lucide-react'
import { useEffect, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import apiClient from '../../api/client'

export default function InvitationAcceptPage() {
  const [searchParams] = useSearchParams()
  const [result, setResult] = useState(null)
  const [error, setError] = useState(null)

  useEffect(() => {
    const token = searchParams.get('token')
    if (!token) {
      setError('This invitation link is missing its secure token.')
      return
    }
    apiClient.post('/organization_invitations/accept', { token })
      .then(response => {
        window.localStorage.setItem('hafapass_organization_id', response.data.organization_id.toString())
        setResult(response.data)
      })
      .catch(requestError => setError(requestError.response?.data?.error || 'This invitation is invalid or expired.'))
  }, [searchParams])

  return (
    <main className="mx-auto max-w-lg px-4 py-20">
      <div className="rounded-2xl border border-neutral-200 bg-white p-8 text-center shadow-sm">
        {!result && !error && <><Loader2 className="mx-auto h-8 w-8 animate-spin text-brand-600" /><h1 className="mt-4 text-xl font-bold">Accepting invitation…</h1></>}
        {error && <><h1 className="text-xl font-bold text-neutral-900">Invitation unavailable</h1><p className="mt-2 text-sm text-red-700">{error}</p></>}
        {result && <><CheckCircle2 className="mx-auto h-10 w-10 text-emerald-600" /><h1 className="mt-4 text-xl font-bold text-neutral-900">You joined {result.organization_name}</h1><p className="mt-2 text-sm text-neutral-600">Your role is {result.role.replaceAll('_', ' ')}.</p></>}
        <Link to="/dashboard" className="btn-primary mt-6 inline-flex">Go to dashboard</Link>
      </div>
    </main>
  )
}
