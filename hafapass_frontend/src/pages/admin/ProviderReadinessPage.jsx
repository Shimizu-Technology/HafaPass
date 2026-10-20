import { useCallback, useEffect, useRef, useState } from 'react'
import { CheckCircle2, CircleAlert, Clock3, Loader2, ShieldCheck } from 'lucide-react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'
import AdminAccessRecovery from '../../components/AdminAccessRecovery'
import { usePlatformIdentity, usePlatformVisit, usePlatformRequests } from '../../hooks/usePlatformContext'

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

// Written labels for the evidence controls defined in PlatformCapabilities.
// Unknown keys fall back to sentence case so a new control still renders.
const CONTROL_LABELS = {
  territory_and_entity_approved: 'Territory and business entity approved',
  signed_webhooks_tested: 'Signed webhooks tested',
  sandbox_matrix_complete: 'Sandbox test plan complete',
  reconciliation_zero_variance: 'Reconciliation matches with no differences',
  refunds_and_disputes_tested: 'Refunds and disputes tested',
  browser_loss_and_idempotency_tested: 'Closed-browser and duplicate-request handling tested',
  domain_verified: 'Sending domain verified',
  deduplication_tested: 'Duplicate prevention tested',
  delivery_and_retry_tested: 'Delivery and retries tested',
  bounce_complaint_and_suppression_tested: 'Bounces, complaints and suppression tested',
  support_resend_tested: 'Support resend tested',
  issuer_approved: 'Issuer account approved',
  class_approved: 'Pass class approved',
  signing_tested: 'Pass signing tested',
  device_install_tested: 'Install on a real device tested',
  invalidation_behavior_tested: 'Pass invalidation tested',
  bank_merchant_contract_approved: 'Bank merchant contract approved',
  clover_app_and_rest_pay_approved: 'Clover app and REST Pay approved',
  device_provisioned: 'Card reader set up',
  oauth_scope_reviewed: 'OAuth permissions reviewed',
  live_low_value_tested: 'Small live payment tested',
  unknown_result_runbook_tested: 'Unknown-result procedure tested',
  counsel_approved: 'Legal counsel approved',
  accounting_approved: 'Accounting approved',
  privacy_approved: 'Privacy review approved',
  effective_dates_approved: 'Effective dates approved',
  reacceptance_rules_approved: 'Re-acceptance rules approved',
  retention_deletion_and_legal_hold_approved: 'Retention, deletion and legal hold approved',
}
const STATUS_LABELS = { not_configured: 'Not configured', disabled_pending_approval: 'Off until approved', approved: 'Approved' }
const sentenceCase = value => { const text = String(value).replaceAll('_', ' '); return text.charAt(0).toUpperCase() + text.slice(1) }
const controlLabel = control => CONTROL_LABELS[control] || sentenceCase(control)
const statusLabel = status => STATUS_LABELS[status] || sentenceCase(status)

function StatusBadge({ item }) {
  const styles = item.enabled
    ? 'bg-emerald-50 text-emerald-800 border-emerald-200'
    : item.configured ? 'bg-amber-50 text-amber-900 border-amber-200' : 'bg-neutral-100 text-neutral-700 border-neutral-200'
  return <span className={`inline-flex rounded-full border px-2.5 py-1 text-xs font-semibold ${styles}`}>{statusLabel(item.status)}</span>
}

function CapabilityCard({ item, refresh, identity }) {
  const { beginRequest } = usePlatformRequests(identity, '/admin/provider-readiness')
  const mutationBusy = useRef(false)
  const [form, setForm] = useState(initialForm)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState(null)

  const run = async operation => {
    if (mutationBusy.current) return
    const request = beginRequest()
    if (!request) return
    mutationBusy.current = true
    setBusy(true); setMessage(null)
    try {
      await operation(request.config)
      if (!request.current()) return
      setForm(initialForm()); setReason('')
      await refresh()
    } catch (error) {
      if (request.handleError(error)) return
      if (request.current()) setMessage(error.response?.data?.error || 'The evidence action failed.')
    } finally {
      request.release(); mutationBusy.current = false
      if (request.current()) setBusy(false)
    }
  }

  const submit = event => {
    event.preventDefault()
    run(config => apiClient.post(`/admin/platform_capabilities/${item.capability}/reviews`, {
      ...form,
      effective_at: new Date(form.effective_at).toISOString(),
      expires_at: new Date(form.expires_at).toISOString(),
      controls: form.controls,
    }, config))
  }
  const pending = item.pending_submission
  const approval = item.latest_approval
  const allControlsChecked = item.required_controls.every(control => form.controls[control])

  return (
    <section className="rounded-2xl border border-neutral-200 bg-white p-5 shadow-soft" aria-labelledby={`${item.capability}-heading`}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 id={`${item.capability}-heading`} className="text-lg font-bold text-neutral-900">{item.label}</h2>
          <p className="mt-1 text-sm text-neutral-600">Setup {item.configured ? 'is complete' : 'is not finished'}. Credentials alone never turn this on; it also needs an approved review.</p>
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
            <button type="button" className="btn-primary" disabled={busy} onClick={() => run(config => apiClient.post(`/admin/platform_capability_reviews/${pending.id}/approve`, undefined, config))}>Approve exact snapshot</button>
            <button type="button" className="rounded-xl border border-red-300 px-4 py-2 text-sm font-semibold text-red-800 disabled:opacity-50" disabled={busy || !reason.trim()} onClick={() => run(config => apiClient.post(`/admin/platform_capability_reviews/${pending.id}/reject`, { reason }, config))}>Reject</button>
          </div>
        </div>
      ) : approval?.active ? (
        <div className="mt-5 space-y-3 rounded-xl border border-emerald-200 bg-emerald-50 p-4">
          <div className="flex gap-3"><CheckCircle2 className="mt-0.5 h-5 w-5 shrink-0 text-emerald-700" /><div><p className="font-semibold text-emerald-950">Current approval</p><p className="text-sm text-emerald-900">Evidence {approval.evidence_reference}; expires {new Date(approval.expires_at).toLocaleString()}.</p></div></div>
          <label className="block text-sm font-medium text-emerald-950">Revocation reason
            <input className="input mt-1" value={reason} onChange={event => setReason(event.target.value)} />
          </label>
          <button type="button" className="rounded-xl border border-red-300 bg-white px-4 py-2 text-sm font-semibold text-red-800 disabled:opacity-50" disabled={busy || !reason.trim()} onClick={() => run(config => apiClient.post(`/admin/platform_capability_reviews/${approval.id}/revoke`, { reason }, config))}>Revoke approval</button>
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
          <fieldset><legend className="text-sm font-semibold text-neutral-900">Required evidence controls</legend><div className="mt-2 grid gap-2 sm:grid-cols-2">{item.required_controls.map(control => <label key={control} className="flex items-start gap-2 rounded-lg border border-neutral-200 p-3 text-sm text-neutral-700"><input className="mt-0.5" type="checkbox" checked={form.controls[control] || false} onChange={event => setForm({ ...form, controls: { ...form.controls, [control]: event.target.checked } })} />{controlLabel(control)}</label>)}</div></fieldset>
          <button className="btn-primary inline-flex items-center gap-2" disabled={busy || !item.configured || !allControlsChecked}>{busy && <Loader2 className="h-4 w-4 animate-spin" />}Submit evidence (can’t be edited later)</button>
        </form>
      )}
    </section>
  )
}

function ProviderReadinessSession({ identity }) {
  const { beginRequest } = usePlatformRequests(identity, '/admin/provider-readiness')
  const generation = useRef(0)
  const pendingRead = useRef(null)
  const [items, setItems] = useState(null)
  const [error, setError] = useState(null)
  const refresh = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    pendingRead.current?.abort()
    pendingRead.current = request
    const read = ++generation.current
    const current = () => request.current() && generation.current === read
    try {
      const response = await apiClient.get('/admin/platform_capabilities', request.config)
      if (!current()) return
      setItems(response.data.capabilities); setError(null)
    } catch (failure) {
      if (!current() || request.handleError(failure)) return
      setError('Unable to load provider readiness. Your current evidence drafts have been kept.')
    } finally { request.release() }
  }, [beginRequest])
  useEffect(() => { refresh(); return () => pendingRead.current?.abort() }, [refresh])

  return <AdminLayout><div className="mb-6 flex items-start gap-3"><ShieldCheck className="mt-1 h-7 w-7 text-brand-600" /><div><h2 className="text-2xl font-bold text-neutral-900">Provider and policy readiness</h2><p className="mt-1 max-w-3xl text-neutral-600">Credentials show that an integration can connect. Independent, current evidence determines whether HåfaPass may use it in production.</p></div></div>{error && <p className="rounded-xl bg-red-50 p-4 text-red-800" role="alert">{error} <button type="button" onClick={refresh} className="min-h-11 px-2 font-semibold underline">Retry provider readiness</button></p>}{!items && !error ? <Loader2 className="mx-auto mt-16 h-8 w-8 animate-spin text-brand-500" /> : <div className="space-y-5">{items?.map(item => <CapabilityCard key={item.capability} item={item} refresh={refresh} identity={identity} />)}</div>}</AdminLayout>
}


export default function ProviderReadinessPage() {
  const identity = usePlatformIdentity('admin')
  const visit = usePlatformVisit('/admin/provider-readiness')
  if (!visit.active) return null
  if (identity.authorityDenied) return <AdminAccessRecovery key={identity.accountKey} identity={identity} />
  if (!identity.ready) return <p role="status">Checking account access…</p>
  return <ProviderReadinessSession key={`${identity.accountKey}:${visit.generation}`} identity={identity} />
}
