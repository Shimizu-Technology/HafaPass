import { useCallback, useEffect, useState } from 'react'
import { Link, useLocation, useParams } from 'react-router-dom'
import apiClient from '../api/client'
import { getOrderAccess } from '../utils/orderAccess'
import { usePlatformIdentity, usePlatformRequests, usePlatformVisit } from '../hooks/usePlatformContext'

function RequestForm({ submit, pending, notice, error, guest = false }) {
  return <section className="rounded-xl border border-neutral-200 bg-white p-5 sm:p-6">
    <h1 className="text-2xl font-semibold text-neutral-900">Your privacy choices</h1>
    <p className="mt-2 max-w-2xl text-sm text-neutral-700">Ask for a copy of your HåfaPass data or request deletion. An administrator verifies each request. Financial records may need to remain for accounting, tax, or disputes; personal details on those records are removed when deletion is allowed.</p>
    {guest && <p className="mt-3 text-sm text-neutral-700">This request covers the order in your verified email link.</p>}
    {error && <p role="alert" className="mt-4 rounded-lg bg-red-50 p-3 text-sm text-red-800">{error}</p>}
    {notice && <p role="status" className="mt-4 rounded-lg bg-emerald-50 p-3 text-sm text-emerald-900">{notice}</p>}
    <div className="mt-5 flex flex-wrap gap-3">
      <button type="button" disabled={pending} onClick={() => submit('access')} className="btn-secondary">Request my data</button>
      <button type="button" disabled={pending} onClick={() => submit('deletion')} className="btn-primary">Request deletion</button>
    </div>
    <p className="mt-4 text-xs text-content-muted">We send a confirmation to the verified email address after processing. A deletion request may be blocked while a legal hold, dispute, refund, or payout is open.</p>
  </section>
}

function AccountSession({ identity, resourcePath }) {
  const { beginRequest } = usePlatformRequests(identity, resourcePath)
  const [requests, setRequests] = useState([])
  const [pending, setPending] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const load = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    try {
      const response = await apiClient.get('/me/privacy_requests', request.config)
      if (request.current()) setRequests(response.data.requests || [])
    } catch {
      if (request.current()) setError('Requests could not be loaded. Try again.')
    } finally { request.release() }
  }, [beginRequest])
  useEffect(() => { load() }, [load])
  const submit = async kind => {
    const request = beginRequest()
    if (!request) return
    setPending(true); setError(''); setNotice('')
    try {
      await apiClient.post('/me/privacy_requests', { kind }, request.config)
      if (request.current()) { setNotice('Request submitted. You can follow its status below.'); await load() }
    } catch (failure) {
      if (request.current()) setError(failure.response?.data?.error || 'Request could not be submitted. Try again.')
    } finally { request.release(); setPending(false) }
  }
  return <main className="mx-auto max-w-3xl space-y-6 px-4 py-8 sm:px-6">
    <RequestForm submit={submit} pending={pending} notice={notice} error={error} />
    <section className="rounded-xl border border-neutral-200 bg-white p-5 sm:p-6">
      <h2 className="font-semibold text-neutral-900">Your requests</h2>
      {requests.length ? <ul className="mt-4 divide-y divide-neutral-200">{requests.map(item => <li key={item.id} className="flex flex-wrap justify-between gap-2 py-3 text-sm"><span className="capitalize">{item.kind} request #{item.id}</span><span>{item.status.replaceAll('_', ' ')}</span></li>)}</ul>
        : <p className="mt-3 text-sm text-content-muted">No requests yet.</p>}
    </section>
    <Link to="/my-tickets" className="text-sm font-semibold text-brand-700 underline">Back to my tickets</Link>
  </main>
}

export default function PrivacyRequestsPage() {
  const resourcePath = useLocation().pathname
  const identity = usePlatformIdentity()
  const visit = usePlatformVisit(resourcePath)
  if (!visit.active) return null
  if (!identity.ready) return <p role="status" className="p-6">Checking your account…</p>
  return <AccountSession key={`${identity.accountKey}:${visit.generation}`} identity={identity} resourcePath={resourcePath} />
}

export function GuestPrivacyRequestsPage() {
  const { orderId } = useParams()
  const [pending, setPending] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const token = getOrderAccess(orderId)
  const submit = async kind => {
    if (!token) { setError('Open the secure link in your order email first.'); return }
    setPending(true); setError(''); setNotice('')
    try {
      await apiClient.post('/guest_privacy_requests', { kind, order_id: orderId, guest_token: token })
      setNotice('Request submitted. We will write to the email on your order.')
    } catch (failure) {
      setError(failure.response?.data?.error || 'Request could not be submitted. Open a current order link and try again.')
    } finally { setPending(false) }
  }
  return <main className="mx-auto max-w-3xl px-4 py-8 sm:px-6"><RequestForm submit={submit} pending={pending} notice={notice}
    error={error || (!token ? 'Open the secure link in your order email to make a request.' : '')} guest /></main>
}
