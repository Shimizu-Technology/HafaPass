import { useEffect, useMemo, useRef, useState } from 'react'
import { Activity, Check, CirclePause, CirclePlay, Loader2, ShieldAlert, X } from 'lucide-react'
import apiClient from '../api/client'

const assignmentFields = [
  ['incident_commander', 'Incident commander'], ['business_owner', 'Business owner'],
  ['technical_lead', 'Technical lead'], ['finance_monitor', 'Finance monitor'],
  ['support_lead', 'Support lead'], ['admissions_lead', 'Admissions lead'],
  ['organizer_contact', 'Organizer contact'], ['venue_contact', 'Venue contact'],
]
const supportWindows = [
  ['before_event', 'Before event'], ['during_event', 'During event'], ['after_event', 'After event'],
]
const thresholdFields = [
  ['minimum_checkout_conversion_bps', 'Minimum checkout conversion (basis points)', 1000],
  ['maximum_payment_failure_rate_bps', 'Maximum payment failure rate (basis points)', 2000],
  ['maximum_hold_expiry_rate_bps', 'Maximum hold expiry rate (basis points)', 5000],
  ['maximum_delivery_failure_rate_bps', 'Maximum delivery failure rate (basis points)', 2000],
  ['maximum_scanner_conflicts', 'Maximum scanner conflicts', 0],
  ['maximum_scanner_sync_lag_seconds', 'Maximum scanner sync lag (seconds)', 120],
  ['maximum_checkout_p95_ms', 'Maximum checkout p95 (ms)', 2000],
  ['maximum_support_contacts_per_100_orders', 'Maximum support contacts per 100 orders', 100],
]
const controlFields = [
  ['bounded_inventory_confirmed', 'Inventory is capped and intentionally bounded'],
  ['no_high_demand_public_blast', 'No high-demand public marketing blast'],
  ['monitoring_dashboard_verified', 'Operations dashboard has been verified'],
  ['provider_status_monitoring_confirmed', 'Provider status monitoring is assigned'],
  ['pause_authority_confirmed', 'Incident commander has pause authority'],
  ['support_coverage_confirmed', 'Before, during, and after support coverage is confirmed'],
  ['guam_change_communications_ready', 'Guam-local schedule and policy communications are ready'],
  ['uncertain_payment_response_ready', 'Uncertain-payment response is rehearsed'],
  ['duplicate_charge_response_ready', 'Duplicate-charge response is rehearsed'],
  ['oversell_response_ready', 'Oversell response is rehearsed'],
  ['credential_compromise_response_ready', 'Credential-compromise response is rehearsed'],
  ['cross_tenant_response_ready', 'Cross-tenant disclosure response is rehearsed'],
  ['widespread_entry_failure_response_ready', 'Widespread entry-failure response is rehearsed'],
  ['no_open_p0_or_p1', 'No P0 or P1 is open'],
  ['explicit_go_decision', 'The accountable owner recorded an explicit go decision'],
]
const completionBooleans = [
  ['all_operations_reconciled', 'All operations reconciled'],
  ['all_payment_outcomes_resolved', 'All payment outcomes resolved'],
  ['all_refunds_resolved', 'All refunds resolved'],
  ['all_holds_reconciled', 'All holds reconciled'],
  ['all_deliveries_resolved', 'All deliveries resolved'],
  ['all_scanner_devices_synced', 'All scanner devices synced'],
  ['all_support_escalations_resolved', 'All support escalations resolved'],
  ['guam_communications_complete', 'Guam customer and organizer communications complete'],
  ['no_unresolved_p0_or_p1', 'No unresolved P0 or P1'],
]
const completionZeros = [
  ['unexplained_payment_variance_cents', 'Unexplained payment variance (cents)'],
  ['unexplained_inventory_variance', 'Unexplained inventory variance'],
  ['unexplained_admission_variance', 'Unexplained admission variance'],
  ['unresolved_operation_exception_count', 'Unresolved operation exceptions'],
]
const incidentCategories = [
  ['uncertain_payment', 'Uncertain payment'], ['duplicate_charge', 'Duplicate charge'],
  ['oversell', 'Oversell'], ['credential_compromise', 'Credential compromise'],
  ['cross_tenant_disclosure', 'Cross-tenant disclosure'],
  ['widespread_entry_failure', 'Widespread entry failure'], ['provider_outage', 'Provider outage'],
  ['checkout_failure', 'Checkout failure'], ['delivery_failure', 'Delivery failure'],
  ['scanner_sync_failure', 'Scanner sync failure'], ['support_escalation', 'Support escalation'],
  ['venue_or_schedule_change', 'Venue or schedule change'], ['other', 'Other'],
]

const pad = value => String(value).padStart(2, '0')
const localDateTime = value => {
  const date = new Date(value)
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`
}
const iso = value => new Date(value).toISOString()
const formatDate = value => value ? new Date(value).toLocaleString() : 'Not recorded'

function initialPlan(event) {
  const start = new Date(event?.starts_at || Date.now() + 86_400_000)
  const end = new Date(event?.ends_at || start.getTime() + 4 * 3_600_000)
  const now = new Date(); const expiry = new Date(end.getTime() + 24 * 3_600_000)
  const windows = {
    before_event: [new Date(start.getTime() - 4 * 3_600_000), new Date(start.getTime() + 30 * 60_000)],
    during_event: [new Date(start.getTime() - 30 * 60_000), new Date(end.getTime() + 30 * 60_000)],
    after_event: [new Date(end.getTime() - 30 * 60_000), new Date(end.getTime() + 3 * 3_600_000)],
  }
  return {
    evidence_reference: '', evidence_digest: '', inventory_cap: '50',
    effective_at: localDateTime(now), expires_at: localDateTime(expiry),
    support_coverage: Object.fromEntries(supportWindows.map(([key]) => [key, {
      starts_at: localDateTime(windows[key][0]), ends_at: localDateTime(windows[key][1]),
      primary_reference: '', backup_reference: '', channel_reference: '', acknowledgement_reference: '',
    }])),
    assignments: Object.fromEntries(assignmentFields.map(([key]) => [key, {
      name: '', private_contact_reference: '', acknowledgement_reference: '',
    }])),
    thresholds: Object.fromEntries(thresholdFields.map(([key, , defaultValue]) => [key, String(defaultValue)])),
    controls: Object.fromEntries(controlFields.map(([key]) => [key, false])),
  }
}

const initialCheckpoint = {
  evidence_reference: '', evidence_digest: '', provider_healthy: true, provider_status_reference: '',
  checkout_p95_ms: '0', scanner_sync_lag_seconds: '0', support_contacts_count: '0',
  refund_request_count: '0', support_coverage_confirmed: true, guam_communications_current: true,
}
const initialIncident = {
  severity: 'p2', category: 'other', summary: '', evidence_reference: '', evidence_digest: '',
}
const initialCompletion = {
  completion_evidence_reference: '', completion_evidence_digest: '',
  ...Object.fromEntries(completionBooleans.map(([key]) => [key, false])),
  ...Object.fromEntries(completionZeros.map(([key]) => [key, '0'])),
}

function ReviewSummary({ review }) {
  return <div className="space-y-4">
    <dl className="grid gap-3 text-sm sm:grid-cols-2 lg:grid-cols-4">
      <div className="border-l-2 border-sky-300 pl-3"><dt className="text-xs font-bold uppercase text-neutral-500">Inventory cap</dt><dd className="mt-1 text-lg font-bold">{review.inventory_cap}</dd></div>
      <div className="border-l-2 border-sky-300 pl-3"><dt className="text-xs font-bold uppercase text-neutral-500">Gate G approval</dt><dd className="mt-1 font-mono text-xs">#{review.event_day_rehearsal_review_id}</dd></div>
      <div className="border-l-2 border-sky-300 pl-3"><dt className="text-xs font-bold uppercase text-neutral-500">Gate H approval</dt><dd className="mt-1 font-mono text-xs">{review.live_money_proof_review_id ? `#${review.live_money_proof_review_id}` : 'Free event'}</dd></div>
      <div className="border-l-2 border-sky-300 pl-3"><dt className="text-xs font-bold uppercase text-neutral-500">Window</dt><dd className="mt-1 text-xs">{formatDate(review.effective_at)} – {formatDate(review.expires_at)}</dd></div>
    </dl>
    <p className="break-all text-xs text-neutral-600">Evidence: <span className="font-mono">{review.evidence_reference}</span> · <span className="font-mono">{review.evidence_digest}</span></p>
  </div>
}

export default function LivePilotOperationsDialog({ event, onComplete }) {
  const [open, setOpen] = useState(false)
  const [details, setDetails] = useState(null)
  const [plan, setPlan] = useState(() => initialPlan(event))
  const [checkpoint, setCheckpoint] = useState(initialCheckpoint)
  const [incident, setIncident] = useState(initialIncident)
  const [completion, setCompletion] = useState(initialCompletion)
  const [reason, setReason] = useState('')
  const [resolution, setResolution] = useState({ incidentId: null, summary: '', evidence_reference: '', evidence_digest: '' })
  const [loading, setLoading] = useState(false); const [busy, setBusy] = useState(false); const [error, setError] = useState('')
  const triggerRef = useRef(null); const closeRef = useRef(null); const dialogRef = useRef(null)
  const pilot = details?.live_pilot || event.live_pilot || {}
  const pending = pilot.pending_submission; const approval = pilot.latest_approval; const run = pilot.latest_run
  const mode = run && ['active', 'paused', 'completed'].includes(run.status) ? 'operate' :
    run?.status === 'aborted' && pilot.approved ? 'aborted' : pilot.approved ? 'approved' :
      pending ? 'pending' : 'submit'
  const planComplete = useMemo(() => controlFields.every(([key]) => plan.controls[key]), [plan.controls])
  const completionComplete = useMemo(() => completionBooleans.every(([key]) => completion[key]) &&
    completionZeros.every(([key]) => Number(completion[key]) === 0), [completion])

  useEffect(() => {
    if (!open) return undefined
    const close = keyEvent => { if (keyEvent.key === 'Escape' && !busy) setOpen(false) }
    document.addEventListener('keydown', close); closeRef.current?.focus()
    return () => document.removeEventListener('keydown', close)
  }, [open, busy])
  useEffect(() => { if (!open) triggerRef.current?.focus() }, [open])

  const load = async () => {
    setLoading(true); setError('')
    try {
      const response = await apiClient.get(`/admin/events/${event.id}/live_pilot`)
      setDetails(response.data)
      if (!response.data.live_pilot?.pending_submission && !response.data.live_pilot?.latest_approval) {
        setPlan(initialPlan(response.data.event))
      }
    } catch (requestError) { setError(requestError.response?.data?.error || 'Gate I operations could not be loaded.') }
    finally { setLoading(false) }
  }
  const openDialog = () => { setOpen(true); load() }
  const request = async action => {
    setBusy(true); setError('')
    try { await action(); setReason(''); await load(); onComplete?.(); return true }
    catch (requestError) { setError(requestError.response?.data?.error || 'The Gate I action could not be recorded.'); return false }
    finally { setBusy(false) }
  }
  const updateNested = (setter, section, key, field, value) => setter(current => ({
    ...current, [section]: { ...current[section], [key]: { ...current[section][key], [field]: value } },
  }))
  const submitPlan = submitEvent => {
    submitEvent.preventDefault()
    const payload = {
      ...plan, inventory_cap: Number(plan.inventory_cap), effective_at: iso(plan.effective_at),
      expires_at: iso(plan.expires_at),
      support_coverage: Object.fromEntries(Object.entries(plan.support_coverage).map(([key, value]) =>
        [key, { ...value, starts_at: iso(value.starts_at), ends_at: iso(value.ends_at) }])),
      thresholds: Object.fromEntries(Object.entries(plan.thresholds).map(([key, value]) => [key, Number(value)])),
    }
    request(() => apiClient.post(`/admin/events/${event.id}/live_pilot_reviews`, payload))
  }
  const recordCheckpoint = submitEvent => {
    submitEvent.preventDefault()
    const external_metrics = { ...checkpoint }
    delete external_metrics.evidence_reference; delete external_metrics.evidence_digest
    ;['checkout_p95_ms', 'scanner_sync_lag_seconds', 'support_contacts_count', 'refund_request_count'].forEach(key => {
      external_metrics[key] = Number(external_metrics[key])
    })
    request(() => apiClient.post(`/admin/live_pilot_runs/${run.id}/checkpoint`, {
      evidence_reference: checkpoint.evidence_reference, evidence_digest: checkpoint.evidence_digest, external_metrics,
    }))
  }
  const reportIncident = submitEvent => {
    submitEvent.preventDefault()
    request(() => apiClient.post(`/admin/live_pilot_runs/${run.id}/incidents`, incident))
  }
  const resolveIncident = async submitEvent => {
    submitEvent.preventDefault()
    const recorded = await request(() => apiClient.post(`/admin/live_pilot_incidents/${resolution.incidentId}/resolve`, {
      summary: resolution.summary, evidence_reference: resolution.evidence_reference,
      evidence_digest: resolution.evidence_digest,
    }))
    if (recorded) setResolution({ incidentId: null, summary: '', evidence_reference: '', evidence_digest: '' })
  }
  const completeRun = submitEvent => {
    submitEvent.preventDefault()
    request(() => apiClient.post(`/admin/live_pilot_runs/${run.id}/complete`, {
      completion_evidence_reference: completion.completion_evidence_reference,
      completion_evidence_digest: completion.completion_evidence_digest,
      completion_results: {
        ...Object.fromEntries(completionBooleans.map(([key]) => [key, completion[key]])),
        ...Object.fromEntries(completionZeros.map(([key]) => [key, Number(completion[key])])),
      },
    }))
  }

  const triggerLabel = event.live_pilot?.run_status ? `Gate I pilot · ${event.live_pilot.run_status}` :
    event.live_pilot?.approval_recorded ? 'Operate Gate I bounded pilot' :
      event.live_pilot?.pending_submission ? 'Review Gate I pilot plan' : 'Prepare Gate I bounded pilot'

  return <>
    <button ref={triggerRef} type="button" onClick={openDialog} className="min-h-11 text-left text-xs font-semibold text-sky-800 underline decoration-sky-300 underline-offset-4 hover:text-sky-950">{triggerLabel}</button>
    {open && <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-neutral-950/55 px-3 py-4 sm:px-6 sm:py-8" role="presentation" onMouseDown={eventValue => { if (eventValue.target === eventValue.currentTarget && !busy) setOpen(false) }}>
      <section ref={dialogRef} role="dialog" aria-modal="true" aria-labelledby="live-pilot-title" className="w-full max-w-7xl overflow-hidden rounded-2xl bg-stone-50 shadow-2xl">
        <header className="sticky top-0 z-10 flex items-start justify-between gap-4 border-b bg-stone-50/95 px-6 py-5 backdrop-blur sm:px-8"><div><p className="text-xs font-bold uppercase tracking-[0.18em] text-sky-800">Gate I · bounded live pilot</p><h2 id="live-pilot-title" className="mt-1 text-2xl font-bold tracking-tight">{details?.event?.title || event.title}</h2><p className="mt-1 max-w-4xl text-sm text-neutral-600">Authorize a small Guam event, watch real commerce and entry operations, pause on uncertainty, and close only after every system is reconciled.</p></div><button ref={closeRef} type="button" aria-label="Close Gate I pilot operations" disabled={busy} onClick={() => setOpen(false)} className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full hover:bg-stone-200 focus-visible:ring-2 focus-visible:ring-sky-700"><X className="h-5 w-5" /></button></header>
        <div className="px-6 py-6 sm:px-8 sm:py-8">
          {error && <div role="alert" className="mb-6 flex gap-3 border-l-4 border-red-600 bg-red-50 p-4 text-sm text-red-900"><ShieldAlert className="h-5 w-5 shrink-0" /><p>{error}</p></div>}
          {loading && !details ? <div className="flex justify-center py-16"><Loader2 aria-label="Loading Gate I operations" className="h-8 w-8 animate-spin text-sky-700" /></div> : <>
            {mode === 'submit' && <form onSubmit={submitPlan} className="space-y-9">
              {!pilot.prerequisite_ready && <div className="border-l-4 border-amber-500 bg-amber-50 p-4 text-sm text-amber-950">The exact current Gate G rehearsal and, for paid events, Gate H live-money approval are required before submission.</div>}
              {approval && <div className="border-l-4 border-amber-500 bg-amber-50 p-4 text-sm text-amber-950">The prior Gate I approval is stale, expired, or revoked. Submit a new plan bound to the current event and application state.</div>}
              <fieldset><legend className="font-bold">Pilot boundary and immutable evidence</legend><p className="mt-1 text-sm text-neutral-600">Cap inventory at 250 or less. Do not use Gate I as a high-demand public launch.</p><div className="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-3"><label className="text-xs font-semibold">Inventory cap<input required type="number" min="1" max={pilot.maximum_inventory_cap || 250} value={plan.inventory_cap} onChange={change => setPlan(current => ({ ...current, inventory_cap: change.target.value }))} className="input mt-1" /></label><label className="text-xs font-semibold">Restricted evidence reference<input required value={plan.evidence_reference} onChange={change => setPlan(current => ({ ...current, evidence_reference: change.target.value }))} className="input mt-1" /></label><label className="text-xs font-semibold">Evidence SHA-256<input required pattern="[0-9a-f]{64}" value={plan.evidence_digest} onChange={change => setPlan(current => ({ ...current, evidence_digest: change.target.value.trim().toLowerCase() }))} className="input mt-1 font-mono text-xs" /></label><label className="text-xs font-semibold">Effective<input required type="datetime-local" value={plan.effective_at} onChange={change => setPlan(current => ({ ...current, effective_at: change.target.value }))} className="input mt-1" /></label><label className="text-xs font-semibold">Expires<input required type="datetime-local" value={plan.expires_at} onChange={change => setPlan(current => ({ ...current, expires_at: change.target.value }))} className="input mt-1" /></label></div></fieldset>
              <fieldset><legend className="font-bold">Guam-local support coverage</legend><p className="mt-1 text-sm text-neutral-600">Record private references, not phone numbers or personal data in this operational ledger.</p><div className="mt-4 grid gap-4 lg:grid-cols-3">{supportWindows.map(([key, label]) => <div key={key} className="bg-white p-4"><h3 className="font-bold">{label}</h3>{[['starts_at', 'Starts', 'datetime-local'], ['ends_at', 'Ends', 'datetime-local'], ['primary_reference', 'Primary support reference', 'text'], ['backup_reference', 'Backup support reference', 'text'], ['channel_reference', 'Support channel reference', 'text'], ['acknowledgement_reference', 'Coverage acknowledgement', 'text']].map(([field, fieldLabel, type]) => <label key={field} className="mt-3 block text-xs font-semibold">{fieldLabel}<input required type={type} aria-label={`${label} ${fieldLabel}`} value={plan.support_coverage[key][field]} onChange={change => updateNested(setPlan, 'support_coverage', key, field, change.target.value)} className="input mt-1" /></label>)}</div>)}</div></fieldset>
              <fieldset><legend className="font-bold">Named operational owners</legend><div className="mt-4 grid gap-4 lg:grid-cols-2">{assignmentFields.map(([key, label]) => <div key={key} className="bg-white p-4"><h3 className="font-bold">{label}</h3>{[['name', 'Name'], ['private_contact_reference', 'Private contact reference'], ['acknowledgement_reference', 'Acknowledgement reference']].map(([field, fieldLabel]) => <label key={field} className="mt-3 block text-xs font-semibold">{fieldLabel}<input required aria-label={`${label} ${fieldLabel}`} value={plan.assignments[key][field]} onChange={change => updateNested(setPlan, 'assignments', key, field, change.target.value)} className="input mt-1" /></label>)}</div>)}</div></fieldset>
              <fieldset><legend className="font-bold">Pause thresholds</legend><div className="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">{thresholdFields.map(([key, label]) => <label key={key} className="text-xs font-semibold">{label}<input required type="number" min="0" value={plan.thresholds[key]} onChange={change => setPlan(current => ({ ...current, thresholds: { ...current.thresholds, [key]: change.target.value } }))} className="input mt-1" /></label>)}</div></fieldset>
              <fieldset><legend className="font-bold">Go/no-go controls</legend><div className="mt-3 grid gap-2 sm:grid-cols-2">{controlFields.map(([key, label]) => <label key={key} className="flex min-h-12 items-start gap-3 border-l-2 border-stone-300 bg-white px-4 py-3 text-sm"><input type="checkbox" checked={plan.controls[key]} onChange={change => setPlan(current => ({ ...current, controls: { ...current.controls, [key]: change.target.checked } }))} className="mt-0.5 h-5 w-5" />{label}</label>)}</div></fieldset>
              <div className="flex flex-col-reverse gap-3 border-t pt-6 sm:flex-row sm:items-center sm:justify-between"><p className="text-xs text-neutral-500">A different administrator must approve this exact append-only plan.</p><button disabled={busy || !pilot.prerequisite_ready || !planComplete} className="btn-primary min-h-11 disabled:opacity-50"><Activity className="h-4 w-4" /> Submit Gate I plan</button></div>
            </form>}
            {mode === 'pending' && <div className="space-y-7"><div className="border-l-4 border-amber-500 bg-amber-50 p-4 text-sm text-amber-950"><strong>Independent decision required.</strong> Admin #{pending.actor_user_id} submitted this plan and cannot approve it.</div><ReviewSummary review={pending} /><label className="block text-sm font-semibold">Rejection reason<input value={reason} onChange={change => setReason(change.target.value)} className="input mt-2" /></label><div className="flex flex-wrap justify-end gap-3 border-t pt-6"><button disabled={busy || !reason.trim()} onClick={() => request(() => apiClient.post(`/admin/live_pilot_reviews/${pending.id}/reject`, { reason }))} className="min-h-11 rounded-full border border-red-300 px-5 font-semibold text-red-800 disabled:opacity-50">Reject plan</button><button disabled={busy} onClick={() => request(() => apiClient.post(`/admin/live_pilot_reviews/${pending.id}/approve`))} className="btn-primary min-h-11"><Check className="h-4 w-4" /> Approve exact Gate I plan</button></div></div>}
            {mode === 'approved' && <div className="space-y-7"><div className="border-l-4 border-emerald-600 bg-emerald-50 p-4 text-sm text-emerald-950"><strong>Gate I plan approved.</strong> Publish the event, confirm the private operating channel, then start the bounded sales window.</div><ReviewSummary review={approval} /><label className="block text-sm font-semibold">Revocation reason<input value={reason} onChange={change => setReason(change.target.value)} className="input mt-2" /></label><div className="flex flex-wrap justify-end gap-3 border-t pt-6"><button disabled={busy || !reason.trim()} onClick={() => request(() => apiClient.post(`/admin/live_pilot_reviews/${approval.id}/revoke`, { reason }))} className="min-h-11 rounded-full border border-red-300 px-5 font-semibold text-red-800 disabled:opacity-50">Revoke approval</button><button disabled={busy || details?.event?.status !== 'published'} onClick={() => request(() => apiClient.post(`/admin/live_pilot_reviews/${approval.id}/start`))} className="btn-primary min-h-11 disabled:opacity-50"><CirclePlay className="h-4 w-4" /> Start bounded pilot</button></div></div>}
            {mode === 'aborted' && <div className="space-y-7"><div className="border-l-4 border-red-600 bg-red-50 p-5 text-red-950"><strong>Gate I run aborted; sales remain suspended.</strong><p className="mt-1 text-sm">{run.abort_reason && `Aborted ${formatDate(run.aborted_at)}: ${run.abort_reason}. `}Revoke the old approval with a specific reason before submitting a separately reviewed recovery plan.</p></div><ReviewSummary review={approval} /><label className="block text-sm font-semibold">Revocation and recovery reason<input value={reason} onChange={change => setReason(change.target.value)} className="input mt-2" /></label><div className="flex justify-end"><button disabled={busy || !reason.trim()} onClick={() => request(() => apiClient.post(`/admin/live_pilot_reviews/${approval.id}/revoke`, { reason }))} className="min-h-11 rounded-full bg-red-700 px-5 font-semibold text-white disabled:opacity-50">Revoke aborted plan approval</button></div></div>}
            {mode === 'operate' && <div className="space-y-10">
              <section className="space-y-5"><div className={`border-l-4 p-4 ${run.status === 'active' ? 'border-emerald-600 bg-emerald-50 text-emerald-950' : run.status === 'paused' ? 'border-amber-500 bg-amber-50 text-amber-950' : 'border-neutral-500 bg-neutral-100'}`}><div className="flex flex-wrap items-center justify-between gap-3"><div><p className="text-xs font-bold uppercase tracking-wide">Pilot run #{run.id} · {run.status}</p><p className="mt-1 text-sm">{run.committed_ticket_quantity} of {run.inventory_cap} tickets committed</p>{run.pause_reason && <p className="mt-1 text-sm">Reason: {run.pause_reason}</p>}</div>{['active', 'paused'].includes(run.status) && <div className="flex flex-wrap gap-2"><button disabled={busy || run.status !== 'active' || !reason.trim()} onClick={() => request(() => apiClient.post(`/admin/live_pilot_runs/${run.id}/pause`, { reason }))} className="min-h-11 rounded-full border border-amber-400 px-4 text-sm font-semibold disabled:opacity-50"><CirclePause className="mr-2 inline h-4 w-4" />Pause</button><button disabled={busy || run.status !== 'paused' || !reason.trim()} onClick={() => request(() => apiClient.post(`/admin/live_pilot_runs/${run.id}/resume`, { reason }))} className="min-h-11 rounded-full border border-emerald-500 px-4 text-sm font-semibold disabled:opacity-50"><CirclePlay className="mr-2 inline h-4 w-4" />Resume after safe checkpoint</button><button disabled={busy || !reason.trim()} onClick={() => request(() => apiClient.post(`/admin/live_pilot_runs/${run.id}/abort`, { reason }))} className="min-h-11 rounded-full bg-red-700 px-4 text-sm font-semibold text-white disabled:opacity-50">Abort</button></div>}</div></div>{['active', 'paused'].includes(run.status) && <label className="block text-sm font-semibold">Action reason<input value={reason} onChange={change => setReason(change.target.value)} placeholder="Required for pause, resume, or abort" className="input mt-2" /></label>}</section>
              {['active', 'paused'].includes(run.status) && <div className="grid gap-8 xl:grid-cols-2"><form onSubmit={recordCheckpoint} className="space-y-5 bg-white p-5"><div><h3 className="font-bold">Monitoring checkpoint</h3><p className="mt-1 text-sm text-neutral-600">Local metrics are calculated by HafaPass. Enter the provider, latency, scanner, support, and communications observations.</p></div><div className="grid gap-3 sm:grid-cols-2">{[['evidence_reference', 'Checkpoint evidence reference', 'text'], ['evidence_digest', 'Evidence SHA-256', 'text'], ['provider_status_reference', 'Provider status reference', 'text'], ['checkout_p95_ms', 'Checkout p95 (ms)', 'number'], ['scanner_sync_lag_seconds', 'Scanner sync lag (seconds)', 'number'], ['support_contacts_count', 'Support contacts', 'number'], ['refund_request_count', 'Refund requests', 'number']].map(([key, label, type]) => <label key={key} className="text-xs font-semibold">{label}<input required type={type} min={type === 'number' ? 0 : undefined} pattern={key === 'evidence_digest' ? '[0-9a-f]{64}' : undefined} value={checkpoint[key]} onChange={change => setCheckpoint(current => ({ ...current, [key]: change.target.value }))} className="input mt-1" /></label>)}</div>{[['provider_healthy', 'Payment/delivery providers healthy'], ['support_coverage_confirmed', 'Support coverage present now'], ['guam_communications_current', 'Guam-facing schedule and policy communications current']].map(([key, label]) => <label key={key} className="flex gap-3 text-sm"><input type="checkbox" checked={checkpoint[key]} onChange={change => setCheckpoint(current => ({ ...current, [key]: change.target.checked }))} className="h-5 w-5" />{label}</label>)}<button disabled={busy} className="btn-primary min-h-11">Record checkpoint</button></form>
                <form onSubmit={reportIncident} className="space-y-5 bg-white p-5"><div><h3 className="font-bold">Report operational incident</h3><p className="mt-1 text-sm text-neutral-600">P0/P1 and mandatory safety categories immediately pause an active run.</p></div><div className="grid gap-3 sm:grid-cols-2"><label className="text-xs font-semibold">Severity<select aria-label="Incident severity" value={incident.severity} onChange={change => setIncident(current => ({ ...current, severity: change.target.value }))} className="input mt-1"><option value="p0">P0</option><option value="p1">P1</option><option value="p2">P2</option><option value="p3">P3</option></select></label><label className="text-xs font-semibold">Category<select aria-label="Incident category" value={incident.category} onChange={change => setIncident(current => ({ ...current, category: change.target.value }))} className="input mt-1">{incidentCategories.map(([key, label]) => <option key={key} value={key}>{label}</option>)}</select></label><label className="text-xs font-semibold sm:col-span-2">Summary<textarea required value={incident.summary} onChange={change => setIncident(current => ({ ...current, summary: change.target.value }))} className="input mt-1 min-h-24" /></label><label className="text-xs font-semibold">Evidence reference<input required value={incident.evidence_reference} onChange={change => setIncident(current => ({ ...current, evidence_reference: change.target.value }))} className="input mt-1" /></label><label className="text-xs font-semibold">Evidence SHA-256<input required pattern="[0-9a-f]{64}" value={incident.evidence_digest} onChange={change => setIncident(current => ({ ...current, evidence_digest: change.target.value.trim().toLowerCase() }))} className="input mt-1" /></label></div><button disabled={busy} className="min-h-11 rounded-full bg-red-700 px-5 font-semibold text-white">Report incident</button></form></div>}
              <section><h3 className="font-bold">Incident ledger</h3>{run.incidents?.length ? <div className="mt-3 space-y-3">{run.incidents.filter(item => item.action === 'report').map(item => <div key={item.id} className="border-l-4 border-neutral-300 bg-white p-4"><div className="flex flex-wrap items-start justify-between gap-3"><div><p className="font-bold">{item.severity.toUpperCase()} · {item.category.replaceAll('_', ' ')}</p><p className="mt-1 text-sm">{item.summary}</p><p className="mt-1 text-xs text-neutral-500">{formatDate(item.occurred_at)} · {item.resolved ? 'Resolved' : 'Open'}</p></div>{!item.resolved && ['active', 'paused'].includes(run.status) && <button onClick={() => setResolution(current => ({ ...current, incidentId: item.id }))} className="min-h-11 rounded-full border px-4 text-sm font-semibold">Resolve with evidence</button>}</div>{resolution.incidentId === item.id && <form onSubmit={resolveIncident} className="mt-4 grid gap-3 border-t pt-4 sm:grid-cols-2"><label className="text-xs font-semibold sm:col-span-2">Resolution summary<textarea required value={resolution.summary} onChange={change => setResolution(current => ({ ...current, summary: change.target.value }))} className="input mt-1" /></label><label className="text-xs font-semibold">Evidence reference<input required value={resolution.evidence_reference} onChange={change => setResolution(current => ({ ...current, evidence_reference: change.target.value }))} className="input mt-1" /></label><label className="text-xs font-semibold">Evidence SHA-256<input required pattern="[0-9a-f]{64}" value={resolution.evidence_digest} onChange={change => setResolution(current => ({ ...current, evidence_digest: change.target.value.trim().toLowerCase() }))} className="input mt-1" /></label><button disabled={busy} className="btn-primary min-h-11 sm:col-span-2 sm:justify-self-end">Record resolution</button></form>}</div>)}</div> : <p className="mt-2 text-sm text-neutral-500">No incidents recorded.</p>}</section>
              {run.latest_metric_snapshot && <section className="bg-sky-50 p-5"><h3 className="font-bold">Latest checkpoint · {formatDate(run.latest_metric_snapshot.observed_at)}</h3><p className="mt-1 text-sm">{Object.keys(run.latest_metric_snapshot.breached_thresholds || {}).length ? `Breaches: ${Object.keys(run.latest_metric_snapshot.breached_thresholds).join(', ')}` : 'All configured safety thresholds passed.'}</p><dl className="mt-4 grid gap-3 text-xs sm:grid-cols-3 lg:grid-cols-6">{Object.entries(run.latest_metric_snapshot.local_metrics || {}).map(([key, value]) => <div key={key}><dt className="text-neutral-500">{key.replaceAll('_', ' ')}</dt><dd className="font-bold">{value}</dd></div>)}</dl></section>}
              {['active', 'paused'].includes(run.status) && <form onSubmit={completeRun} className="space-y-5 border-t pt-8"><div><h3 className="font-bold">Post-event closeout</h3><p className="mt-1 text-sm text-neutral-600">First mark the event completed and record a new safe checkpoint. Gate I will reject nonzero local operations, open P0/P1 incidents, stale checkpoints, or unexplained variance.</p></div><div className="grid gap-4 sm:grid-cols-2"><label className="text-xs font-semibold">Completion evidence reference<input required value={completion.completion_evidence_reference} onChange={change => setCompletion(current => ({ ...current, completion_evidence_reference: change.target.value }))} className="input mt-1" /></label><label className="text-xs font-semibold">Completion evidence SHA-256<input required pattern="[0-9a-f]{64}" value={completion.completion_evidence_digest} onChange={change => setCompletion(current => ({ ...current, completion_evidence_digest: change.target.value.trim().toLowerCase() }))} className="input mt-1" /></label></div><div className="grid gap-2 sm:grid-cols-2">{completionBooleans.map(([key, label]) => <label key={key} className="flex gap-3 bg-white p-3 text-sm"><input type="checkbox" checked={completion[key]} onChange={change => setCompletion(current => ({ ...current, [key]: change.target.checked }))} className="h-5 w-5" />{label}</label>)}</div><div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">{completionZeros.map(([key, label]) => <label key={key} className="text-xs font-semibold">{label}<input required type="number" min="0" value={completion[key]} onChange={change => setCompletion(current => ({ ...current, [key]: change.target.value }))} className="input mt-1" /></label>)}</div><div className="flex justify-end"><button disabled={busy || !completionComplete || details?.event?.status !== 'completed'} className="btn-primary min-h-11 disabled:opacity-50">Complete and reconcile Gate I</button></div></form>}
              {run.status === 'completed' && <div className="border-l-4 border-emerald-600 bg-emerald-50 p-5 text-emerald-950"><strong>Gate I completed and reconciled.</strong><p className="mt-1 text-sm">Closed {formatDate(run.completed_at)} · evidence {run.completion_evidence_reference}</p></div>}{run.status === 'aborted' && <div className="border-l-4 border-red-600 bg-red-50 p-5 text-red-950"><strong>Gate I aborted.</strong><p className="mt-1 text-sm">Aborted {formatDate(run.aborted_at)}{run.abort_reason ? `: ${run.abort_reason}` : ''}. Sales remain suspended. A new plan requires an explicitly reviewed recovery path.</p></div>}
            </div>}
          </>}
        </div>
      </section>
    </div>}
  </>
}
