import { useCallback, useEffect, useState } from 'react'
import apiClient from '../../api/client'
import { usePlatformRequests } from '../../hooks/usePlatformContext'
import AdminLayout from './AdminLayout'
import AdminSessionGate from './AdminSessionGate'

const SCOPES = ['organization', 'event', 'order', 'user', 'buyer_email']

function AdminPrivacySession({ identity, resourcePath }) {
  const { beginRequest } = usePlatformRequests(identity, resourcePath)
  const [requests, setRequests] = useState([])
  const [holds, setHolds] = useState([])
  const [selected, setSelected] = useState(null)
  const [scope, setScope] = useState('order')
  const [value, setValue] = useState('')
  const [reason, setReason] = useState('')
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [busy, setBusy] = useState(false)
  const load = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    try {
      const [queue, legal] = await Promise.all([
        apiClient.get('/admin/privacy_requests', request.config), apiClient.get('/admin/legal_holds', request.config),
      ])
      if (request.current()) { setRequests(queue.data.requests || []); setHolds(legal.data.holds || []) }
    } catch (failure) {
      if (request.current() && !request.handleError(failure)) setError('Privacy queue could not be loaded.')
    } finally { request.release() }
  }, [beginRequest])
  useEffect(() => { load() }, [load])
  const choose = async id => {
    const request = beginRequest()
    if (!request) return
    try {
      const response = await apiClient.get(`/admin/privacy_requests/${id}`, request.config)
      if (request.current()) setSelected(response.data)
    } catch (failure) {
      if (request.current() && !request.handleError(failure)) setError('Preview could not be loaded.')
    } finally { request.release() }
  }
  const act = async (path, payload = {}) => {
    const request = beginRequest()
    if (!request) return
    setBusy(true); setError(''); setNotice('')
    try {
      await apiClient.post(path, payload, request.config)
      if (request.current()) { setNotice('Saved.'); await load(); if (selected) await choose(selected.request.id) }
      return true
    } catch (failure) {
      if (request.current() && !request.handleError(failure)) setError(failure.response?.data?.error || failure.response?.data?.errors?.join('; ') || 'Action failed.')
      return false
    } finally { request.release(); setBusy(false) }
  }
  const place = async event => {
    event.preventDefault()
    if (await act('/admin/legal_holds', { scope_type: scope, scope_value: value, reason })) {
      setValue(''); setReason('')
    }
  }
  const download = async () => {
    const request = beginRequest()
    if (!request || !selected) return
    try {
      const response = await apiClient.get(`/admin/privacy_requests/${selected.request.id}/export`,
        { ...request.config, responseType: 'blob' })
      if (!request.current()) return
      const url = URL.createObjectURL(response.data)
      const link = document.createElement('a')
      link.href = url
      link.download = `hafapass-data-${selected.request.id}.json`
      link.click()
      setTimeout(() => URL.revokeObjectURL(url), 1000)
    } catch (failure) {
      if (request.current() && !request.handleError(failure)) setError('Export could not be downloaded.')
    } finally { request.release() }
  }
  return <AdminLayout>
    <p className="mb-5 max-w-3xl text-sm text-content-muted">Verify identity, review the exact action plan, and resolve blockers before executing a request. Holds pause deletion and scheduled disposal.</p>
    {error && <p role="alert" className="mb-4 rounded-lg bg-red-50 p-3 text-sm text-red-800">{error}</p>}
    {notice && <p role="status" className="mb-4 rounded-lg bg-emerald-50 p-3 text-sm text-emerald-900">{notice}</p>}
    <div className="grid gap-6 xl:grid-cols-2">
      <section className="rounded-xl border border-neutral-200 bg-white p-5">
        <h2 className="text-lg font-semibold">Requests</h2>
        {requests.length ? <ul className="mt-4 divide-y divide-neutral-200">{requests.map(item => <li key={item.id} className="py-3">
          <button type="button" onClick={() => choose(item.id)} className="min-h-11 w-full text-left text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus">
            <span className="font-semibold capitalize">{item.kind} #{item.id}</span> · {item.status.replaceAll('_', ' ')}
            <span className="mt-1 block break-all text-content-muted">{item.requester_email}</span>
          </button>
        </li>)}</ul> : <p className="mt-3 text-sm text-content-muted">No requests.</p>}
      </section>
      <section className="rounded-xl border border-neutral-200 bg-white p-5" aria-label="Request preview">
        <h2 className="text-lg font-semibold">Request preview</h2>
        {selected ? <div className="mt-4 space-y-4 text-sm">
          <p className="font-medium capitalize">{selected.request.kind} #{selected.request.id} · {selected.request.status.replaceAll('_', ' ')}</p>
          {selected.preview.blockers.length > 0 && <div role="alert" className="rounded-lg bg-amber-50 p-3 text-amber-900"><strong>Blocked:</strong><ul className="mt-1 list-disc pl-5">{selected.preview.blockers.map(item => <li key={item}>{item}</li>)}</ul></div>}
          <div><h3 className="font-semibold">Retained and anonymized</h3><ul className="mt-1 space-y-2">{selected.preview.retained.map(item => <li key={item.table}>{item.table}: {item.count} · {item.reason}</li>)}</ul></div>
          <div><h3 className="font-semibold">Deleted</h3><ul className="mt-1 space-y-2">{selected.preview.deleted.map(item => <li key={item.table}>{item.table}: {item.count} · {item.reason}</li>)}</ul></div>
          <div className="flex flex-wrap gap-2">
            {!selected.request.verified_at && <button type="button" disabled={busy} onClick={() => act(`/admin/privacy_requests/${selected.request.id}/verify`)} className="btn-secondary">Verify identity</button>}
            {selected.request.verified_at && !selected.request.executed_at && <button type="button" disabled={busy || selected.preview.blockers.length > 0} onClick={() => act(`/admin/privacy_requests/${selected.request.id}/execute`)} className="btn-primary">Execute request</button>}
            {selected.request.kind === 'access' && selected.request.verified_at && <button type="button" onClick={download} className="btn-secondary">Download JSON</button>}
          </div>
          {selected.request.result?.manual_steps?.length > 0 && <p className="rounded-lg bg-amber-50 p-3">Manual completion: {selected.request.result.manual_steps.join(', ')}</p>}
        </div> : <p className="mt-3 text-sm text-content-muted">Select a request to inspect it.</p>}
      </section>
    </div>
    <section className="mt-6 rounded-xl border border-neutral-200 bg-white p-5">
      <h2 className="text-lg font-semibold">Legal holds</h2>
      <form onSubmit={place} className="mt-4 grid gap-3 sm:grid-cols-2">
        <label className="text-sm font-medium">Scope<select value={scope} onChange={event => setScope(event.target.value)} className="input mt-1">{SCOPES.map(item => <option key={item} value={item}>{item.replaceAll('_', ' ')}</option>)}</select></label>
        <label className="text-sm font-medium">ID or buyer email<input required value={value} onChange={event => setValue(event.target.value)} className="input mt-1" /></label>
        <label className="text-sm font-medium sm:col-span-2">Reason<textarea required minLength={10} maxLength={2000} value={reason} onChange={event => setReason(event.target.value)} className="input mt-1" rows={3} /></label>
        <button type="submit" disabled={busy} className="btn-primary justify-self-start">Place hold</button>
      </form>
      {holds.length ? <ul className="mt-5 divide-y divide-neutral-200">{holds.map(hold => <li key={hold.id} className="flex flex-wrap items-center justify-between gap-3 py-3 text-sm">
        <span className="break-all"><strong>{hold.scope_type}</strong> {hold.scope_value} · {hold.reason} {hold.released_at && '(released)'}</span>
        {!hold.released_at && <button type="button" disabled={busy} onClick={() => act(`/admin/legal_holds/${hold.id}/release`)} className="btn-secondary">Release</button>}
      </li>)}</ul> : <p className="mt-3 text-sm text-content-muted">No holds.</p>}
    </section>
  </AdminLayout>
}

export default function AdminPrivacyPage() {
  return <AdminSessionGate resourcePath="/admin/privacy" Session={AdminPrivacySession} />
}
