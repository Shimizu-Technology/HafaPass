import { useEffect, useMemo, useRef, useState } from 'react'
import { Banknote, Check, ExternalLink, Loader2, ShieldAlert, ShieldCheck, X } from 'lucide-react'
import apiClient from '../api/client'

const entityFields = [
  ['legal_entity_reference', 'Approved legal-entity reference'], ['organizer_reference', 'Actual organizer reference'],
  ['bank_account_reference', 'Verified bank-account reference'], ['provider_approval_reference', 'Production-provider approval reference'],
  ['charge_provider', 'Charge provider'], ['payout_provider', 'Payout provider'],
]
const providerFields = [
  ['charge_reference', 'Provider charge reference', 'text'], ['charge_amount_cents', 'Charge amount (cents)', 'number'],
  ['currency', 'Currency', 'text'], ['partial_refund_reference', 'Partial-refund reference', 'text'],
  ['partial_refund_amount_cents', 'Partial refund (cents)', 'number'], ['final_refund_reference', 'Final-refund reference', 'text'],
  ['final_refund_amount_cents', 'Final refund (cents)', 'number'], ['initial_settlement_digest', 'Initial settlement SHA-256', 'text'],
  ['payout_reference', 'Payout/provider reference', 'text'], ['payout_amount_cents', 'Payout amount (cents)', 'number'],
  ['bank_receipt_reference', 'Restricted bank-receipt reference', 'text'], ['bank_receipt_digest', 'Bank receipt SHA-256', 'text'],
  ['bank_receipt_amount_cents', 'Bank receipt amount (cents)', 'number'],
  ['post_payout_settlement_digest', 'Post-payout settlement SHA-256', 'text'],
  ['post_payout_negative_balance_cents', 'Negative balance (cents)', 'number'],
]
const reconciliationFields = [
  ['provider_charge_cents', 'Provider charge'], ['local_charge_cents', 'Local charge'], ['charge_variance_cents', 'Charge variance'],
  ['provider_refund_cents', 'Provider refunds'], ['local_refund_cents', 'Local refunds'], ['refund_variance_cents', 'Refund variance'],
  ['provider_processing_fee_cents', 'Provider processing fee'], ['local_processing_fee_cents', 'Local processing fee'],
  ['processing_fee_variance_cents', 'Processing variance'], ['provider_payout_cents', 'Provider payout'],
  ['local_payout_cents', 'Local payout'], ['bank_receipt_cents', 'Bank receipt'], ['payout_variance_cents', 'Payout variance'],
  ['local_negative_balance_cents', 'Local negative balance'], ['negative_balance_variance_cents', 'Negative-balance variance'],
  ['open_reconciliation_exception_count', 'Open reconciliation exceptions'], ['open_dispute_count', 'Open disputes'],
  ['pending_refund_count', 'Pending refunds'],
]
const communicationKeys = [
  ['buyer_charge_receipt', 'Buyer charge receipt'], ['buyer_partial_refund_notice', 'Buyer partial-refund notice'],
  ['buyer_final_refund_notice', 'Buyer final-refund notice'], ['organizer_settlement_statement', 'Organizer settlement statement'],
  ['organizer_payout_notice', 'Organizer payout notice'], ['support_order_trace', 'Support order trace'],
]
const controlFields = [
  ['actual_entity_verified', 'Actual HafaPass entity verified'], ['actual_organizer_verified', 'Actual organizer verified'],
  ['actual_bank_verified', 'Actual settlement bank verified'], ['production_provider_verified', 'Production provider verified'],
  ['live_charge_confirmed', 'Low-value live charge confirmed'], ['partial_refund_confirmed', 'Partial refund confirmed'],
  ['full_refund_confirmed', 'Full refund confirmed'], ['initial_settlement_finalized', 'Initial settlement finalized'],
  ['payout_paid', 'Payout paid'], ['bank_receipt_confirmed', 'Bank receipt confirmed'],
  ['post_payout_negative_balance_confirmed', 'Post-payout negative balance confirmed'],
  ['communications_confirmed', 'Buyer, organizer, and support visibility confirmed'],
  ['zero_unexplained_variance', 'Every unexplained variance is zero'], ['no_open_exceptions', 'No open exception, dispute, or refund'],
  ['explicit_go_decision', 'Finance lead recorded explicit go decision'],
]
const recordFields = [
  ['payment_id', 'Payment ID'], ['partial_refund_id', 'Partial refund ID'], ['final_refund_id', 'Final refund ID'],
  ['initial_settlement_id', 'Initial settlement ID'], ['payout_id', 'Payout ID'],
  ['post_payout_settlement_id', 'Post-payout settlement ID'], ['event_day_rehearsal_review_id', 'Gate G approval ID'],
]
const pad = value => String(value).padStart(2, '0')
const localDateTime = value => {
  const date = new Date(value)
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`
}
const initialEvidence = () => {
  const now = new Date(); const expiry = new Date(now); expiry.setDate(expiry.getDate() + 30)
  return {
    evidence_reference: '', evidence_digest: '', effective_at: localDateTime(now), expires_at: localDateTime(expiry),
    authorization_id: '', order_id: '', payment_id: '', partial_refund_id: '', final_refund_id: '',
    initial_settlement_id: '', payout_id: '', post_payout_settlement_id: '', event_day_rehearsal_review_id: '',
    entity_results: Object.fromEntries(entityFields.map(([key]) => [key, key === 'charge_provider' ? 'stripe' : ''])),
    provider_results: Object.fromEntries(providerFields.map(([key]) => [key, key === 'currency' ? 'usd' : ''])),
    reconciliation_results: Object.fromEntries(reconciliationFields.map(([key]) => [key,
      key.includes('variance') || key.includes('count') ? '0' : ''])),
    communication_results: Object.fromEntries(communicationKeys.map(([key]) => [key, { status: 'confirmed', evidence_reference: '' }])),
    controls: Object.fromEntries(controlFields.map(([key]) => [key, false])),
    entity_production_environment: true,
  }
}
const inputClass = 'input mt-1'
const formatDate = value => value ? new Date(value).toLocaleString() : 'Not recorded'

function Summary({ review }) {
  return <dl className="grid gap-4 text-sm sm:grid-cols-2 lg:grid-cols-3">
    <div className="border-l-2 border-emerald-400 pl-3"><dt className="text-xs font-bold uppercase text-neutral-500">Proof order</dt><dd>#{review.order_id}</dd></div>
    <div className="border-l-2 border-emerald-400 pl-3"><dt className="text-xs font-bold uppercase text-neutral-500">Payout</dt><dd>#{review.payout_id}</dd></div>
    <div className="border-l-2 border-emerald-400 pl-3"><dt className="text-xs font-bold uppercase text-neutral-500">Bank receipt</dt><dd className="break-all">{review.provider_results?.bank_receipt_reference}</dd></div>
    <div className="border-l-2 border-neutral-300 pl-3"><dt className="text-xs font-bold uppercase text-neutral-500">Evidence</dt><dd className="break-all">{review.evidence_reference}</dd></div>
    <div className="border-l-2 border-neutral-300 pl-3"><dt className="text-xs font-bold uppercase text-neutral-500">Effective</dt><dd>{formatDate(review.effective_at)}</dd></div>
    <div className="border-l-2 border-neutral-300 pl-3"><dt className="text-xs font-bold uppercase text-neutral-500">Review by</dt><dd>{formatDate(review.expires_at)}</dd></div>
  </dl>
}

export default function LiveMoneyProofReviewDialog({ event, onComplete }) {
  const [open, setOpen] = useState(false)
  const [details, setDetails] = useState(null)
  const [authorizationForm, setAuthorizationForm] = useState({ buyer_email: '', max_amount_cents: '500', expires_at: localDateTime(new Date(Date.now() + 60 * 60 * 1000)) })
  const [form, setForm] = useState(initialEvidence)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false); const [loading, setLoading] = useState(false); const [error, setError] = useState('')
  const triggerRef = useRef(null); const dialogRef = useRef(null); const closeRef = useRef(null)
  const proof = details?.live_money_proof || event.live_money_proof || {}
  const authorization = details?.authorization
  const pending = proof.pending_submission; const approval = proof.latest_approval
  const authorizationExpired = authorization && new Date(authorization.expires_at) <= new Date()
  const mode = proof.approved ? 'approved' : pending ? 'pending' : !event.live_money_proof_candidate ? 'not-candidate' :
    (!authorization || authorization.revoked_at || authorizationExpired) ? 'authorize' : !authorization.approved_at ? 'approve-authorization' :
      !authorization.order_id ? 'run' : 'submit'
  const allControls = useMemo(() => controlFields.every(([key]) => form.controls[key]), [form.controls])

  const load = async () => {
    setLoading(true); setError('')
    try {
      const response = await apiClient.get(`/admin/events/${event.id}/live_money_proof`)
      setDetails(response.data)
      if (response.data.authorization) setForm(current => ({ ...current,
        authorization_id: String(response.data.authorization.id), order_id: String(response.data.authorization.order_id || ''),
        event_day_rehearsal_review_id: String(response.data.authorization.event_day_rehearsal_review_id || ''),
      }))
    } catch (requestError) { setError(requestError.response?.data?.error || 'Gate H proof could not be loaded.') }
    finally { setLoading(false) }
  }
  useEffect(() => {
    if (!open) return undefined
    load(); const trigger = triggerRef.current; const overflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'; const frame = window.requestAnimationFrame(() => closeRef.current?.focus())
    const onKeyDown = keyboardEvent => {
      if (keyboardEvent.key === 'Escape' && !busy) setOpen(false)
      if (keyboardEvent.key !== 'Tab' || !dialogRef.current) return
      const focusable = [...dialogRef.current.querySelectorAll('button:not([disabled]), input:not([disabled]), [href], [tabindex]:not([tabindex="-1"])')]
      if (!focusable.length) return
      const first = focusable[0]; const last = focusable[focusable.length - 1]
      if (keyboardEvent.shiftKey && document.activeElement === first) { keyboardEvent.preventDefault(); last.focus() }
      else if (!keyboardEvent.shiftKey && document.activeElement === last) { keyboardEvent.preventDefault(); first.focus() }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => { window.cancelAnimationFrame(frame); window.removeEventListener('keydown', onKeyDown); document.body.style.overflow = overflow; trigger?.focus() }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open])

  const request = async operation => {
    setBusy(true); setError('')
    try { await operation(); await load(); setReason(''); onComplete?.() }
    catch (requestError) { setError(requestError.response?.data?.error || 'The Gate H action could not be recorded.') }
    finally { setBusy(false) }
  }
  const requestAuthorization = submitEvent => {
    submitEvent.preventDefault()
    request(() => apiClient.post(`/admin/events/${event.id}/live_money_proof_authorizations`, {
      ...authorizationForm, max_amount_cents: Number.parseInt(authorizationForm.max_amount_cents, 10),
      expires_at: new Date(authorizationForm.expires_at).toISOString(),
    }))
  }
  const submitEvidence = submitEvent => {
    submitEvent.preventDefault(); const payload = structuredClone(form)
    payload.entity_results.production_environment = payload.entity_production_environment
    delete payload.entity_production_environment
    for (const [key] of [...recordFields, ['authorization_id'], ['order_id']]) payload[key] = Number.parseInt(payload[key], 10)
    payload.provider_results = Object.fromEntries(Object.entries(payload.provider_results).map(([key, value]) =>
      [key, key.endsWith('_cents') ? Number.parseInt(value, 10) : value]))
    payload.reconciliation_results = Object.fromEntries(Object.entries(payload.reconciliation_results).map(([key, value]) =>
      [key, Number.parseInt(value, 10)]))
    payload.effective_at = new Date(payload.effective_at).toISOString(); payload.expires_at = new Date(payload.expires_at).toISOString()
    request(() => apiClient.post(`/admin/events/${event.id}/live_money_proof_reviews`, payload))
  }
  const setNested = (section, key, value) => setForm(current => ({ ...current, [section]: { ...current[section], [key]: value } }))
  const setCommunication = (key, value) => setForm(current => ({ ...current,
    communication_results: { ...current.communication_results, [key]: { ...current.communication_results[key], evidence_reference: value } },
  }))

  return <>
    <button ref={triggerRef} type="button" onClick={() => setOpen(true)} className="inline-flex min-h-11 items-center gap-2 rounded-full border border-emerald-200 bg-emerald-50 px-3 py-2 text-xs font-semibold text-emerald-950 hover:bg-emerald-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-700 focus-visible:ring-offset-2">
      {proof.approval_recorded ? <ShieldCheck className="h-4 w-4" /> : <Banknote className="h-4 w-4" />}
      {proof.approval_recorded ? 'Review Gate H approval' : proof.pending_submission ? 'Review Gate H evidence' : 'Prepare Gate H live-money proof'}
    </button>
    {open && <div className="fixed inset-0 z-[100] flex items-end justify-center bg-neutral-950/60 backdrop-blur-sm sm:items-center sm:p-6" onMouseDown={mouseEvent => { if (mouseEvent.target === mouseEvent.currentTarget && !busy) setOpen(false) }}>
      <section ref={dialogRef} role="dialog" aria-modal="true" aria-labelledby="live-money-title" className="max-h-[96vh] w-full overflow-y-auto rounded-t-3xl bg-stone-50 shadow-2xl sm:max-w-6xl sm:rounded-3xl">
        <header className="sticky top-0 z-10 flex items-start justify-between gap-4 border-b bg-stone-50/95 px-6 py-5 backdrop-blur sm:px-8"><div><p className="text-xs font-bold uppercase tracking-[0.18em] text-emerald-800">Gate H · low-value live-money loop</p><h2 id="live-money-title" className="mt-1 text-2xl font-bold">{event.title}</h2><p className="mt-1 max-w-4xl text-sm text-neutral-600">Authorize one hidden charge, then reconcile partial and full refunds, settlement, payout, bank receipt, and the post-payout negative balance.</p></div><button ref={closeRef} type="button" aria-label="Close Gate H live-money proof" disabled={busy} onClick={() => setOpen(false)} className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full hover:bg-stone-200 focus-visible:ring-2 focus-visible:ring-emerald-700"><X className="h-5 w-5" /></button></header>
        <div className="px-6 py-6 sm:px-8 sm:py-8">
          {error && <div role="alert" className="mb-6 flex gap-3 border-l-4 border-red-600 bg-red-50 p-4 text-sm text-red-900"><ShieldAlert className="h-5 w-5 shrink-0" />{error}</div>}
          {loading && !details ? <div className="flex justify-center py-16"><Loader2 aria-label="Loading Gate H proof" className="h-8 w-8 animate-spin text-emerald-700" /></div> : <>
            {mode === 'not-candidate' && <div className="border-l-4 border-amber-500 bg-amber-50 p-5 text-sm text-amber-950">Mark and configure a dedicated draft <strong>[LIVE MONEY TEST]</strong> event before Gates E–G. Normal events cannot be used to bypass Gate H.</div>}
            {mode === 'authorize' && <form onSubmit={requestAuthorization} className="space-y-6"><div className="border-l-4 border-emerald-600 bg-emerald-50 p-4 text-sm text-emerald-950">The authorization is private, expires within two hours, is locked to one administrator email, and must be approved by a different administrator.</div><div className="grid gap-4 sm:grid-cols-3"><label className="text-sm font-semibold">Proof buyer email<input required type="email" value={authorizationForm.buyer_email} onChange={change => setAuthorizationForm(current => ({ ...current, buyer_email: change.target.value }))} className={inputClass} /></label><label className="text-sm font-semibold">Maximum total cents<input required min="1" max="500" type="number" value={authorizationForm.max_amount_cents} onChange={change => setAuthorizationForm(current => ({ ...current, max_amount_cents: change.target.value }))} className={inputClass} /></label><label className="text-sm font-semibold">Expires<input required type="datetime-local" value={authorizationForm.expires_at} onChange={change => setAuthorizationForm(current => ({ ...current, expires_at: change.target.value }))} className={inputClass} /></label></div><div className="flex justify-end"><button disabled={busy} className="btn-primary min-h-11">Request proof authorization</button></div></form>}
            {mode === 'approve-authorization' && <div className="space-y-6"><div className="border-l-4 border-amber-500 bg-amber-50 p-4 text-sm text-amber-950">Authorization #{authorization.id} was requested by admin #{authorization.requested_by_user_id}, capped at {authorization.max_amount_cents} cents, and expires {formatDate(authorization.expires_at)}. A different administrator must approve it.</div><div className="flex justify-end"><button disabled={busy} onClick={() => request(() => apiClient.post(`/admin/live_money_proof_authorizations/${authorization.id}/approve`))} className="btn-primary min-h-11"><Check className="h-4 w-4" /> Approve one-time proof</button></div></div>}
            {mode === 'run' && <div className="space-y-6"><div className="border-l-4 border-emerald-600 bg-emerald-50 p-4 text-sm text-emerald-950">Authorization #{authorization.id} is approved. Sign in as the authorized admin, buy exactly one ticket, and never share this private URL.</div><a href={`/events/${event.slug}?live_money_proof=true`} className="btn-primary inline-flex min-h-11 items-center gap-2"><ExternalLink className="h-4 w-4" /> Open private proof checkout</a></div>}
            {mode === 'submit' && <form onSubmit={submitEvidence} className="space-y-9"><div className="border-l-4 border-emerald-600 bg-emerald-50 p-4 text-sm text-emerald-950">Authorization #{authorization.id} was consumed by order #{authorization.order_id}. Complete the finance sequence, then enter the exact local IDs and restricted external evidence references.</div><fieldset><legend className="text-base font-bold">Local immutable records</legend><div className="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">{recordFields.map(([key, label]) => <label key={key} className="text-xs font-semibold">{label}<input required type="number" min="1" value={form[key]} onChange={change => setForm(current => ({ ...current, [key]: change.target.value }))} className={inputClass} /></label>)}<label className="text-xs font-semibold">Authorization ID<input required readOnly type="number" value={form.authorization_id} className={inputClass} /></label><label className="text-xs font-semibold">Order ID<input required readOnly type="number" value={form.order_id} className={inputClass} /></label></div></fieldset><fieldset><legend className="text-base font-bold">Restricted evidence bundle</legend><div className="mt-4 grid gap-4 sm:grid-cols-2"><label className="text-xs font-semibold">Evidence reference<input required value={form.evidence_reference} onChange={change => setForm(current => ({ ...current, evidence_reference: change.target.value }))} className={inputClass} /></label><label className="text-xs font-semibold">Evidence SHA-256<input required pattern="[0-9a-f]{64}" value={form.evidence_digest} onChange={change => setForm(current => ({ ...current, evidence_digest: change.target.value.trim().toLowerCase() }))} className={inputClass} /></label><label className="text-xs font-semibold">Effective<input required type="datetime-local" value={form.effective_at} onChange={change => setForm(current => ({ ...current, effective_at: change.target.value }))} className={inputClass} /></label><label className="text-xs font-semibold">Review by<input required type="datetime-local" value={form.expires_at} onChange={change => setForm(current => ({ ...current, expires_at: change.target.value }))} className={inputClass} /></label></div></fieldset><fieldset><legend className="text-base font-bold">Actual entity, organizer, bank, and providers</legend><div className="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">{entityFields.map(([key, label]) => <label key={key} className="text-xs font-semibold">{label}<input required value={form.entity_results[key]} onChange={change => setNested('entity_results', key, change.target.value)} className={inputClass} /></label>)}</div><label className="mt-4 flex items-center gap-3 text-sm font-semibold"><input type="checkbox" checked={form.entity_production_environment} onChange={change => setForm(current => ({ ...current, entity_production_environment: change.target.checked }))} className="h-5 w-5" /> Confirm every transaction used the approved production environment</label></fieldset><fieldset><legend className="text-base font-bold">Provider and bank facts</legend><div className="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">{providerFields.map(([key, label, type]) => <label key={key} className="text-xs font-semibold">{label}<input required type={type} min={type === 'number' ? 0 : undefined} pattern={key.includes('digest') ? '[0-9a-f]{64}' : undefined} value={form.provider_results[key]} onChange={change => setNested('provider_results', key, change.target.value)} className={inputClass} /></label>)}</div></fieldset><fieldset><legend className="text-base font-bold">Cent-exact reconciliation</legend><div className="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">{reconciliationFields.map(([key, label]) => <label key={key} className="text-xs font-semibold">{label} (cents/count)<input required type="number" value={form.reconciliation_results[key]} onChange={change => setNested('reconciliation_results', key, change.target.value)} className={inputClass} /></label>)}</div></fieldset><fieldset><legend className="text-base font-bold">Buyer, organizer, and support visibility</legend><div className="mt-4 grid gap-4 sm:grid-cols-2">{communicationKeys.map(([key, label]) => <label key={key} className="text-xs font-semibold">{label} evidence reference<input required value={form.communication_results[key].evidence_reference} onChange={change => setCommunication(key, change.target.value)} className={inputClass} /></label>)}</div></fieldset><fieldset><legend className="text-base font-bold">Finance release controls</legend><div className="mt-4 grid gap-3 sm:grid-cols-2">{controlFields.map(([key, label]) => <label key={key} className="flex items-start gap-3 bg-white p-3 text-sm"><input type="checkbox" checked={form.controls[key]} onChange={change => setNested('controls', key, change.target.checked)} className="mt-0.5 h-5 w-5" />{label}</label>)}</div></fieldset><div className="flex justify-end border-t pt-6"><button disabled={busy || !allControls} className="btn-primary min-h-11">Submit immutable Gate H evidence</button></div></form>}
            {mode === 'pending' && <div className="space-y-7"><div className="border-l-4 border-amber-500 bg-amber-50 p-4 text-sm text-amber-950">Submitted by admin #{pending.actor_user_id}. A different administrator must inspect the restricted provider and bank bundle.</div><Summary review={pending} /><label className="block text-sm font-semibold">Rejection reason<input value={reason} onChange={change => setReason(change.target.value)} className={inputClass} /></label><div className="flex flex-wrap justify-end gap-3"><button disabled={busy || !reason.trim()} onClick={() => request(() => apiClient.post(`/admin/live_money_proof_reviews/${pending.id}/reject`, { reason }))} className="min-h-11 rounded-full border border-red-300 px-5 font-semibold text-red-800">Reject</button><button disabled={busy} onClick={() => request(() => apiClient.post(`/admin/live_money_proof_reviews/${pending.id}/approve`))} className="btn-primary min-h-11"><Check className="h-4 w-4" /> Approve Gate H</button></div></div>}
            {mode === 'approved' && <form onSubmit={submitEvent => { submitEvent.preventDefault(); request(() => apiClient.post(`/admin/live_money_proof_reviews/${approval.id}/revoke`, { reason })) }} className="space-y-7"><div className="border-l-4 border-emerald-600 bg-emerald-50 p-4 text-sm text-emerald-950"><strong>Current Gate H approval.</strong> Normal paid pilot events using this exact account/provider/revision may proceed through their event-specific gates.</div><Summary review={approval} /><label className="block text-sm font-semibold">Revocation reason<input required value={reason} onChange={change => setReason(change.target.value)} className={inputClass} /></label><div className="flex justify-end"><button disabled={busy || !reason.trim()} className="min-h-11 rounded-full bg-red-700 px-5 font-semibold text-white">Revoke Gate H approval</button></div></form>}
          </>}
        </div>
      </section>
    </div>}
  </>
}
