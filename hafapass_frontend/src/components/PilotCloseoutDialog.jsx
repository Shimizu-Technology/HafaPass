import { useEffect, useMemo, useRef, useState } from 'react'
import { Check, ClipboardCheck, Loader2, Plus, Trash2, X } from 'lucide-react'
import apiClient from '../api/client'

const outcomeFields = [
  ['support_contacts_count', 'Support contacts'], ['entry_latency_p50_ms', 'Entry latency p50 (ms)'],
  ['entry_latency_p95_ms', 'Entry latency p95 (ms)'], ['organizer_feedback_rating', 'Organizer feedback (1–5)'],
  ['buyer_feedback_response_count', 'Buyer feedback responses'], ['buyer_feedback_rating', 'Buyer feedback (0 or 1–5)'],
]
const reconciliationFields = [
  ['sales', 'Sales'], ['discounts', 'Discounts'], ['taxes', 'Taxes'], ['fees', 'Fees'],
  ['refunds', 'Refunds'], ['disputes', 'Disputes'], ['add_ons', 'Add-ons'], ['door_sales', 'Cash/card door sales'],
  ['settlement', 'Settlement'], ['payout', 'Payout and bank receipt'], ['scans', 'Scans and no-shows'],
  ['support_cases', 'Support cases'], ['message_exceptions', 'Message exceptions'],
  ['admission_exceptions', 'Admission exceptions'], ['reconciliation_exceptions', 'Reconciliation exceptions'],
]
const cleanupFields = [
  ['temporary_staff_revoked', 'Temporary staff access revoked or expired'],
  ['scanner_devices_revoked', 'Scanner devices revoked'],
  ['device_local_data_purged', 'Device-local manifests, tokens, queues, and scan state purged under policy'],
  ['retention_policy_followed', 'Server evidence retained under the approved policy or legal hold'],
]
const evidenceFields = [
  ['financial', 'Financial reconciliation'], ['provider', 'Provider, settlement, payout, and bank'],
  ['admission', 'Admission and device closeout'], ['support', 'Support case closeout'],
  ['cleanup', 'Staff/device cleanup'], ['metrics', 'Metric exports'], ['feedback', 'Organizer and buyer feedback'],
  ['retrospective', 'Retrospective record'],
]
const investmentFields = [
  ['complex_charts', 'Complex venue charts'], ['waiting_room', 'High-demand waiting room'],
  ['memberships_season_products', 'Memberships or season products'],
]

const formatDate = value => value ? new Intl.DateTimeFormat('en-US', {
  dateStyle: 'medium', timeStyle: 'short', timeZone: 'Pacific/Guam',
}).format(new Date(value)) : '—'
const localInput = date => {
  const offset = date.getTimezoneOffset() * 60_000
  return new Date(date.getTime() - offset).toISOString().slice(0, 16)
}
const iso = value => value ? new Date(value).toISOString() : null
const blankBooleans = fields => Object.fromEntries(fields.map(([key]) => [key, false]))
const blankEvidence = Object.fromEntries(evidenceFields.map(([key]) => [key, '']))
const newAction = () => ({
  title: '', owner_reference: '', due_at: localInput(new Date(Date.now() + 7 * 86_400_000)),
  status: 'planned', priority: 'p2', evidence_reference: '', blocks_expansion: true,
})
const initialForm = () => ({
  evidence_reference: '', evidence_digest: '', expansion_decision: 'hold',
  outcome_metrics: {
    support_contacts_count: '0', entry_latency_p50_ms: '0', entry_latency_p95_ms: '0',
    organizer_feedback_rating: '5', buyer_feedback_response_count: '0', buyer_feedback_rating: '0',
  },
  reconciliation_results: blankBooleans(reconciliationFields), cleanup_results: blankBooleans(cleanupFields),
  evidence_references: blankEvidence, retrospective_actions: [newAction()],
  expansion_scope: {
    event_limit: '0', max_inventory_per_event: '0', expires_at: '', new_regions: false,
    recommended_product_investments: [], product_evidence_reference: '', demand_evidence_reference: '',
    capacity_evidence_reference: '', rationale: '',
  },
})

function MetricGrid({ metrics }) {
  if (!metrics) return null
  const featured = [
    ['completed_order_count', 'Orders'], ['checkout_conversion_bps', 'Conversion (bps)'],
    ['checkout_abandonment_bps', 'Abandonment (bps)'], ['no_show_rate_bps', 'No-shows (bps)'],
    ['refund_average_seconds', 'Avg. refund (sec)'], ['payout_variance_cents', 'Payout variance'],
    ['partner_attributed_order_count', 'Partner orders'], ['support_note_count', 'Support notes'],
  ]
  return <dl className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
    {featured.map(([key, label]) => <div key={key} className="border-l-2 border-sky-300 bg-white p-3">
      <dt className="text-xs font-bold uppercase text-neutral-500">{label}</dt><dd className="mt-1 text-xl font-bold">{metrics[key] ?? 0}</dd>
    </div>)}
  </dl>
}

function CloseoutSummary({ review }) {
  const metrics = review.metric_report || {}
  const references = review.evidence_references || {}
  const reconciliation = review.reconciliation_results || {}
  const cleanup = review.cleanup_results || {}
  const scope = review.expansion_scope || {}
  const investments = scope.recommended_product_investments || []
  return <div className="space-y-5">
    <div className="grid gap-3 sm:grid-cols-3">
      <div className="border-l-2 border-sky-300 pl-3"><p className="text-xs font-bold uppercase text-neutral-500">Decision</p><p className="mt-1 font-bold">{review.expansion_decision.replaceAll('_', ' ')}</p></div>
      <div className="border-l-2 border-sky-300 pl-3"><p className="text-xs font-bold uppercase text-neutral-500">Gate I run</p><p className="mt-1 font-bold">#{review.live_pilot_run_id}</p></div>
      <div className="border-l-2 border-sky-300 pl-3"><p className="text-xs font-bold uppercase text-neutral-500">Signed</p><p className="mt-1 font-bold">{formatDate(review.signed_at)}</p></div>
    </div>
    <MetricGrid metrics={metrics} />
    <section className="space-y-3"><h3 className="font-bold">Exact decision scope</h3><dl className="grid gap-3 text-sm sm:grid-cols-2 lg:grid-cols-4"><div className="bg-white p-3"><dt className="text-xs font-bold uppercase text-neutral-500">Event limit</dt><dd className="mt-1 font-bold">{scope.event_limit ?? '—'}</dd></div><div className="bg-white p-3"><dt className="text-xs font-bold uppercase text-neutral-500">Inventory per event</dt><dd className="mt-1 font-bold">{scope.max_inventory_per_event ?? '—'}</dd></div><div className="bg-white p-3"><dt className="text-xs font-bold uppercase text-neutral-500">Expires</dt><dd className="mt-1 font-bold">{formatDate(scope.expires_at)}</dd></div><div className="bg-white p-3"><dt className="text-xs font-bold uppercase text-neutral-500">New regions</dt><dd className="mt-1 font-bold">{scope.new_regions === false ? 'Not authorized' : 'Invalid or missing'}</dd></div></dl><p className="text-sm"><strong>Rationale:</strong> {scope.rationale || 'No rationale supplied'}</p>{investments.length > 0 && <p className="text-sm"><strong>Recommended investments:</strong> {investments.map(item => item.replaceAll('_', ' ')).join(', ')}</p>}<dl className="grid gap-2 text-xs sm:grid-cols-2">{[['demand_evidence_reference', 'Demand evidence'], ['capacity_evidence_reference', 'Capacity evidence'], ['product_evidence_reference', 'Product evidence']].filter(([key]) => scope[key]).map(([key, label]) => <div key={key} className="break-all bg-white p-3"><dt className="font-bold">{label}</dt><dd className="mt-1 font-mono">{scope[key]}</dd></div>)}</dl></section>
    <section><h3 className="font-bold">Externally observed outcomes</h3><dl className="mt-2 grid gap-2 text-sm sm:grid-cols-2 lg:grid-cols-3">{outcomeFields.map(([key, label]) => <div key={key} className="bg-white p-3"><dt className="text-xs font-bold text-neutral-500">{label}</dt><dd className="mt-1 font-bold">{metrics[key] ?? review.outcome_metrics?.[key] ?? '—'}</dd></div>)}</dl></section>
    <section><h3 className="font-bold">Restricted evidence references</h3><p className="mt-2 break-all bg-white p-3 text-xs text-neutral-700"><strong>Bundle:</strong> <span className="font-mono">{review.evidence_reference}</span><br /><strong>SHA-256:</strong> <span className="font-mono">{review.evidence_digest}</span></p><dl className="mt-2 grid gap-2 text-xs sm:grid-cols-2">{evidenceFields.map(([key, label]) => <div key={key} className="break-all bg-white p-3"><dt className="font-bold">{label}</dt><dd className="mt-1 font-mono">{references[key] || 'Missing'}</dd></div>)}</dl></section>
    <section className="grid gap-5 lg:grid-cols-2"><div><h3 className="font-bold">Reconciliation attestations</h3><ul className="mt-2 grid gap-2 text-sm sm:grid-cols-2">{reconciliationFields.map(([key, label]) => <li key={key} className={reconciliation[key] === true ? 'bg-emerald-50 p-3 text-emerald-950' : 'bg-red-50 p-3 text-red-950'}>{reconciliation[key] === true ? 'Confirmed' : 'Not confirmed'} · {label}</li>)}</ul></div><div><h3 className="font-bold">Cleanup attestations</h3><ul className="mt-2 space-y-2 text-sm">{cleanupFields.map(([key, label]) => <li key={key} className={cleanup[key] === true ? 'bg-emerald-50 p-3 text-emerald-950' : 'bg-red-50 p-3 text-red-950'}>{cleanup[key] === true ? 'Confirmed' : 'Not confirmed'} · {label}</li>)}</ul></div></section>
    <section><h3 className="font-bold">Retrospective actions</h3><ul className="mt-2 space-y-2 text-sm">{review.retrospective_actions.map((action, index) => <li key={index} className="bg-white p-3"><strong>{action.priority.toUpperCase()} · {action.title}</strong><span className="ml-2 text-neutral-500">{action.status} · due {formatDate(action.due_at)}{action.blocks_expansion ? ' · blocks expansion' : ''}</span><p className="mt-2 break-all text-xs text-neutral-600">Owner: <span className="font-mono">{action.owner_reference}</span> · Evidence: <span className="font-mono">{action.evidence_reference}</span></p></li>)}</ul></section>
    <p className="break-all text-xs text-neutral-600">Application revision: <span className="font-mono">{review.application_revision || '—'}</span><br />Local-state digest: <span className="font-mono">{review.local_state_digest || '—'}</span></p>
  </div>
}

export default function PilotCloseoutDialog({ event, onComplete }) {
  const [open, setOpen] = useState(false); const [details, setDetails] = useState(null)
  const [form, setForm] = useState(initialForm); const [reason, setReason] = useState('')
  const [loading, setLoading] = useState(false); const [busy, setBusy] = useState(false); const [error, setError] = useState('')
  const triggerRef = useRef(null); const closeRef = useRef(null)
  const closeout = details?.pilot_closeout || event.pilot_closeout || {}
  const pending = closeout.pending_submission; const approval = closeout.latest_approval
  const mode = pending ? 'pending' : closeout.approved ? 'approved' : 'submit'
  const allAttested = useMemo(() =>
    Object.values(form.reconciliation_results).every(Boolean) && Object.values(form.cleanup_results).every(Boolean),
  [form.reconciliation_results, form.cleanup_results])

  useEffect(() => {
    if (!open) return undefined
    const handler = keyEvent => { if (keyEvent.key === 'Escape' && !busy) setOpen(false) }
    document.addEventListener('keydown', handler); closeRef.current?.focus()
    return () => document.removeEventListener('keydown', handler)
  }, [open, busy])
  useEffect(() => { if (!open) triggerRef.current?.focus() }, [open])

  const load = async () => {
    setLoading(true); setError('')
    try { setDetails((await apiClient.get(`/admin/events/${event.id}/pilot_closeout`)).data) }
    catch (requestError) { setError(requestError.response?.data?.error || 'Gate J closeout could not be loaded.') }
    finally { setLoading(false) }
  }
  const request = async action => {
    setBusy(true); setError('')
    try { await action(); setReason(''); await load(); onComplete?.(); return true }
    catch (requestError) { setError(requestError.response?.data?.error || 'The Gate J decision could not be recorded.'); return false }
    finally { setBusy(false) }
  }
  const setSection = (section, key, value) => setForm(current => ({
    ...current, [section]: { ...current[section], [key]: value },
  }))
  const chooseDecision = decision => setForm(current => {
    const scope = { ...current.expansion_scope }
    if (decision === 'hold') Object.assign(scope, { event_limit: '0', max_inventory_per_event: '0', expires_at: '' })
    if (decision === 'repeat_bounded_pilot') Object.assign(scope, { event_limit: '1', max_inventory_per_event: '250', expires_at: localInput(new Date(Date.now() + 30 * 86_400_000)) })
    if (decision === 'limited_guam_expansion') Object.assign(scope, { event_limit: '3', max_inventory_per_event: '500', expires_at: localInput(new Date(Date.now() + 60 * 86_400_000)) })
    return { ...current, expansion_decision: decision, expansion_scope: scope }
  })
  const changeAction = (index, key, value) => setForm(current => ({
    ...current, retrospective_actions: current.retrospective_actions.map((action, actionIndex) =>
      actionIndex === index ? { ...action, [key]: value } : action),
  }))
  const submit = submitEvent => {
    submitEvent.preventDefault()
    request(() => apiClient.post(`/admin/events/${event.id}/pilot_closeout_reviews`, {
      ...form,
      outcome_metrics: Object.fromEntries(Object.entries(form.outcome_metrics).map(([key, value]) => [key, Number(value)])),
      retrospective_actions: form.retrospective_actions.map(action => ({ ...action, due_at: iso(action.due_at) })),
      expansion_scope: {
        ...form.expansion_scope, event_limit: Number(form.expansion_scope.event_limit),
        max_inventory_per_event: Number(form.expansion_scope.max_inventory_per_event),
        expires_at: iso(form.expansion_scope.expires_at), new_regions: false,
      },
    }))
  }
  const toggleInvestment = key => setForm(current => {
    const selected = current.expansion_scope.recommended_product_investments
    return { ...current, expansion_scope: { ...current.expansion_scope,
      recommended_product_investments: selected.includes(key) ? selected.filter(item => item !== key) : [...selected, key],
    } }
  })

  const triggerLabel = event.pilot_closeout?.pending_submission ? 'Review Gate J closeout' :
    event.pilot_closeout?.approved ? `Gate J · ${event.pilot_closeout.expansion_decision?.replaceAll('_', ' ')}` :
      event.pilot_closeout?.approval_recorded ? 'Revalidate Gate J closeout' : 'Prepare Gate J closeout'

  return <>
    <button ref={triggerRef} type="button" onClick={() => { setOpen(true); load() }} className="min-h-11 text-left text-xs font-semibold text-violet-800 underline decoration-violet-300 underline-offset-4 hover:text-violet-950">{triggerLabel}</button>
    {open && <div role="presentation" className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-neutral-950/55 px-3 py-4 sm:px-6 sm:py-8" onMouseDown={mouseEvent => { if (mouseEvent.target === mouseEvent.currentTarget && !busy) setOpen(false) }}>
      <section role="dialog" aria-modal="true" aria-labelledby="pilot-closeout-title" className="w-full max-w-7xl overflow-hidden rounded-2xl bg-stone-50 shadow-2xl">
        <header className="sticky top-0 z-10 flex items-start justify-between gap-4 border-b bg-stone-50/95 px-6 py-5 backdrop-blur sm:px-8"><div><p className="text-xs font-bold uppercase tracking-[0.18em] text-violet-800">Gate J · close out before expanding</p><h2 id="pilot-closeout-title" className="mt-1 text-2xl font-bold">{details?.event?.title || event.title}</h2><p className="mt-1 max-w-4xl text-sm text-neutral-600">Reconcile the completed pilot, measure customer and operating outcomes, close access and device obligations, approve retrospective actions, and make an explicit Guam expansion decision.</p></div><button ref={closeRef} type="button" aria-label="Close Gate J pilot closeout" disabled={busy} onClick={() => setOpen(false)} className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full hover:bg-stone-200"><X className="h-5 w-5" /></button></header>
        <div className="px-6 py-6 sm:px-8 sm:py-8">
          {error && <p role="alert" className="mb-6 border-l-4 border-red-600 bg-red-50 p-4 text-sm text-red-900">{error}</p>}
          {loading && !details ? <div className="flex justify-center py-16"><Loader2 aria-label="Loading Gate J closeout" className="h-8 w-8 animate-spin text-violet-700" /></div> : <>
            {!closeout.eligible && <div className="border-l-4 border-amber-500 bg-amber-50 p-5 text-amber-950"><strong>Gate J is not eligible yet.</strong><p className="mt-1 text-sm">Complete and reconcile a real Gate I run before recording closeout evidence.</p></div>}
            {mode === 'submit' && closeout.eligible && <form onSubmit={submit} className="space-y-10">
              {approval && <div className="border-l-4 border-amber-500 bg-amber-50 p-4 text-sm text-amber-950">The recorded approval is revoked, application-stale, or no longer matches local operations. Submit a new exact closeout snapshot.</div>}
              <section className="space-y-4"><h3 className="text-lg font-bold">System-calculated closeout</h3><p className="text-sm text-neutral-600">HafaPass recalculates these values at submission and approval. A later payment, refund, dispute, payout, scan, message, support note, device, staff, or funnel change invalidates the decision.</p><MetricGrid metrics={closeout.local_metrics} /></section>
              <fieldset className="space-y-4"><legend className="text-lg font-bold">Signed restricted evidence bundle</legend><div className="grid gap-4 sm:grid-cols-2"><label className="text-xs font-semibold">Bundle reference<input required value={form.evidence_reference} onChange={change => setForm(current => ({ ...current, evidence_reference: change.target.value }))} className="input mt-1" /></label><label className="text-xs font-semibold">Bundle SHA-256<input required pattern="[0-9a-f]{64}" value={form.evidence_digest} onChange={change => setForm(current => ({ ...current, evidence_digest: change.target.value.trim().toLowerCase() }))} className="input mt-1 font-mono text-xs" /></label>{evidenceFields.map(([key, label]) => <label key={key} className="text-xs font-semibold">{label} reference<input required value={form.evidence_references[key]} onChange={change => setSection('evidence_references', key, change.target.value)} className="input mt-1" /></label>)}</div></fieldset>
              <fieldset><legend className="text-lg font-bold">Measured outcomes</legend><p className="mt-1 text-sm text-neutral-600">Conversion, abandonment, no-shows, refund time, payout accuracy/time, and attribution are calculated locally. Enter externally observed support, entry, and feedback measures.</p><div className="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">{outcomeFields.map(([key, label]) => <label key={key} className="text-xs font-semibold">{label}<input required type="number" min={key.includes('feedback_rating') ? 0 : 0} max={key.includes('feedback_rating') ? 5 : undefined} value={form.outcome_metrics[key]} onChange={change => setSection('outcome_metrics', key, change.target.value)} className="input mt-1" /></label>)}</div></fieldset>
              <fieldset><legend className="text-lg font-bold">Reconciliation attestations</legend><div className="mt-4 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">{reconciliationFields.map(([key, label]) => <label key={key} className="flex gap-3 bg-white p-3 text-sm"><input type="checkbox" checked={form.reconciliation_results[key]} onChange={change => setSection('reconciliation_results', key, change.target.checked)} className="h-5 w-5" />{label} reconciled</label>)}</div></fieldset>
              <fieldset><legend className="text-lg font-bold">Access, device, and retention closeout</legend><div className="mt-4 grid gap-2 sm:grid-cols-2">{cleanupFields.map(([key, label]) => <label key={key} className="flex gap-3 bg-white p-3 text-sm"><input type="checkbox" checked={form.cleanup_results[key]} onChange={change => setSection('cleanup_results', key, change.target.checked)} className="h-5 w-5" />{label}</label>)}</div></fieldset>
              <fieldset className="space-y-4"><div className="flex items-center justify-between"><legend className="text-lg font-bold">Retrospective actions</legend><button type="button" onClick={() => setForm(current => ({ ...current, retrospective_actions: [...current.retrospective_actions, newAction()] }))} className="min-h-11 rounded-full border px-4 text-sm font-semibold"><Plus className="mr-1 inline h-4 w-4" />Add action</button></div>{form.retrospective_actions.map((action, index) => <div key={index} className="grid gap-3 bg-white p-4 sm:grid-cols-2 lg:grid-cols-4"><label className="text-xs font-semibold lg:col-span-2">Action<input required value={action.title} onChange={change => changeAction(index, 'title', change.target.value)} className="input mt-1" /></label><label className="text-xs font-semibold">Owner reference<input required value={action.owner_reference} onChange={change => changeAction(index, 'owner_reference', change.target.value)} className="input mt-1" /></label><label className="text-xs font-semibold">Due<input required type="datetime-local" value={action.due_at} onChange={change => changeAction(index, 'due_at', change.target.value)} className="input mt-1" /></label><label className="text-xs font-semibold">Status<select value={action.status} onChange={change => changeAction(index, 'status', change.target.value)} className="input mt-1"><option value="planned">Planned</option><option value="completed">Completed</option></select></label><label className="text-xs font-semibold">Priority<select value={action.priority} onChange={change => changeAction(index, 'priority', change.target.value)} className="input mt-1">{['p0', 'p1', 'p2', 'p3'].map(item => <option key={item}>{item}</option>)}</select></label><label className="text-xs font-semibold lg:col-span-2">Action evidence reference<input required value={action.evidence_reference} onChange={change => changeAction(index, 'evidence_reference', change.target.value)} className="input mt-1" /></label><label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={action.blocks_expansion} onChange={change => changeAction(index, 'blocks_expansion', change.target.checked)} className="h-5 w-5" />Blocks expansion until complete</label>{form.retrospective_actions.length > 1 && <button type="button" aria-label={`Remove retrospective action ${index + 1}`} onClick={() => setForm(current => ({ ...current, retrospective_actions: current.retrospective_actions.filter((_, itemIndex) => itemIndex !== index) }))} className="min-h-11 text-red-700"><Trash2 className="mx-auto h-4 w-4" /></button>}</div>)}</fieldset>
              <fieldset className="space-y-4"><legend className="text-lg font-bold">Explicit expansion decision</legend><div className="border-l-4 border-violet-500 bg-violet-50 p-4 text-sm text-violet-950">This records a governed decision; it does not invent demand, provider capacity, or customer evidence, enable unfinished features, authorize a new region, or bypass event-specific release gates.</div><div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3"><label className="text-xs font-semibold">Decision<select value={form.expansion_decision} onChange={change => chooseDecision(change.target.value)} className="input mt-1"><option value="hold">Hold expansion</option><option value="repeat_bounded_pilot">Repeat one bounded pilot</option><option value="limited_guam_expansion">Limited Guam expansion</option></select></label><label className="text-xs font-semibold">Event limit<input required type="number" min="0" max="10" value={form.expansion_scope.event_limit} onChange={change => setSection('expansion_scope', 'event_limit', change.target.value)} className="input mt-1" /></label><label className="text-xs font-semibold">Max inventory per event<input required type="number" min="0" max="1000" value={form.expansion_scope.max_inventory_per_event} onChange={change => setSection('expansion_scope', 'max_inventory_per_event', change.target.value)} className="input mt-1" /></label>{form.expansion_decision !== 'hold' && <label className="text-xs font-semibold">Decision expires<input required type="datetime-local" value={form.expansion_scope.expires_at} onChange={change => setSection('expansion_scope', 'expires_at', change.target.value)} className="input mt-1" /></label>}{form.expansion_decision === 'limited_guam_expansion' && <><label className="text-xs font-semibold">Demand evidence reference<input required value={form.expansion_scope.demand_evidence_reference} onChange={change => setSection('expansion_scope', 'demand_evidence_reference', change.target.value)} className="input mt-1" /></label><label className="text-xs font-semibold">Capacity evidence reference<input required value={form.expansion_scope.capacity_evidence_reference} onChange={change => setSection('expansion_scope', 'capacity_evidence_reference', change.target.value)} className="input mt-1" /></label></>}<label className="text-xs font-semibold sm:col-span-2 lg:col-span-3">Rationale<textarea required value={form.expansion_scope.rationale} onChange={change => setSection('expansion_scope', 'rationale', change.target.value)} className="input mt-1 min-h-24" /></label></div><div><p className="text-sm font-bold">Measured product investments to prioritize</p><div className="mt-2 flex flex-wrap gap-3">{investmentFields.map(([key, label]) => <label key={key} className="flex gap-2 text-sm"><input type="checkbox" checked={form.expansion_scope.recommended_product_investments.includes(key)} onChange={() => toggleInvestment(key)} className="h-5 w-5" />{label}</label>)}</div>{form.expansion_scope.recommended_product_investments.length > 0 && <label className="mt-3 block text-xs font-semibold">Product demand/capacity evidence reference<input required value={form.expansion_scope.product_evidence_reference} onChange={change => setSection('expansion_scope', 'product_evidence_reference', change.target.value)} className="input mt-1" /></label>}</div></fieldset>
              <div className="flex justify-end border-t pt-6"><button disabled={busy || !allAttested} className="btn-primary min-h-11 disabled:opacity-50"><ClipboardCheck className="h-4 w-4" /> Sign and submit Gate J closeout</button></div>
            </form>}
            {mode === 'pending' && <div className="space-y-7"><div className="border-l-4 border-amber-500 bg-amber-50 p-4 text-sm text-amber-950"><strong>Independent decision required.</strong> A different administrator must inspect the restricted evidence and approve this exact state-bound snapshot.</div><CloseoutSummary review={pending} /><label className="block text-sm font-semibold">Rejection reason<input value={reason} onChange={change => setReason(change.target.value)} className="input mt-2" /></label><div className="flex flex-wrap justify-end gap-3 border-t pt-6"><button disabled={busy || !reason.trim()} onClick={() => request(() => apiClient.post(`/admin/pilot_closeout_reviews/${pending.id}/reject`, { reason }))} className="min-h-11 rounded-full border border-red-300 px-5 font-semibold text-red-800 disabled:opacity-50">Reject closeout</button><button disabled={busy} onClick={() => request(() => apiClient.post(`/admin/pilot_closeout_reviews/${pending.id}/approve`))} className="btn-primary min-h-11"><Check className="h-4 w-4" /> Approve exact Gate J decision</button></div></div>}
            {mode === 'approved' && <div className="space-y-7"><div className="border-l-4 border-emerald-600 bg-emerald-50 p-5 text-emerald-950"><strong>Gate J closeout independently approved.</strong><p className="mt-1 text-sm">Expansion decision: {approval.expansion_decision.replaceAll('_', ' ')}. External evidence remains subject to its owners and retention policy.</p></div><CloseoutSummary review={approval} /><label className="block text-sm font-semibold">Revocation reason<input value={reason} onChange={change => setReason(change.target.value)} className="input mt-2" /></label><div className="flex justify-end"><button disabled={busy || !reason.trim()} onClick={() => request(() => apiClient.post(`/admin/pilot_closeout_reviews/${approval.id}/revoke`, { reason }))} className="min-h-11 rounded-full bg-red-700 px-5 font-semibold text-white disabled:opacity-50">Revoke Gate J approval</button></div></div>}
          </>}
        </div>
      </section>
    </div>}
  </>
}
