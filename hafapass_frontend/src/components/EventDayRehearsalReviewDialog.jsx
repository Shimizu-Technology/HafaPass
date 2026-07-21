import { useEffect, useMemo, useRef, useState } from 'react'
import { Check, Loader2, RadioTower, ShieldAlert, ShieldCheck, Smartphone, X } from 'lucide-react'
import apiClient from '../api/client'

const scanScenarios = [
  ['valid_unique', 'Unique valid ticket'], ['invalid_credential', 'Invalid credential'],
  ['same_ticket_cross_device', 'Same ticket on multiple offline devices'], ['duplicate', 'Duplicate ticket'],
  ['refunded', 'Refunded ticket'], ['transferred', 'Transferred ticket'], ['rotated', 'Rotated credential'],
  ['payment_blocked', 'Payment-blocked ticket'], ['already_admitted', 'Already-admitted ticket'],
  ['manual_lookup', 'Manual lookup'], ['authorized_reversal', 'Authorized reversal'],
  ['reconnect_in_different_order', 'Reconnect devices in different order'],
  ['conflict_resolution', 'Visible conflict resolution'], ['queue_drain', 'Every local queue drains'],
]
const incidents = [
  ['payment_provider_outage', 'Payment-provider outage'], ['venue_network_loss', 'Venue internet loss'],
  ['worker_failure', 'Worker failure'], ['severe_application_error', 'Severe application error'],
  ['evacuation_sales_pause', 'Evacuation and sales pause'], ['refund_incident', 'Refund incident'],
  ['support_escalation', 'Support escalation'],
]
const assignments = [
  ['event_commander', 'Event commander'], ['technical_lead', 'Technical lead'], ['door_lead', 'Door lead'],
  ['finance_contact', 'Finance contact'], ['venue_safety_contact', 'Venue safety contact'],
  ['support_escalation_owner', 'Support escalation owner'],
]
const controls = [
  ['stable_signing_key_confirmed', 'Stable signing key and rotation procedure confirmed'],
  ['emergency_list_handling_confirmed', 'Emergency list printed and handled as restricted data'],
  ['spare_devices_and_batteries_confirmed', 'Spare devices and batteries assigned'],
  ['venue_network_fallback_confirmed', 'Venue-network fallback confirmed'],
  ['cash_control_approved', 'Cash handling decision approved'],
  ['card_present_policy_approved', 'Card-present decision and unknown-result policy approved'],
  ['alerts_acknowledged', 'Every triggered alert acknowledged'],
  ['rehearsal_log_complete', 'Rehearsal log is complete'],
  ['all_findings_resolved', 'All release-blocking findings resolved'],
  ['no_open_p0_or_p1', 'No P0 or P1 remains open'],
  ['explicit_go_decision', 'Event commander recorded an explicit go decision'],
]
const manifestFields = [
  ['rehearsal_event_reference', 'Controlled rehearsal event/reference', 'text'], ['version', 'Manifest version', 'number'],
  ['digest', 'Manifest SHA-256', 'text'], ['key_id', 'Signing key ID', 'text'],
  ['algorithm', 'Signing algorithm', 'text'], ['ticket_count', 'Generated ticket count', 'number'],
  ['generated_at', 'Manifest generated at', 'datetime-local'], ['expires_at', 'Manifest expires at', 'datetime-local'],
  ['signed_manifest_evidence_reference', 'Signed-manifest evidence reference', 'text'],
  ['emergency_door_list_reference', 'Emergency door-list reference', 'text'],
  ['emergency_door_list_digest', 'Emergency list SHA-256', 'text'],
]
const deviceFields = [
  ['identifier', 'Device identifier', 'text'], ['name', 'Operational name', 'text'], ['model', 'Physical model', 'text'],
  ['os_version', 'OS version', 'text'], ['browser', 'Browser', 'text'], ['browser_version', 'Browser version', 'text'],
  ['tester_reference', 'Private tester reference', 'text'], ['evidence_reference', 'Evidence reference', 'text'],
  ['reconnect_order', 'Reconnect order', 'number'], ['queued_actions_before_sync', 'Queued before sync', 'number'],
  ['queued_actions_after_sync', 'Queued after sync', 'number'], ['conflicts_observed', 'Conflicts observed', 'number'],
  ['immediate_feedback_p95_ms', 'Offline feedback p95 (ms)', 'number'],
  ['battery_plan_reference', 'Battery plan reference', 'text'], ['spare_device_reference', 'Spare device reference', 'text'],
]
const reconciliationFields = [
  ['generated_ticket_count', 'Generated ticket count'], ['unique_admissions_expected', 'Unique admissions expected'],
  ['unique_admissions_observed', 'Unique admissions observed'], ['duplicate_conflicts_expected', 'Duplicate conflicts expected'],
  ['duplicate_conflicts_observed', 'Duplicate conflicts observed'], ['pending_queue_count', 'Pending queue count'],
  ['unresolved_conflict_count', 'Unresolved conflict count'], ['unexplained_admission_variance', 'Unexplained admission variance'],
  ['unexplained_inventory_variance', 'Unexplained inventory variance'],
  ['unexplained_cash_variance_cents', 'Unexplained cash variance (cents)'],
  ['unexplained_card_variance_cents', 'Unexplained card variance (cents)'],
  ['online_scan_p95_ms', 'Online scan p95 (ms)'], ['offline_feedback_p95_ms', 'Offline feedback p95 (ms)'],
]

const pad = value => String(value).padStart(2, '0')
const localDateTime = value => {
  const date = new Date(value)
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`
}
const blankDevice = index => ({
  identifier: '', name: `Door ${index + 1}`, model: '', os_version: '', browser: '', browser_version: '',
  tester_reference: '', evidence_reference: '', physical_device: true, manifest_signature_verified: true,
  offline_mode_completed: true, reconnect_order: String(index + 1), queued_actions_before_sync: '',
  queued_actions_after_sync: '0', conflicts_observed: '', immediate_feedback_p95_ms: '',
  battery_plan_reference: '', spare_device_reference: '',
})
const initialForm = () => {
  const now = new Date(); const expiry = new Date(now); expiry.setDate(expiry.getDate() + 7)
  const manifestExpiry = new Date(now); manifestExpiry.setHours(manifestExpiry.getHours() + 12)
  return {
    evidence_reference: '', evidence_digest: '', effective_at: localDateTime(now), expires_at: localDateTime(expiry),
    manifest_results: {
      rehearsal_event_reference: '', version: '', digest: '', key_id: '', algorithm: 'RSA-PSS-SHA256',
      ticket_count: '500', generated_at: localDateTime(now), expires_at: localDateTime(manifestExpiry),
      signed_manifest_evidence_reference: '', emergency_door_list_reference: '', emergency_door_list_digest: '',
      signature_verified_on_every_device: true,
    },
    device_results: [blankDevice(0), blankDevice(1), blankDevice(2)],
    scan_results: Object.fromEntries(scanScenarios.map(([key]) => [key, false])),
    incident_drills: Object.fromEntries(incidents.map(([key]) => [key, {
      status: 'passed', evidence_reference: '', alert_acknowledgement_reference: '', resolution_reference: '',
    }])),
    door_sales_results: {
      cash: { status: 'disabled', evidence_reference: '', reconciliation_reference: '', disabled_reason: '', provider: '', account_readiness_reference: '', successful_attempt_reference: '', unknown_outcome_reference: '', no_blind_retry_confirmed: false },
      card_present: { status: 'disabled', evidence_reference: '', reconciliation_reference: '', disabled_reason: '', provider: '', account_readiness_reference: '', successful_attempt_reference: '', unknown_outcome_reference: '', no_blind_retry_confirmed: false },
    },
    reconciliation_results: Object.fromEntries(reconciliationFields.map(([key]) => [key,
      key === 'generated_ticket_count' ? '500' : ['unique_admissions_expected', 'unique_admissions_observed'].includes(key) ? '2' : ['duplicate_conflicts_expected', 'duplicate_conflicts_observed'].includes(key) ? '1' : ['online_scan_p95_ms', 'offline_feedback_p95_ms'].includes(key) ? '' : '0'])),
    assignments: Object.fromEntries(assignments.map(([key]) => [key, { name: '', private_contact_reference: '', acknowledgement_reference: '' }])),
    controls: Object.fromEntries(controls.map(([key]) => [key, false])),
  }
}

const formatDate = value => value ? new Date(value).toLocaleString() : 'Not recorded'

function EvidenceSummary({ review }) {
  return <div className="space-y-5">
    <dl className="grid gap-4 text-sm sm:grid-cols-2">
      <div className="border-l-2 border-violet-300 pl-3"><dt className="text-xs font-bold uppercase tracking-wide text-neutral-500">Evidence reference</dt><dd className="mt-1 break-all">{review.evidence_reference}</dd></div>
      <div className="border-l-2 border-violet-300 pl-3"><dt className="text-xs font-bold uppercase tracking-wide text-neutral-500">Evidence SHA-256</dt><dd className="mt-1 break-all font-mono text-xs">{review.evidence_digest}</dd></div>
      <div className="border-l-2 border-neutral-300 pl-3"><dt className="text-xs font-bold uppercase tracking-wide text-neutral-500">Gate F approval</dt><dd className="mt-1 font-mono text-xs">#{review.pilot_validation_review_id}</dd></div>
      <div className="border-l-2 border-neutral-300 pl-3"><dt className="text-xs font-bold uppercase tracking-wide text-neutral-500">Application revision</dt><dd className="mt-1 break-all font-mono text-xs">{review.application_revision}</dd></div>
    </dl>
    <div className="grid gap-3 sm:grid-cols-3">
      <div className="bg-violet-50 p-4 text-sm text-violet-950"><strong>{review.manifest_results?.ticket_count}</strong><br />signed manifest tickets</div>
      <div className="bg-violet-50 p-4 text-sm text-violet-950"><strong>{review.device_results?.length}</strong><br />physical offline devices</div>
      <div className="bg-violet-50 p-4 text-sm text-violet-950"><strong>{review.reconciliation_results?.pending_queue_count}</strong><br />actions left queued</div>
    </div>
  </div>
}

export default function EventDayRehearsalReviewDialog({ event, onComplete }) {
  const [open, setOpen] = useState(false)
  const [details, setDetails] = useState(null)
  const [form, setForm] = useState(initialForm)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const triggerRef = useRef(null); const dialogRef = useRef(null); const closeRef = useRef(null)
  const rehearsal = details?.event_day_rehearsal || event.event_day_rehearsal || {}
  const pending = rehearsal.pending_submission; const approval = rehearsal.latest_approval
  const mode = rehearsal.approved ? 'approved' : pending ? 'pending' : 'submit'
  const complete = useMemo(() => scanScenarios.every(([key]) => form.scan_results[key]) &&
    controls.every(([key]) => form.controls[key]) && form.manifest_results.signature_verified_on_every_device &&
    form.device_results.every(device => device.physical_device && device.manifest_signature_verified && device.offline_mode_completed) &&
    incidents.every(([key]) => form.incident_drills[key].status === 'passed') &&
    form.reconciliation_results.all_card_attempts_resolved && form.reconciliation_results.all_devices_synced,
  [form])

  const load = async () => {
    setLoading(true); setError('')
    try { setDetails((await apiClient.get(`/admin/events/${event.id}/event_day_rehearsal`)).data) }
    catch (requestError) { setError(requestError.response?.data?.error || 'Gate G rehearsal could not be loaded.') }
    finally { setLoading(false) }
  }
  useEffect(() => {
    if (!open) return undefined
    load(); const trigger = triggerRef.current; const previousOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    const frame = window.requestAnimationFrame(() => closeRef.current?.focus())
    const onKeyDown = keyboardEvent => {
      if (keyboardEvent.key === 'Escape' && !busy) setOpen(false)
      if (keyboardEvent.key !== 'Tab' || !dialogRef.current) return
      const focusable = [...dialogRef.current.querySelectorAll('button:not([disabled]), input:not([disabled]), select:not([disabled]), [href], [tabindex]:not([tabindex="-1"])')]
      if (!focusable.length) return
      const first = focusable[0]; const last = focusable[focusable.length - 1]
      if (keyboardEvent.shiftKey && document.activeElement === first) { keyboardEvent.preventDefault(); last.focus() }
      else if (!keyboardEvent.shiftKey && document.activeElement === last) { keyboardEvent.preventDefault(); first.focus() }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => { window.cancelAnimationFrame(frame); window.removeEventListener('keydown', onKeyDown); document.body.style.overflow = previousOverflow; trigger?.focus() }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open])

  const request = async operation => {
    setBusy(true); setError('')
    try { await operation(); await load(); setForm(initialForm()); setReason(''); onComplete?.() }
    catch (requestError) { setError(requestError.response?.data?.error || 'The Gate G decision could not be recorded.') }
    finally { setBusy(false) }
  }
  const submit = submitEvent => {
    submitEvent.preventDefault()
    const payload = structuredClone(form)
    for (const key of ['version', 'ticket_count']) payload.manifest_results[key] = Number.parseInt(payload.manifest_results[key], 10)
    payload.manifest_results.generated_at = new Date(payload.manifest_results.generated_at).toISOString()
    payload.manifest_results.expires_at = new Date(payload.manifest_results.expires_at).toISOString()
    payload.device_results = payload.device_results.map(device => ({ ...device,
      reconnect_order: Number.parseInt(device.reconnect_order, 10), queued_actions_before_sync: Number.parseInt(device.queued_actions_before_sync, 10),
      queued_actions_after_sync: Number.parseInt(device.queued_actions_after_sync, 10), conflicts_observed: Number.parseInt(device.conflicts_observed, 10),
      immediate_feedback_p95_ms: Number.parseInt(device.immediate_feedback_p95_ms, 10),
    }))
    payload.reconciliation_results = Object.fromEntries(Object.entries(payload.reconciliation_results).map(([key, value]) =>
      [key, ['all_card_attempts_resolved', 'all_devices_synced'].includes(key) ? value : Number.parseInt(value, 10)]))
    payload.effective_at = new Date(payload.effective_at).toISOString(); payload.expires_at = new Date(payload.expires_at).toISOString()
    request(() => apiClient.post(`/admin/events/${event.id}/event_day_rehearsal_reviews`, payload))
  }
  const updateDevice = (index, field, value) => setForm(current => ({ ...current, device_results: current.device_results.map((device, position) => position === index ? { ...device, [field]: value } : device) }))
  const updateNested = (section, key, field, value) => setForm(current => ({ ...current, [section]: { ...current[section], [key]: { ...current[section][key], [field]: value } } }))
  const approve = () => request(() => apiClient.post(`/admin/event_day_rehearsal_reviews/${pending.id}/approve`))
  const reject = () => request(() => apiClient.post(`/admin/event_day_rehearsal_reviews/${pending.id}/reject`, { reason }))
  const revoke = revokeEvent => { revokeEvent.preventDefault(); request(() => apiClient.post(`/admin/event_day_rehearsal_reviews/${approval.id}/revoke`, { reason })) }

  return <>
    <button ref={triggerRef} type="button" onClick={() => setOpen(true)} className="inline-flex min-h-11 items-center gap-2 rounded-full border border-violet-200 bg-violet-50 px-3 py-2 text-xs font-semibold text-violet-900 transition-colors hover:bg-violet-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-violet-600 focus-visible:ring-offset-2">
      {rehearsal.approved || rehearsal.approval_recorded ? <ShieldCheck className="h-4 w-4" /> : <RadioTower className="h-4 w-4" />}
      {rehearsal.approved || rehearsal.approval_recorded ? 'Review rehearsal approval' : rehearsal.pending_submission ? 'Review rehearsal evidence' : 'Prepare Gate G rehearsal'}
    </button>
    {open && <div className="fixed inset-0 z-[100] flex items-end justify-center bg-neutral-950/60 backdrop-blur-sm sm:items-center sm:p-6" onMouseDown={mouseEvent => { if (mouseEvent.target === mouseEvent.currentTarget && !busy) setOpen(false) }}>
      <section ref={dialogRef} role="dialog" aria-modal="true" aria-labelledby="event-day-rehearsal-title" className="max-h-[96vh] w-full overflow-y-auto rounded-t-3xl bg-stone-50 shadow-2xl sm:max-w-6xl sm:rounded-3xl">
        <header className="sticky top-0 z-10 flex items-start justify-between gap-4 border-b border-stone-200 bg-stone-50/95 px-6 py-5 backdrop-blur sm:px-8"><div><p className="text-xs font-bold uppercase tracking-[0.18em] text-violet-800">Gate G · physical event-day rehearsal</p><h2 id="event-day-rehearsal-title" className="mt-1 text-2xl font-bold tracking-tight text-neutral-950">{event.title}</h2><p className="mt-1 max-w-4xl text-sm leading-relaxed text-neutral-600">Record the real signed-manifest, three-device offline, outage, door-sale, alert, staffing, and zero-variance rehearsal for the exact Gate F candidate.</p></div><button ref={closeRef} type="button" aria-label="Close Gate G rehearsal review" disabled={busy} onClick={() => setOpen(false)} className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full text-neutral-500 hover:bg-stone-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-violet-600"><X className="h-5 w-5" /></button></header>
        <div className="px-6 py-6 sm:px-8 sm:py-8">
          {error && <div role="alert" className="mb-6 flex items-start gap-3 border-l-4 border-red-600 bg-red-50 p-4 text-sm text-red-900"><ShieldAlert className="mt-0.5 h-5 w-5 shrink-0" /><p>{error}</p></div>}
          {loading && !details ? <div className="flex justify-center py-16"><Loader2 aria-label="Loading Gate G rehearsal" className="h-8 w-8 animate-spin text-violet-700" /></div> : <>
            {mode === 'submit' && <form onSubmit={submit} className="space-y-9">
              {!rehearsal.prerequisite_ready && <div className="border-l-4 border-amber-500 bg-amber-50 p-4 text-sm text-amber-950">Gate F must have a current approval before Gate G rehearsal evidence can be submitted.</div>}
              {approval && <div className="border-l-4 border-amber-500 bg-amber-50 p-4 text-sm text-amber-950">The prior rehearsal is expired, revoked, or stale. Submit a new complete record.</div>}
              <div className="grid gap-5 sm:grid-cols-2"><label className="text-sm font-semibold">Restricted evidence reference<input required value={form.evidence_reference} onChange={changeEvent => setForm(current => ({ ...current, evidence_reference: changeEvent.target.value }))} className="input mt-2" /></label><label className="text-sm font-semibold">Evidence SHA-256<input required pattern="[0-9a-f]{64}" value={form.evidence_digest} onChange={changeEvent => setForm(current => ({ ...current, evidence_digest: changeEvent.target.value.trim().toLowerCase() }))} className="input mt-2 font-mono text-xs" /></label><label className="text-sm font-semibold">Effective<input required type="datetime-local" value={form.effective_at} onChange={changeEvent => setForm(current => ({ ...current, effective_at: changeEvent.target.value }))} className="input mt-2" /></label><label className="text-sm font-semibold">Review by<input required type="datetime-local" value={form.expires_at} onChange={changeEvent => setForm(current => ({ ...current, expires_at: changeEvent.target.value }))} className="input mt-2" /></label></div>

              <fieldset><legend className="text-sm font-bold">Signed manifest and emergency list</legend><p className="mt-1 text-sm text-neutral-600">Use a controlled production-like rehearsal event. Gate G stores artifact references; it does not put attendee data in this record.</p><div className="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">{manifestFields.map(([key, label, type]) => <label key={key} className="text-xs font-semibold">{label}<input required type={type} min={type === 'number' ? 1 : undefined} pattern={key.includes('digest') ? '[0-9a-f]{64}' : undefined} value={form.manifest_results[key]} onChange={changeEvent => setForm(current => ({ ...current, manifest_results: { ...current.manifest_results, [key]: changeEvent.target.value } }))} className="input mt-1" /></label>)}</div><label className="mt-4 flex items-center gap-3 bg-white p-4 text-sm font-semibold"><input required type="checkbox" checked={form.manifest_results.signature_verified_on_every_device} onChange={changeEvent => setForm(current => ({ ...current, manifest_results: { ...current.manifest_results, signature_verified_on_every_device: changeEvent.target.checked } }))} className="h-5 w-5" /> Signature, digest, key ID, event, and expiry verified on every device</label></fieldset>

              <fieldset><legend className="flex items-center gap-2 text-sm font-bold"><Smartphone className="h-4 w-4 text-violet-700" /> Three distinct physical offline devices</legend><div className="mt-4 grid gap-4 lg:grid-cols-3">{form.device_results.map((device, index) => <div key={index} className="border-l-2 border-violet-300 bg-white p-4"><p className="font-bold">Physical device {index + 1}</p><div className="mt-3 grid gap-3">{deviceFields.map(([key, label, type]) => <label key={key} className="text-xs font-semibold">{label}<input required type={type} min={type === 'number' ? 0 : undefined} aria-label={`Device ${index + 1} ${label}`} value={device[key]} onChange={changeEvent => updateDevice(index, key, changeEvent.target.value)} className="input mt-1" /></label>)}</div>{[['physical_device', 'Physical device'], ['manifest_signature_verified', 'Manifest signature verified'], ['offline_mode_completed', 'Offline drill completed']].map(([key, label]) => <label key={key} className="mt-3 flex items-center gap-2 text-xs font-semibold"><input required type="checkbox" checked={device[key]} onChange={changeEvent => updateDevice(index, key, changeEvent.target.checked)} /> {label}</label>)}</div>)}</div></fieldset>

              <fieldset><legend className="text-sm font-bold">Required scan and reconnect scenarios</legend><div className="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">{scanScenarios.map(([key, label]) => <label key={key} className="flex min-h-12 items-start gap-3 border-l-2 border-stone-300 bg-white px-4 py-3 text-sm"><input type="checkbox" checked={form.scan_results[key]} onChange={changeEvent => setForm(current => ({ ...current, scan_results: { ...current.scan_results, [key]: changeEvent.target.checked } }))} className="mt-0.5 h-5 w-5" /><span>{label}</span></label>)}</div></fieldset>

              <fieldset><legend className="text-sm font-bold">Outage, incident, and escalation drills</legend><div className="mt-4 grid gap-4 lg:grid-cols-2">{incidents.map(([key, label]) => { const result = form.incident_drills[key]; return <div key={key} className="bg-white p-4"><div className="flex items-center justify-between gap-3"><p className="font-bold">{label}</p><select aria-label={`${label} status`} value={result.status} onChange={changeEvent => updateNested('incident_drills', key, 'status', changeEvent.target.value)} className="rounded-lg border border-neutral-300 px-2 py-1 text-xs"><option value="passed">Passed</option><option value="failed">Failed</option></select></div>{[['evidence_reference', 'Evidence reference'], ['alert_acknowledgement_reference', 'Alert acknowledgement reference'], ['resolution_reference', 'Resolution reference']].map(([field, fieldLabel]) => <label key={field} className="mt-3 block text-xs font-semibold">{fieldLabel}<input required aria-label={`${label} ${fieldLabel}`} value={result[field]} onChange={changeEvent => updateNested('incident_drills', key, field, changeEvent.target.value)} className="input mt-1" /></label>)}</div> })}</div></fieldset>

              <fieldset><legend className="text-sm font-bold">Door-sale decisions and reconciliation</legend><div className="mt-4 grid gap-4 lg:grid-cols-2">{[['cash', 'Cash'], ['card_present', 'Approved card-present']].map(([key, label]) => { const result = form.door_sales_results[key]; return <div key={key} className="bg-white p-4"><div className="flex items-center justify-between gap-3"><p className="font-bold">{label}</p><select aria-label={`${label} door-sale status`} value={result.status} onChange={changeEvent => updateNested('door_sales_results', key, 'status', changeEvent.target.value)} className="rounded-lg border border-neutral-300 px-2 py-1 text-xs"><option value="disabled">Disabled for pilot</option><option value="passed">Passed rehearsal</option></select></div>{result.status === 'disabled' ? <div><label className="mt-3 block text-xs font-semibold">Signed disablement reason<input required aria-label={`${label} disablement reason`} value={result.disabled_reason} onChange={changeEvent => updateNested('door_sales_results', key, 'disabled_reason', changeEvent.target.value)} className="input mt-1" /></label><label className="mt-3 block text-xs font-semibold">Signed decision reference<input required aria-label={`${label} signed disablement decision reference`} value={result.evidence_reference} onChange={changeEvent => updateNested('door_sales_results', key, 'evidence_reference', changeEvent.target.value)} className="input mt-1" /></label></div> : <div>{[['evidence_reference', 'Evidence reference'], ['reconciliation_reference', 'Reconciliation reference'], ...(key === 'card_present' ? [['provider', 'Approved provider'], ['account_readiness_reference', 'Account readiness reference'], ['successful_attempt_reference', 'Successful attempt reference'], ['unknown_outcome_reference', 'Unknown-outcome drill reference']] : [])].map(([field, fieldLabel]) => <label key={field} className="mt-3 block text-xs font-semibold">{fieldLabel}<input required aria-label={`${label} ${fieldLabel}`} value={result[field]} onChange={changeEvent => updateNested('door_sales_results', key, field, changeEvent.target.value)} className="input mt-1" /></label>)}{key === 'card_present' && <label className="mt-3 flex items-center gap-2 text-xs font-semibold"><input required type="checkbox" checked={result.no_blind_retry_confirmed} onChange={changeEvent => updateNested('door_sales_results', key, 'no_blind_retry_confirmed', changeEvent.target.checked)} /> Unknown results were not blindly retried</label>}</div>}</div> })}</div></fieldset>

              <fieldset><legend className="text-sm font-bold">Final reconciliation</legend><p className="mt-1 text-sm text-neutral-600">Expected and observed totals must match; all queues, conflicts, and unexplained money/inventory/admission variance must be zero.</p><div className="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">{reconciliationFields.map(([key, label]) => <label key={key} className="text-xs font-semibold">{label}<input required type="number" min="0" value={form.reconciliation_results[key]} onChange={changeEvent => setForm(current => ({ ...current, reconciliation_results: { ...current.reconciliation_results, [key]: changeEvent.target.value } }))} className="input mt-1" /></label>)}</div>{[['all_card_attempts_resolved', 'Every card-present attempt has a known final state'], ['all_devices_synced', 'Every device is synced and its queue is empty']].map(([key, label]) => <label key={key} className="mt-3 flex items-center gap-3 bg-white p-4 text-sm font-semibold"><input type="checkbox" checked={form.reconciliation_results[key] || false} onChange={changeEvent => setForm(current => ({ ...current, reconciliation_results: { ...current.reconciliation_results, [key]: changeEvent.target.checked } }))} className="h-5 w-5" />{label}</label>)}</fieldset>

              <fieldset><legend className="text-sm font-bold">Named event-day owners</legend><div className="mt-4 grid gap-4 lg:grid-cols-2">{assignments.map(([key, label]) => { const value = form.assignments[key]; return <div key={key} className="bg-white p-4"><p className="font-bold">{label}</p>{[['name', 'Name'], ['private_contact_reference', 'Private contact reference'], ['acknowledgement_reference', 'Acknowledgement reference']].map(([field, fieldLabel]) => <label key={field} className="mt-3 block text-xs font-semibold">{fieldLabel}<input required aria-label={`${label} ${fieldLabel}`} value={value[field]} onChange={changeEvent => updateNested('assignments', key, field, changeEvent.target.value)} className="input mt-1" /></label>)}</div> })}</div></fieldset>

              <fieldset><legend className="text-sm font-bold">Release controls</legend><div className="mt-3 grid gap-2 sm:grid-cols-2">{controls.map(([key, label]) => <label key={key} className="flex min-h-12 items-start gap-3 border-l-2 border-stone-300 bg-white px-4 py-3 text-sm"><input type="checkbox" checked={form.controls[key]} onChange={changeEvent => setForm(current => ({ ...current, controls: { ...current.controls, [key]: changeEvent.target.checked } }))} className="mt-0.5 h-5 w-5" /><span>{label}</span></label>)}</div></fieldset>
              <div className="flex flex-col-reverse gap-3 border-t pt-6 sm:flex-row sm:items-center sm:justify-between"><p className="text-xs text-neutral-500">A different administrator must inspect and approve this immutable rehearsal record.</p><button type="submit" disabled={busy || !complete || !rehearsal.prerequisite_ready} className="btn-primary min-h-11 disabled:opacity-50">{busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <RadioTower className="h-4 w-4" />} Submit Gate G rehearsal</button></div>
            </form>}

            {mode === 'pending' && <div className="space-y-7"><div className="border-l-4 border-amber-500 bg-amber-50 p-4"><p className="font-semibold">Independent decision required</p><p className="mt-1 text-sm">Admin #{pending.actor_user_id} submitted this exact rehearsal and cannot approve it.</p></div><EvidenceSummary review={pending} /><div><h3 className="text-sm font-bold">Recorded controls</h3><ul className="mt-3 grid gap-2 sm:grid-cols-2">{controls.map(([key, label]) => <li key={key} className="flex gap-2 text-sm"><Check className={`mt-0.5 h-4 w-4 ${pending.controls?.[key] ? 'text-emerald-700' : 'text-red-700'}`} />{label}</li>)}</ul></div><p className="text-sm text-neutral-600">Effective {formatDate(pending.effective_at)} · expires {formatDate(pending.expires_at)}</p><label className="block text-sm font-semibold">Rejection or correction reason<input value={reason} onChange={changeEvent => setReason(changeEvent.target.value)} className="input mt-2" /></label><div className="flex flex-col-reverse gap-3 border-t pt-6 sm:flex-row sm:justify-end"><button type="button" onClick={reject} disabled={busy || !reason.trim()} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-full border border-red-300 px-5 py-2.5 text-sm font-semibold text-red-800 disabled:opacity-50"><ShieldAlert className="h-4 w-4" /> Reject rehearsal</button><button type="button" onClick={approve} disabled={busy} className="btn-primary min-h-11 disabled:opacity-50"><ShieldCheck className="h-4 w-4" /> Approve exact rehearsal</button></div></div>}
            {mode === 'approved' && <form onSubmit={revoke} className="space-y-7"><div className="border-l-4 border-emerald-600 bg-emerald-50 p-4"><p className="font-semibold text-emerald-950">Current Gate G rehearsal approval</p><p className="mt-1 text-sm text-emerald-900">Approved by admin #{approval.actor_user_id}; expires {formatDate(approval.expires_at)}.</p></div><EvidenceSummary review={approval} /><label className="block text-sm font-semibold">Revocation reason<input required value={reason} onChange={changeEvent => setReason(changeEvent.target.value)} className="input mt-2" /></label><div className="flex justify-end border-t pt-6"><button type="submit" disabled={busy || !reason.trim()} className="inline-flex min-h-11 items-center gap-2 rounded-full bg-red-700 px-5 py-2.5 text-sm font-semibold text-white disabled:opacity-50"><ShieldAlert className="h-4 w-4" /> Revoke rehearsal</button></div></form>}
          </>}
        </div>
      </section>
    </div>}
  </>
}
