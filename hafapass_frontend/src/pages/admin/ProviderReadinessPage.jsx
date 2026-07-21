import { useCallback, useEffect, useState } from 'react'
import { CheckCircle2, CircleAlert, Clock3, Loader2, ShieldCheck } from 'lucide-react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'

const localDateTimeValue = date => {
  const pad = value => String(value).padStart(2, '0')
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`
}

const initialForm = () => {
  const effective = new Date()
  const expires = new Date(effective)
  expires.setMonth(expires.getMonth() + 3)
  return { evidence_reference: '', evidence_digest: '', effective_at: localDateTimeValue(effective), expires_at: localDateTimeValue(expires), controls: {} }
}

const humanize = value => value.replaceAll('_', ' ').replace(/\b\w/g, letter => letter.toUpperCase())

function StatusBadge({ item }) {
  const styles = item.enabled
    ? 'bg-emerald-50 text-emerald-800 border-emerald-200'
    : item.configured ? 'bg-amber-50 text-amber-900 border-amber-200' : 'bg-neutral-100 text-neutral-700 border-neutral-200'
  return <span className={`inline-flex rounded-full border px-2.5 py-1 text-xs font-semibold ${styles}`}>{humanize(item.status)}</span>
}

function CapabilityCard({ item, refresh }) {
  const [form, setForm] = useState(initialForm)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState(null)

  const run = async request => {
    setBusy(true); setMessage(null)
    try { await request(); setForm(initialForm()); setReason(''); await refresh() }
    catch (error) { setMessage(error.response?.data?.error || 'The evidence action failed.') }
    finally { setBusy(false) }
  }

  const submit = event => {
    event.preventDefault()
    run(() => apiClient.post(`/admin/platform_capabilities/${item.capability}/reviews`, {
      ...form,
      effective_at: new Date(form.effective_at).toISOString(),
      expires_at: new Date(form.expires_at).toISOString(),
      controls: form.controls,
    }))
  }
  const pending = item.pending_submission
  const approval = item.latest_approval
  const allControlsChecked = item.required_controls.every(control => form.controls[control])

  return (
    <section className="rounded-2xl border border-neutral-200 bg-white p-5 shadow-soft" aria-labelledby={`${item.capability}-heading`}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 id={`${item.capability}-heading`} className="text-lg font-bold text-neutral-900">{item.label}</h2>
          <p className="mt-1 text-sm text-neutral-600">Configuration {item.configured ? 'is complete' : 'is incomplete'}; credentials alone never enable this capability.</p>
        </div>
        <StatusBadge item={item} />
      </div>

      {message && <p className="mt-4 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-800" role="alert">{message}</p>}

      {pending ? (
        <div className="mt-5 space-y-3 rounded-xl border border-amber-200 bg-amber-50 p-4">
          <div className="flex gap-3"><Clock3 className="mt-0.5 h-5 w-5 shrink-0 text-amber-700" /><div><p className="font-semibold text-amber-950">Independent decision required</p><p className="text-sm text-amber-900">Admin #{pending.actor_user_id} submitted evidence {pending.evidence_reference}. A different administrator must approve it.</p></div></div>
          <label className="block text-sm font-medium text-amber-950">Decision reason (required for reject)
            <input className="input mt-1" value={reason} onChange={event => setReason(event.target.value)} />
          </label>
          <div className="flex flex-wrap gap-2">
            <button type="button" className="btn-primary" disabled={busy} onClick={() => run(() => apiClient.post(`/admin/platform_capability_reviews/${pending.id}/approve`))}>Approve exact snapshot</button>
            <button type="button" className="rounded-xl border border-red-300 px-4 py-2 text-sm font-semibold text-red-800 disabled:opacity-50" disabled={busy || !reason.trim()} onClick={() => run(() => apiClient.post(`/admin/platform_capability_reviews/${pending.id}/reject`, { reason }))}>Reject</button>
          </div>
        </div>
      ) : approval?.active ? (
        <div className="mt-5 space-y-3 rounded-xl border border-emerald-200 bg-emerald-50 p-4">
          <div className="flex gap-3"><CheckCircle2 className="mt-0.5 h-5 w-5 shrink-0 text-emerald-700" /><div><p className="font-semibold text-emerald-950">Current approval</p><p className="text-sm text-emerald-900">Evidence {approval.evidence_reference}; expires {new Date(approval.expires_at).toLocaleString()}.</p></div></div>
          <label className="block text-sm font-medium text-emerald-950">Revocation reason
            <input className="input mt-1" value={reason} onChange={event => setReason(event.target.value)} />
          </label>
          <button type="button" className="rounded-xl border border-red-300 bg-white px-4 py-2 text-sm font-semibold text-red-800 disabled:opacity-50" disabled={busy || !reason.trim()} onClick={() => run(() => apiClient.post(`/admin/platform_capability_reviews/${approval.id}/revoke`, { reason }))}>Revoke approval</button>
        </div>
      ) : (
        <form className="mt-5 space-y-4" onSubmit={submit}>
          {!item.configured && <div className="flex gap-3 rounded-xl bg-neutral-100 p-4 text-sm text-neutral-700"><CircleAlert className="h-5 w-5 shrink-0" />Complete the documented provider configuration before submitting evidence.</div>}
          <div className="grid gap-4 sm:grid-cols-2">
            <label className="text-sm font-medium text-neutral-800">Evidence reference
              <input className="input mt-1" required value={form.evidence_reference} onChange={event => setForm({ ...form, evidence_reference: event.target.value })} placeholder="Controlled record ID or URL" />
            </label>
            <label className="text-sm font-medium text-neutral-800">SHA-256 evidence digest
              <input className="input mt-1 font-mono text-xs" required pattern="[0-9a-f]{64}" value={form.evidence_digest} onChange={event => setForm({ ...form, evidence_digest: event.target.value.trim().toLowerCase() })} />
            </label>
            <label className="text-sm font-medium text-neutral-800">Effective at
              <input className="input mt-1" type="datetime-local" required value={form.effective_at} onChange={event => setForm({ ...form, effective_at: event.target.value })} />
            </label>
            <label className="text-sm font-medium text-neutral-800">Expires at
              <input className="input mt-1" type="datetime-local" required value={form.expires_at} onChange={event => setForm({ ...form, expires_at: event.target.value })} />
            </label>
          </div>
          <fieldset><legend className="text-sm font-semibold text-neutral-900">Required evidence controls</legend><div className="mt-2 grid gap-2 sm:grid-cols-2">{item.required_controls.map(control => <label key={control} className="flex items-start gap-2 rounded-lg border border-neutral-200 p-3 text-sm text-neutral-700"><input className="mt-0.5" type="checkbox" checked={form.controls[control] || false} onChange={event => setForm({ ...form, controls: { ...form.controls, [control]: event.target.checked } })} />{humanize(control)}</label>)}</div></fieldset>
          <button className="btn-primary inline-flex items-center gap-2" disabled={busy || !item.configured || !allControlsChecked}>{busy && <Loader2 className="h-4 w-4 animate-spin" />}Submit immutable evidence</button>
        </form>
      )}
    </section>
  )
}

export default function ProviderReadinessPage() {
  const [items, setItems] = useState(null)
  const [error, setError] = useState(null)
  const refresh = useCallback(async () => {
    try { const response = await apiClient.get('/admin/platform_capabilities'); setItems(response.data.capabilities); setError(null) }
    catch { setError('Unable to load provider readiness.') }
  }, [])
  useEffect(() => { refresh() }, [refresh])

  return <AdminLayout><div className="mb-6 flex items-start gap-3"><ShieldCheck className="mt-1 h-7 w-7 text-brand-600" /><div><h2 className="text-2xl font-bold text-neutral-900">Provider and policy readiness</h2><p className="mt-1 max-w-3xl text-neutral-600">Credentials show that an integration can connect. Independent, current evidence determines whether HafaPass may use it in production.</p></div></div>{error && <p className="rounded-xl bg-red-50 p-4 text-red-800" role="alert">{error}</p>}{!items && !error ? <Loader2 className="mx-auto mt-16 h-8 w-8 animate-spin text-brand-500" /> : <div className="space-y-5">{items?.map(item => <CapabilityCard key={item.capability} item={item} refresh={refresh} />)}</div>}</AdminLayout>
}
