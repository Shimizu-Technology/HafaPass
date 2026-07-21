import { useEffect, useMemo, useRef, useState } from 'react'
import { Check, Gauge, Loader2, MonitorCheck, ShieldAlert, ShieldCheck, X } from 'lucide-react'
import apiClient from '../api/client'

const devices = [
  ['ios_safari', 'iOS Safari', true, true],
  ['android_chrome', 'Android Chrome', true, true],
  ['desktop_chrome', 'Desktop Chrome', true, false],
  ['desktop_safari', 'Desktop Safari', false, false],
  ['desktop_firefox', 'Desktop Firefox', false, false],
  ['desktop_edge', 'Desktop Edge', false, false],
]
const buyerFlows = [
  ['guest_browse_and_checkout', 'Guest browse and checkout'],
  ['authenticated_checkout', 'Authenticated checkout'],
  ['payment_return_and_recovery', 'Payment return and recovery'],
  ['refund', 'Refund'], ['transfer', 'Transfer'],
  ['wallet_or_documented_not_launching', 'Wallet, or documented decision not to launch it'],
  ['reminder', 'Reminder'], ['waitlist', 'Waitlist'], ['add_on', 'Add-on'],
  ['assigned_seat_or_not_applicable', 'Assigned seat, or documented not applicable'],
  ['ticket_presentation', 'Ticket presentation'], ['low_connectivity', 'Low connectivity'],
  ['recovery_after_browser_loss', 'Recovery after browser loss'],
]
const organizerFlows = [
  ['role_boundaries', 'Role boundaries'], ['event_lifecycle', 'Event lifecycle'], ['finance', 'Finance'],
  ['communications', 'Communications'], ['seating_or_not_applicable', 'Seating, or documented not applicable'],
  ['box_office', 'Box office'], ['support', 'Support'], ['admin_boundaries', 'Admin boundaries'],
]
const accessibilityChecks = [
  ['keyboard_only', 'Keyboard-only completion'], ['focus_and_dialogs', 'Focus order and dialogs'],
  ['errors_and_status_announcements', 'Errors and status announcements'], ['zoom_and_reflow', 'Zoom and reflow'],
  ['reduced_motion', 'Reduced motion'],
  ['equivalent_accessible_seat_discovery', 'Equivalent accessible-seat discovery'],
  ['equivalent_accessible_seat_purchase', 'Equivalent accessible-seat purchase'],
  ['no_medical_proof_request', 'No medical-proof request'],
]
const assistiveTechnology = [
  ['ios_voiceover', 'iOS VoiceOver'], ['android_talkback', 'Android TalkBack'],
  ['desktop_screen_reader', 'Desktop screen reader'],
]
const controls = [
  ['privacy_safe_artifacts', 'Screenshots and artifacts are privacy-safe'],
  ['representative_buyers_completed', 'Representative buyers completed the matrix'],
  ['venue_staff_completed', 'Representative venue staff completed their matrix'],
  ['findings_triaged', 'Every finding is severity-triaged'],
  ['all_findings_resolved', 'All release-blocking findings are resolved'],
  ['no_open_p0_or_p1', 'No P0 or P1 issue remains open'],
]
const loadFields = [
  ['scenario_name', 'Scenario name', 'text'], ['tool_name', 'Load tool and version', 'text'],
  ['target_environment', 'Isolated target environment', 'text'],
  ['expected_concurrent_buyers', 'Expected concurrent buyers', 'number'],
  ['executed_concurrent_buyers', 'Executed concurrent buyers', 'number'],
  ['request_count', 'Request count', 'number'], ['duration_seconds', 'Duration (seconds)', 'number'],
  ['p95_latency_ms', 'Observed p95 (ms)', 'number'], ['latency_budget_ms', 'p95 budget (ms)', 'number'],
  ['observed_error_rate_percent', 'Observed error rate (%)', 'number'],
  ['error_rate_budget_percent', 'Error-rate budget (%)', 'number'],
  ['peak_database_connections', 'Peak database connections', 'number'],
  ['database_connection_limit', 'Database connection limit', 'number'],
  ['inventory_contention_attempts', 'Inventory contention attempts', 'number'],
  ['seat_contention_attempts', 'Assigned-seat contention attempts', 'number'],
  ['expired_holds_expected', 'Expected hold expirations', 'number'],
  ['expired_holds_observed', 'Observed hold expirations', 'number'],
  ['oversell_count', 'Oversell count', 'number'], ['duplicate_sale_count', 'Duplicate-sale count', 'number'],
]
const integerLoadFields = new Set(loadFields.filter(([, , type]) => type === 'number').map(([key]) => key)
  .filter(key => !key.includes('rate_percent')))

const localDateTimeValue = date => {
  const pad = value => String(value).padStart(2, '0')
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`
}

const initialForm = () => {
  const effective = new Date()
  const expires = new Date(effective)
  expires.setDate(expires.getDate() + 14)
  return {
    evidence_reference: '', evidence_digest: '', effective_at: localDateTimeValue(effective),
    expires_at: localDateTimeValue(expires),
    device_matrix: Object.fromEntries(devices.map(([key, , required, physical]) => [key, {
      status: required ? 'passed' : 'unavailable', device_name: '', os_version: '', browser_version: '',
      tester_reference: '', evidence_reference: '', physical_device: physical, unavailable_reason: '',
    }])),
    buyer_flows: Object.fromEntries(buyerFlows.map(([key]) => [key, false])),
    organizer_flows: Object.fromEntries(organizerFlows.map(([key]) => [key, false])),
    accessibility_results: {
      checks: Object.fromEntries(accessibilityChecks.map(([key]) => [key, false])),
      assistive_technology: Object.fromEntries(assistiveTechnology.map(([key]) => [key, {
        status: 'passed', platform: '', technology_version: '', tester_reference: '', evidence_reference: '',
      }])),
      reviewer: { name: '', qualification_reference: '', evidence_reference: '' },
    },
    load_results: Object.fromEntries(loadFields.map(([key]) => [key, ['oversell_count', 'duplicate_sale_count', 'seat_contention_attempts'].includes(key) ? '0' : ''])),
    controls: Object.fromEntries(controls.map(([key]) => [key, false])),
  }
}

const formatDate = value => value ? new Date(value).toLocaleString() : 'Not recorded'

function EvidenceSummary({ review }) {
  return <div className="space-y-6">
    <dl className="grid gap-4 text-sm sm:grid-cols-2">
      <div className="border-l-2 border-brand-300 pl-3"><dt className="text-xs font-bold uppercase tracking-wide text-neutral-500">Evidence reference</dt><dd className="mt-1 break-all">{review.evidence_reference}</dd></div>
      <div className="border-l-2 border-brand-300 pl-3"><dt className="text-xs font-bold uppercase tracking-wide text-neutral-500">Evidence SHA-256</dt><dd className="mt-1 break-all font-mono text-xs">{review.evidence_digest}</dd></div>
      <div className="border-l-2 border-neutral-300 pl-3"><dt className="text-xs font-bold uppercase tracking-wide text-neutral-500">Application revision</dt><dd className="mt-1 break-all font-mono text-xs">{review.application_revision}</dd></div>
      <div className="border-l-2 border-neutral-300 pl-3"><dt className="text-xs font-bold uppercase tracking-wide text-neutral-500">Gate E approval</dt><dd className="mt-1 font-mono text-xs">#{review.pilot_readiness_review_id}</dd></div>
    </dl>
    <div><h3 className="text-sm font-bold text-neutral-950">Device matrix</h3><div className="mt-3 overflow-x-auto"><table className="w-full text-left text-sm"><thead><tr className="border-b text-xs text-neutral-500"><th className="py-2">Target</th><th>Status</th><th>Device</th><th>Versions</th></tr></thead><tbody>{devices.map(([key, label]) => { const item = review.device_matrix?.[key] || {}; return <tr key={key} className="border-b border-stone-200"><th className="py-2 font-semibold">{label}</th><td>{item.status}</td><td>{item.device_name || item.unavailable_reason}</td><td>{item.os_version && `${item.os_version} · ${item.browser_version}`}</td></tr> })}</tbody></table></div></div>
    <div className="border-l-4 border-cyan-600 bg-cyan-50 p-4 text-sm text-cyan-950"><strong>Load proof:</strong> {review.load_results?.executed_concurrent_buyers} buyers, {review.load_results?.request_count} requests, p95 {review.load_results?.p95_latency_ms} ms, {review.load_results?.observed_error_rate_percent}% errors, {review.load_results?.oversell_count} oversells.</div>
  </div>
}

export default function PilotValidationReviewDialog({ event, onComplete }) {
  const [open, setOpen] = useState(false)
  const [details, setDetails] = useState(null)
  const [form, setForm] = useState(initialForm)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const triggerRef = useRef(null)
  const dialogRef = useRef(null)
  const closeRef = useRef(null)
  const validation = details?.pilot_validation || event.pilot_validation || {}
  const pending = validation.pending_submission
  const approval = validation.latest_approval
  const mode = validation.approved ? 'approved' : pending ? 'pending' : 'submit'

  const complete = useMemo(() => {
    const deviceComplete = devices.every(([key, , required]) => {
      const item = form.device_matrix[key]
      if (item.status === 'unavailable') return !required && item.unavailable_reason.trim()
      return item.status === 'passed' && ['device_name', 'os_version', 'browser_version', 'tester_reference', 'evidence_reference'].every(field => item[field].trim())
    })
    const accessibilityComplete = accessibilityChecks.every(([key]) => form.accessibility_results.checks[key]) &&
      assistiveTechnology.every(([key]) => ['platform', 'technology_version', 'tester_reference', 'evidence_reference'].every(field => form.accessibility_results.assistive_technology[key][field].trim())) &&
      Object.values(form.accessibility_results.reviewer).every(value => value.trim())
    return deviceComplete && buyerFlows.every(([key]) => form.buyer_flows[key]) &&
      organizerFlows.every(([key]) => form.organizer_flows[key]) && accessibilityComplete &&
      loadFields.every(([key]) => String(form.load_results[key]).trim()) && form.load_results.all_holds_reconciled &&
      controls.every(([key]) => form.controls[key])
  }, [form])

  const load = async () => {
    setLoading(true); setError('')
    try { setDetails((await apiClient.get(`/admin/events/${event.id}/pilot_validation`)).data) }
    catch (requestError) { setError(requestError.response?.data?.error || 'Gate F validation could not be loaded.') }
    finally { setLoading(false) }
  }

  useEffect(() => {
    if (!open) return undefined
    load()
    const trigger = triggerRef.current
    const previousOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    const animationFrame = window.requestAnimationFrame(() => closeRef.current?.focus())
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
    return () => { window.cancelAnimationFrame(animationFrame); window.removeEventListener('keydown', onKeyDown); document.body.style.overflow = previousOverflow; trigger?.focus() }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open])

  const request = async operation => {
    setBusy(true); setError('')
    try { await operation(); await load(); setForm(initialForm()); setReason(''); onComplete?.() }
    catch (requestError) { setError(requestError.response?.data?.error || 'The Gate F decision could not be recorded.') }
    finally { setBusy(false) }
  }
  const submit = submitEvent => {
    submitEvent.preventDefault()
    const loadResults = Object.fromEntries(Object.entries(form.load_results).map(([key, value]) => {
      if (integerLoadFields.has(key)) return [key, Number.parseInt(value, 10)]
      if (key.includes('rate_percent')) return [key, Number.parseFloat(value)]
      return [key, value]
    }))
    request(() => apiClient.post(`/admin/events/${event.id}/pilot_validation_reviews`, {
      ...form, load_results: loadResults, effective_at: new Date(form.effective_at).toISOString(),
      expires_at: new Date(form.expires_at).toISOString(),
    }))
  }
  const approve = () => request(() => apiClient.post(`/admin/pilot_validation_reviews/${pending.id}/approve`))
  const reject = () => request(() => apiClient.post(`/admin/pilot_validation_reviews/${pending.id}/reject`, { reason }))
  const revoke = revokeEvent => { revokeEvent.preventDefault(); request(() => apiClient.post(`/admin/pilot_validation_reviews/${approval.id}/revoke`, { reason })) }
  const setMatrixValue = (matrix, key, value) => setForm(current => ({ ...current, [matrix]: { ...current[matrix], [key]: value } }))
  const updateDevice = (key, field, value) => setForm(current => ({ ...current, device_matrix: { ...current.device_matrix, [key]: { ...current.device_matrix[key], [field]: value } } }))
  const updateAssistive = (key, field, value) => setForm(current => ({ ...current, accessibility_results: { ...current.accessibility_results, assistive_technology: { ...current.accessibility_results.assistive_technology, [key]: { ...current.accessibility_results.assistive_technology[key], [field]: value } } } }))

  return <>
    <button ref={triggerRef} type="button" onClick={() => setOpen(true)} className="inline-flex min-h-11 items-center gap-2 rounded-full border border-cyan-200 bg-cyan-50 px-3 py-2 text-xs font-semibold text-cyan-900 transition-colors hover:bg-cyan-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-600 focus-visible:ring-offset-2">
      {validation.approved || validation.approval_recorded ? <ShieldCheck className="h-4 w-4" /> : <MonitorCheck className="h-4 w-4" />}
      {validation.approved || validation.approval_recorded ? 'Review QA approval' : validation.pending_submission ? 'Review QA evidence' : 'Prepare Gate F evidence'}
    </button>

    {open && <div className="fixed inset-0 z-[100] flex items-end justify-center bg-neutral-950/60 backdrop-blur-sm sm:items-center sm:p-6" onMouseDown={mouseEvent => { if (mouseEvent.target === mouseEvent.currentTarget && !busy) setOpen(false) }}>
      <section ref={dialogRef} role="dialog" aria-modal="true" aria-labelledby="pilot-validation-title" className="max-h-[96vh] w-full overflow-y-auto rounded-t-3xl bg-stone-50 shadow-2xl sm:max-w-5xl sm:rounded-3xl">
        <header className="sticky top-0 z-10 flex items-start justify-between gap-4 border-b border-stone-200 bg-stone-50/95 px-6 py-5 backdrop-blur sm:px-8"><div><p className="text-xs font-bold uppercase tracking-[0.18em] text-cyan-800">Gate F · candidate validation</p><h2 id="pilot-validation-title" className="mt-1 text-2xl font-bold tracking-tight text-neutral-950">{event.title}</h2><p className="mt-1 max-w-3xl text-sm leading-relaxed text-neutral-600">Record actual devices, representative-user flows, assistive technology, qualified review, and measured expected-onsale load for the exact Gate E candidate.</p></div><button ref={closeRef} type="button" aria-label="Close Gate F validation review" disabled={busy} onClick={() => setOpen(false)} className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full text-neutral-500 hover:bg-stone-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-600 disabled:opacity-50"><X className="h-5 w-5" /></button></header>
        <div className="px-6 py-6 sm:px-8 sm:py-8">
          {error && <div role="alert" className="mb-6 flex items-start gap-3 border-l-4 border-red-600 bg-red-50 p-4 text-sm text-red-900"><ShieldAlert className="mt-0.5 h-5 w-5 shrink-0" /><p>{error}</p></div>}
          {loading && !details ? <div className="flex justify-center py-16"><Loader2 aria-label="Loading Gate F validation" className="h-8 w-8 animate-spin text-cyan-700" /></div> : <>
            {mode === 'submit' && <form onSubmit={submit} className="space-y-9">
              {!validation.prerequisite_ready && <div className="border-l-4 border-amber-500 bg-amber-50 p-4 text-sm text-amber-950">Gate E must have a current approval before Gate F evidence can be submitted.</div>}
              {approval && <div className="border-l-4 border-amber-500 bg-amber-50 p-4 text-sm text-amber-950">Prior validation is expired, revoked, or stale. Submit a new complete candidate snapshot.</div>}
              <div className="grid gap-5 sm:grid-cols-2"><label className="text-sm font-semibold">Restricted evidence reference<input required value={form.evidence_reference} onChange={changeEvent => setForm(current => ({ ...current, evidence_reference: changeEvent.target.value }))} className="input mt-2" /></label><label className="text-sm font-semibold">Evidence SHA-256<input required pattern="[0-9a-f]{64}" minLength={64} maxLength={64} value={form.evidence_digest} onChange={changeEvent => setForm(current => ({ ...current, evidence_digest: changeEvent.target.value.trim().toLowerCase() }))} className="input mt-2 font-mono text-xs" /></label><label className="text-sm font-semibold">Effective<input required type="datetime-local" value={form.effective_at} onChange={changeEvent => setForm(current => ({ ...current, effective_at: changeEvent.target.value }))} className="input mt-2" /></label><label className="text-sm font-semibold">Review by<input required type="datetime-local" value={form.expires_at} onChange={changeEvent => setForm(current => ({ ...current, expires_at: changeEvent.target.value }))} className="input mt-2" /></label></div>

              <fieldset><legend className="flex items-center gap-2 text-sm font-bold"><MonitorCheck className="h-4 w-4 text-cyan-700" /> Real device and browser matrix</legend><p className="mt-1 text-sm text-neutral-600">iOS Safari, Android Chrome, and desktop Chrome must pass. Record a reason for any unavailable conditional desktop target.</p><div className="mt-4 grid gap-4 lg:grid-cols-2">{devices.map(([key, label, required, physical]) => { const item = form.device_matrix[key]; return <div key={key} className="border-l-2 border-stone-300 bg-white p-4"><div className="flex items-center justify-between gap-3"><p className="font-bold">{label}{required && <span className="ml-1 text-red-700">*</span>}</p>{!required && <select aria-label={`${label} status`} value={item.status} onChange={changeEvent => updateDevice(key, 'status', changeEvent.target.value)} className="rounded-lg border border-neutral-300 px-2 py-1 text-xs"><option value="unavailable">Unavailable</option><option value="passed">Passed</option></select>}</div>{item.status === 'passed' ? <div className="mt-3 grid gap-3 sm:grid-cols-2">{[['device_name', 'Device/model'], ['os_version', 'OS version'], ['browser_version', 'Browser version'], ['tester_reference', 'Private tester reference'], ['evidence_reference', 'Evidence reference']].map(([field, fieldLabel]) => <label key={field} className={`text-xs font-semibold ${field === 'evidence_reference' ? 'sm:col-span-2' : ''}`}>{fieldLabel}<input required aria-label={`${label} ${fieldLabel}`} value={item[field]} onChange={changeEvent => updateDevice(key, field, changeEvent.target.value)} className="input mt-1" /></label>)}{physical && <label className="flex items-center gap-2 text-xs font-semibold sm:col-span-2"><input type="checkbox" checked={item.physical_device} onChange={changeEvent => updateDevice(key, 'physical_device', changeEvent.target.checked)} /> Tested on a physical device</label>}</div> : <label className="mt-3 block text-xs font-semibold">Unavailable reason<input required aria-label={`${label} unavailable reason`} value={item.unavailable_reason} onChange={changeEvent => updateDevice(key, 'unavailable_reason', changeEvent.target.value)} className="input mt-1" /></label>}</div> })}</div></fieldset>

              {[['Buyer journeys', 'buyer_flows', buyerFlows], ['Organizer and staff journeys', 'organizer_flows', organizerFlows]].map(([legend, matrix, entries]) => <fieldset key={matrix}><legend className="text-sm font-bold">{legend}</legend><div className="mt-3 grid gap-2 sm:grid-cols-2">{entries.map(([key, label]) => <label key={key} className="flex min-h-12 items-start gap-3 border-l-2 border-stone-300 bg-white px-4 py-3 text-sm"><input type="checkbox" checked={form[matrix][key]} onChange={changeEvent => setMatrixValue(matrix, key, changeEvent.target.checked)} className="mt-0.5 h-5 w-5" /><span>{label}</span></label>)}</div></fieldset>)}

              <fieldset><legend className="text-sm font-bold">Accessibility and equivalent access</legend><div className="mt-3 grid gap-2 sm:grid-cols-2">{accessibilityChecks.map(([key, label]) => <label key={key} className="flex min-h-12 items-start gap-3 border-l-2 border-stone-300 bg-white px-4 py-3 text-sm"><input type="checkbox" checked={form.accessibility_results.checks[key]} onChange={changeEvent => setForm(current => ({ ...current, accessibility_results: { ...current.accessibility_results, checks: { ...current.accessibility_results.checks, [key]: changeEvent.target.checked } } }))} className="mt-0.5 h-5 w-5" /><span>{label}</span></label>)}</div><div className="mt-5 grid gap-4 lg:grid-cols-3">{assistiveTechnology.map(([key, label]) => { const item = form.accessibility_results.assistive_technology[key]; return <div key={key} className="bg-white p-4"><p className="font-bold">{label}</p>{[['platform', 'Device/platform'], ['technology_version', 'AT version'], ['tester_reference', 'Private tester reference'], ['evidence_reference', 'Evidence reference']].map(([field, fieldLabel]) => <label key={field} className="mt-3 block text-xs font-semibold">{fieldLabel}<input required aria-label={`${label} ${fieldLabel}`} value={item[field]} onChange={changeEvent => updateAssistive(key, field, changeEvent.target.value)} className="input mt-1" /></label>)}</div> })}</div><div className="mt-5 grid gap-4 sm:grid-cols-3">{[['name', 'Qualified reviewer name'], ['qualification_reference', 'Qualification reference'], ['evidence_reference', 'Sign-off evidence reference']].map(([field, label]) => <label key={field} className="text-xs font-semibold">{label}<input required value={form.accessibility_results.reviewer[field]} onChange={changeEvent => setForm(current => ({ ...current, accessibility_results: { ...current.accessibility_results, reviewer: { ...current.accessibility_results.reviewer, [field]: changeEvent.target.value } } }))} className="input mt-1" /></label>)}</div></fieldset>

              <fieldset><legend className="flex items-center gap-2 text-sm font-bold"><Gauge className="h-4 w-4 text-cyan-700" /> Expected-onsale load evidence</legend><p className="mt-1 text-sm text-neutral-600">Observed results must remain within the declared budgets, below the database limit, reconcile every hold, and prove zero oversells and duplicate sales.</p><div className="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">{loadFields.map(([key, label, type]) => <label key={key} className="text-xs font-semibold">{label}<input required type={type} min={type === 'number' ? 0 : undefined} step={key.includes('rate_percent') ? '0.01' : type === 'number' ? '1' : undefined} value={form.load_results[key]} onChange={changeEvent => setForm(current => ({ ...current, load_results: { ...current.load_results, [key]: changeEvent.target.value } }))} className="input mt-1" /></label>)}</div><label className="mt-4 flex items-center gap-3 bg-white p-4 text-sm font-semibold"><input type="checkbox" checked={form.load_results.all_holds_reconciled || false} onChange={changeEvent => setForm(current => ({ ...current, load_results: { ...current.load_results, all_holds_reconciled: changeEvent.target.checked } }))} className="h-5 w-5" /> Every test hold reached a known final state</label></fieldset>

              <fieldset><legend className="text-sm font-bold">Release evidence controls</legend><div className="mt-3 grid gap-2 sm:grid-cols-2">{controls.map(([key, label]) => <label key={key} className="flex min-h-12 items-start gap-3 border-l-2 border-stone-300 bg-white px-4 py-3 text-sm"><input type="checkbox" checked={form.controls[key]} onChange={changeEvent => setForm(current => ({ ...current, controls: { ...current.controls, [key]: changeEvent.target.checked } }))} className="mt-0.5 h-5 w-5" /><span>{label}</span></label>)}</div></fieldset>
              <div className="flex flex-col-reverse gap-3 border-t pt-6 sm:flex-row sm:items-center sm:justify-between"><p className="text-xs text-neutral-500">A different administrator must approve this immutable candidate record.</p><button type="submit" disabled={busy || !complete || !validation.prerequisite_ready} className="btn-primary min-h-11 disabled:opacity-50">{busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <MonitorCheck className="h-4 w-4" />} Submit Gate F evidence</button></div>
            </form>}

            {mode === 'pending' && <div className="space-y-7"><div className="border-l-4 border-amber-500 bg-amber-50 p-4"><p className="font-semibold">Independent decision required</p><p className="mt-1 text-sm">Admin #{pending.actor_user_id} submitted this exact candidate and cannot approve it.</p></div><EvidenceSummary review={pending} /><div><h3 className="text-sm font-bold">Recorded controls</h3><ul className="mt-3 grid gap-2 sm:grid-cols-2">{controls.map(([key, label]) => <li key={key} className="flex gap-2 text-sm"><Check className={`mt-0.5 h-4 w-4 ${pending.controls?.[key] ? 'text-emerald-700' : 'text-red-700'}`} />{label}</li>)}</ul></div><p className="text-sm text-neutral-600">Effective {formatDate(pending.effective_at)} · expires {formatDate(pending.expires_at)}</p><label className="block text-sm font-semibold">Rejection or correction reason<input value={reason} onChange={changeEvent => setReason(changeEvent.target.value)} className="input mt-2" /></label><div className="flex flex-col-reverse gap-3 border-t pt-6 sm:flex-row sm:justify-end"><button type="button" onClick={reject} disabled={busy || !reason.trim()} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-full border border-red-300 px-5 py-2.5 text-sm font-semibold text-red-800 disabled:opacity-50"><ShieldAlert className="h-4 w-4" /> Reject evidence</button><button type="button" onClick={approve} disabled={busy} className="btn-primary min-h-11 disabled:opacity-50"><ShieldCheck className="h-4 w-4" /> Approve exact candidate</button></div></div>}

            {mode === 'approved' && <form onSubmit={revoke} className="space-y-7"><div className="border-l-4 border-emerald-600 bg-emerald-50 p-4"><p className="font-semibold text-emerald-950">Current Gate F candidate approval</p><p className="mt-1 text-sm text-emerald-900">Approved by admin #{approval.actor_user_id}; expires {formatDate(approval.expires_at)}.</p></div><EvidenceSummary review={approval} /><label className="block text-sm font-semibold">Revocation reason<input required value={reason} onChange={changeEvent => setReason(changeEvent.target.value)} className="input mt-2" /></label><div className="flex justify-end border-t pt-6"><button type="submit" disabled={busy || !reason.trim()} className="inline-flex min-h-11 items-center gap-2 rounded-full bg-red-700 px-5 py-2.5 text-sm font-semibold text-white disabled:opacity-50"><ShieldAlert className="h-4 w-4" /> Revoke validation</button></div></form>}
          </>}
        </div>
      </section>
    </div>}
  </>
}
