import { useTranslation } from 'react-i18next'
import { useCallback, useEffect, useState } from 'react'
import { Link, useLocation, useParams } from 'react-router-dom'
import apiClient from '../api/client'
import { getOrderAccess } from '../utils/orderAccess'
import { usePlatformIdentity, usePlatformRequests, usePlatformVisit } from '../hooks/usePlatformContext'

function RequestForm({ submit, pending, notice, error, guest = false }) {
  const { t } = useTranslation()
  return <section className="rounded-xl border border-neutral-200 bg-white p-5 sm:p-6">
    <h1 className="text-2xl font-semibold text-neutral-900">{t('buyerAccount.privacyRequests.title')}</h1>
    <p className="mt-2 max-w-2xl text-sm text-neutral-700">{t('buyerAccount.privacyRequests.intro')}</p>
    {guest && <p className="mt-3 text-sm text-neutral-700">{t('buyerAccount.privacyRequests.guestScope')}</p>}
    {error && <p role="alert" className="mt-4 rounded-lg bg-red-50 p-3 text-sm text-red-800">{error}</p>}
    {notice && <p role="status" className="mt-4 rounded-lg bg-emerald-50 p-3 text-sm text-emerald-900">{notice}</p>}
    <div className="mt-5 flex flex-wrap gap-3">
      <button type="button" disabled={pending} onClick={() => submit('access')} className="btn-secondary">{t('buyerAccount.privacyRequests.requestData')}</button>
      <button type="button" disabled={pending} onClick={() => submit('deletion')} className="btn-primary">{t('buyerAccount.privacyRequests.requestDeletion')}</button>
    </div>
    <p className="mt-4 text-xs text-content-muted">{t('buyerAccount.privacyRequests.processingNote')}</p>
  </section>
}

function AccountSession({ identity, resourcePath }) {
  const { t } = useTranslation()
  const { beginRequest } = usePlatformRequests(identity, resourcePath)
  const [requests, setRequests] = useState(null)
  const [loadError, setLoadError] = useState(false)
  const [loading, setLoading] = useState(true)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const load = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    setLoading(true)
    setLoadError(false)
    try {
      const response = await apiClient.get('/me/privacy_requests', request.config)
      if (request.current()) setRequests(response.data.requests || [])
    } catch {
      if (request.current()) setLoadError(true)
    } finally { if (request.current()) setLoading(false); request.release() }
  }, [beginRequest])
  useEffect(() => { load() }, [load])
  const submit = async kind => {
    const request = beginRequest()
    if (!request) return
    setPending(true); setError(''); setNotice('')
    try {
      await apiClient.post('/me/privacy_requests', { kind }, request.config)
      if (request.current()) { setNotice(t('buyerAccount.privacyRequests.submitted')); await load() }
    } catch (failure) {
      if (request.current()) setError(failure.response?.data?.error || t('buyerAccount.privacyRequests.submitFailed'))
    } finally { request.release(); setPending(false) }
  }
  return <main className="mx-auto max-w-3xl space-y-6 px-4 py-8 sm:px-6">
    <RequestForm submit={submit} pending={pending} notice={notice} error={error} />
    <section className="rounded-xl border border-neutral-200 bg-white p-5 sm:p-6">
      <h2 className="font-semibold text-neutral-900">{t('buyerAccount.privacyRequests.yourRequests')}</h2>
      {loading ? <p role="status" className="mt-3 text-sm text-content-muted">{t('buyerAccount.privacyRequests.loading')}</p>
        : loadError ? <div className="mt-3"><p role="alert" className="text-sm text-red-700">{t('buyerAccount.privacyRequests.loadError')}</p><button type="button" className="btn-secondary mt-3" onClick={load}>{t('buyerAccount.privacyRequests.tryAgain')}</button></div>
        : requests?.length ? <ul className="mt-4 divide-y divide-neutral-200">{requests.map(item => <li key={item.id} className="flex flex-wrap justify-between gap-2 py-3 text-sm"><span>{t(item.kind === 'deletion' ? 'buyerAccount.privacyRequests.deletionRequest' : 'buyerAccount.privacyRequests.accessRequest', { id: item.id })}</span><span>{t(`buyerAccount.privacyRequests.status_${item.status}`, { defaultValue: item.status.replaceAll('_', ' ') })}</span></li>)}</ul>
        : <p className="mt-3 text-sm text-content-muted">{t('buyerAccount.privacyRequests.empty')}</p>}
    </section>
    <Link to="/my-tickets" className="text-sm font-semibold text-brand-700 underline">{t('buyerAccount.privacyRequests.backToMyTickets')}</Link>
  </main>
}

export default function PrivacyRequestsPage() {
  const { t } = useTranslation()
  const resourcePath = useLocation().pathname
  const identity = usePlatformIdentity()
  const visit = usePlatformVisit(resourcePath)
  if (!visit.active) return null
  if (!identity.ready) return <p role="status" className="p-6">{t('buyerAccount.privacyRequests.checkingAccount')}</p>
  return <AccountSession key={`${identity.accountKey}:${visit.generation}`} identity={identity} resourcePath={resourcePath} />
}

export function GuestPrivacyRequestsPage() {
  const { t } = useTranslation()
  const { orderId } = useParams()
  const [pending, setPending] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [requestId, setRequestId] = useState(null)
  const [code, setCode] = useState('')
  const token = getOrderAccess(orderId)
  const submit = async kind => {
    if (!token) { setError(t('buyerAccount.privacyRequests.openSecureLinkFirst')); return }
    setPending(true); setError(''); setNotice('')
    try {
      const response = await apiClient.post('/guest_privacy_requests', { kind, order_id: orderId, guest_token: token })
      setRequestId(response.data.id)
      setNotice(t('buyerAccount.privacyRequests.codeSent'))
    } catch (failure) {
      setError(failure.response?.data?.error || t('buyerAccount.privacyRequests.guestSubmitFailed'))
    } finally { setPending(false) }
  }
  const verify = async event => {
    event.preventDefault()
    setPending(true); setError('')
    try {
      await apiClient.post(`/guest_privacy_requests/${requestId}/verify`, { code })
      setNotice(t('buyerAccount.privacyRequests.emailVerified'))
      setRequestId(null); setCode('')
    } catch (failure) {
      setError(failure.response?.data?.error || t('buyerAccount.privacyRequests.codeInvalid'))
    } finally { setPending(false) }
  }
  return <main className="mx-auto max-w-3xl space-y-4 px-4 py-8 sm:px-6"><RequestForm submit={submit} pending={pending} notice={notice}
    error={error || (!token ? t('buyerAccount.privacyRequests.openSecureLink') : '')} guest />
    {requestId && <form onSubmit={verify} className="rounded-xl border border-neutral-200 bg-white p-5">
      <label className="block text-sm font-medium">{t('buyerAccount.privacyRequests.verificationCode')}
        <input className="input mt-2" inputMode="numeric" autoComplete="one-time-code" maxLength={6}
          value={code} onChange={event => setCode(event.target.value)} required />
      </label>
      <button type="submit" className="btn-primary mt-3" disabled={pending || code.length !== 6}>{t('buyerAccount.privacyRequests.verifyEmail')}</button>
    </form>}
  </main>
}
