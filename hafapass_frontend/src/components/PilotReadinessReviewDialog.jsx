import { useEffect, useMemo, useRef, useState } from 'react'
import { Check, ClipboardCheck, Loader2, ShieldAlert, ShieldCheck, UsersRound, X } from 'lucide-react'
import apiClient from '../api/client'

const controls = [
  ['low_risk_scope', 'Organizer and event are intentionally low-risk and bounded'],
  ['organizer_identity_and_agreement', 'Organizer identity and current agreement are verified'],
  ['payout_method', 'Approved payout method is ready for this event'],
  ['event_content_and_prohibited_review', 'Event content and prohibited-event review are complete'],
  ['venue_schedule_capacity_inventory', 'Venue, schedule, capacity, and inventory reconcile'],
  ['pricing_fees_and_refund_policy', 'Prices, fees, and refund policy are approved'],
  ['seating_physically_reconciled_or_not_applicable', 'Every physical seat is reconciled, or seating is not applicable'],
  ['support_channels_and_sla', 'Support channels and response SLA are staffed'],
  ['cash_controls_and_staffing', 'Cash controls, staffing, and shift ownership are defined'],
  ['scanners_spares_and_connectivity', 'Scanners, batteries, spares, and connectivity fallback are assigned'],
  ['emergency_door_list_restricted', 'Emergency door-list access and disposal are restricted'],
  ['no_open_p0_or_p1', 'No pilot scenario has an unresolved P0 or P1 issue'],
]

const assignmentRoles = [
  ['primary_on_call', 'Primary on-call'],
  ['backup_on_call', 'Backup on-call'],
  ['event_commander', 'Event commander'],
  ['door_lead', 'Door lead'],
  ['finance_contact', 'Finance contact'],
  ['venue_safety_contact', 'Venue safety contact'],
]

const localDateTimeValue = date => {
  const pad = value => String(value).padStart(2, '0')
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`
}

const initialForm = () => {
  const effective = new Date()
  const expires = new Date(effective)
  expires.setMonth(expires.getMonth() + 2)
  return {
    evidence_reference: '',
    evidence_digest: '',
    effective_at: localDateTimeValue(effective),
    expires_at: localDateTimeValue(expires),
    controls: Object.fromEntries(controls.map(([key]) => [key, false])),
    assignments: Object.fromEntries(assignmentRoles.map(([key]) => [key, { name: '', contact_reference: '' }])),
  }
}

const formatDate = value => value ? new Date(value).toLocaleString() : 'Not recorded'

function EvidenceSummary({ review }) {
  return (
    <div className="space-y-5">
      <dl className="grid gap-4 text-sm sm:grid-cols-2">
        <div className="border-l-2 border-brand-300 pl-3"><dt className="text-xs font-bold uppercase tracking-wide text-neutral-500">Evidence reference</dt><dd className="mt-1 break-all text-neutral-900">{review.evidence_reference}</dd></div>
        <div className="border-l-2 border-brand-300 pl-3"><dt className="text-xs font-bold uppercase tracking-wide text-neutral-500">Evidence SHA-256</dt><dd className="mt-1 break-all font-mono text-xs text-neutral-700">{review.evidence_digest}</dd></div>
        <div className="border-l-2 border-neutral-300 pl-3 sm:col-span-2"><dt className="text-xs font-bold uppercase tracking-wide text-neutral-500">Event-state SHA-256</dt><dd className="mt-1 break-all font-mono text-xs text-neutral-700">{review.event_state_digest}</dd></div>
        <div className="border-l-2 border-neutral-300 pl-3 sm:col-span-2"><dt className="text-xs font-bold uppercase tracking-wide text-neutral-500">Application revision</dt><dd className="mt-1 break-all font-mono text-xs text-neutral-700">{review.application_revision}</dd></div>
      </dl>
      <div>
        <h3 className="text-sm font-bold text-neutral-950">Named command and response owners</h3>
        <dl className="mt-3 grid gap-3 sm:grid-cols-2">
          {assignmentRoles.map(([key, label]) => <div key={key} className="bg-white px-4 py-3 shadow-sm"><dt className="text-xs font-semibold text-neutral-500">{label}</dt><dd className="mt-1 text-sm font-semibold text-neutral-900">{review.assignments?.[key]?.name}</dd><dd className="mt-0.5 break-all text-xs text-neutral-600">{review.assignments?.[key]?.contact_reference}</dd></div>)}
        </dl>
      </div>
    </div>
  )
}

export default function PilotReadinessReviewDialog({ event, onComplete }) {
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
  const readiness = details?.pilot_readiness || event.pilot_readiness || {}
  const pending = readiness.pending_submission
  const approval = readiness.latest_approval
  const mode = readiness.approved ? 'approved' : pending ? 'pending' : 'submit'
  const allControlsChecked = useMemo(() => controls.every(([key]) => form.controls[key]), [form.controls])
  const allAssignmentsComplete = useMemo(() => assignmentRoles.every(([key]) => {
    const assignment = form.assignments[key]
    return assignment.name.trim() && assignment.contact_reference.trim()
  }), [form.assignments])

  const load = async () => {
    setLoading(true)
    setError('')
    try {
      const response = await apiClient.get(`/admin/events/${event.id}/pilot_readiness`)
      setDetails(response.data)
    } catch (requestError) {
      setError(requestError.response?.data?.error || 'Pilot readiness could not be loaded.')
    } finally {
      setLoading(false)
    }
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
      const focusable = [...dialogRef.current.querySelectorAll('button:not([disabled]), input:not([disabled]), [href], [tabindex]:not([tabindex="-1"])')]
      if (!focusable.length) return
      const first = focusable[0]
      const last = focusable[focusable.length - 1]
      if (keyboardEvent.shiftKey && document.activeElement === first) {
        keyboardEvent.preventDefault(); last.focus()
      } else if (!keyboardEvent.shiftKey && document.activeElement === last) {
        keyboardEvent.preventDefault(); first.focus()
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => {
      window.cancelAnimationFrame(animationFrame)
      window.removeEventListener('keydown', onKeyDown)
      document.body.style.overflow = previousOverflow
      trigger?.focus()
    }
  // `busy` must not reinstall the focus trap while an operation is running.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open])

  const request = async operation => {
    setBusy(true)
    setError('')
    try {
      await operation()
      await load()
      setForm(initialForm())
      setReason('')
      onComplete?.()
    } catch (requestError) {
      setError(requestError.response?.data?.error || 'The readiness decision could not be recorded.')
    } finally {
      setBusy(false)
    }
  }

  const submit = submitEvent => {
    submitEvent.preventDefault()
    request(() => apiClient.post(`/admin/events/${event.id}/pilot_readiness_reviews`, {
      ...form,
      effective_at: new Date(form.effective_at).toISOString(),
      expires_at: new Date(form.expires_at).toISOString(),
    }))
  }
  const approve = () => request(() => apiClient.post(`/admin/pilot_readiness_reviews/${pending.id}/approve`))
  const reject = () => request(() => apiClient.post(`/admin/pilot_readiness_reviews/${pending.id}/reject`, { reason }))
  const revoke = revokeEvent => {
    revokeEvent.preventDefault()
    request(() => apiClient.post(`/admin/pilot_readiness_reviews/${approval.id}/revoke`, { reason }))
  }

  const updateAssignment = (role, field, value) => setForm(current => ({
    ...current,
    assignments: { ...current.assignments, [role]: { ...current.assignments[role], [field]: value } },
  }))

  return (
    <>
      <button ref={triggerRef} type="button" onClick={() => setOpen(true)} className="inline-flex min-h-11 items-center gap-2 rounded-full border border-brand-200 bg-brand-50 px-3 py-2 text-xs font-semibold text-brand-800 transition-colors hover:bg-brand-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2">
        {readiness.approved ? <ShieldCheck className="h-4 w-4" /> : <ClipboardCheck className="h-4 w-4" />}
        {readiness.approved ? 'Review pilot approval' : readiness.pending_submission ? 'Review readiness' : 'Prepare pilot readiness'}
      </button>

      {open && <div className="fixed inset-0 z-[100] flex items-end justify-center bg-neutral-950/60 backdrop-blur-sm sm:items-center sm:p-6" onMouseDown={mouseEvent => { if (mouseEvent.target === mouseEvent.currentTarget && !busy) setOpen(false) }}>
        <section ref={dialogRef} role="dialog" aria-modal="true" aria-labelledby="pilot-readiness-title" className="max-h-[96vh] w-full overflow-y-auto rounded-t-3xl bg-stone-50 shadow-2xl sm:max-w-4xl sm:rounded-3xl">
          <header className="sticky top-0 z-10 flex items-start justify-between gap-4 border-b border-stone-200 bg-stone-50/95 px-6 py-5 backdrop-blur sm:px-8">
            <div><p className="text-xs font-bold uppercase tracking-[0.18em] text-brand-700">Gate E · event-specific approval</p><h2 id="pilot-readiness-title" className="mt-1 text-2xl font-bold tracking-tight text-neutral-950">{event.title}</h2><p className="mt-1 max-w-2xl text-sm leading-relaxed text-neutral-600">Bind the operating plan to this exact event configuration. Store evidence and contact-directory references here—never contracts, identity documents, bank details, or secrets.</p></div>
            <button ref={closeRef} type="button" aria-label="Close pilot readiness review" disabled={busy} onClick={() => setOpen(false)} className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full text-neutral-500 hover:bg-stone-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 disabled:opacity-50"><X className="h-5 w-5" /></button>
          </header>

          <div className="px-6 py-6 sm:px-8 sm:py-8">
            {error && <div role="alert" className="mb-6 flex items-start gap-3 border-l-4 border-red-600 bg-red-50 p-4 text-sm text-red-900"><ShieldAlert className="mt-0.5 h-5 w-5 shrink-0" /><p>{error}</p></div>}
            {loading && !details ? <div className="flex justify-center py-16"><Loader2 aria-label="Loading pilot readiness" className="h-8 w-8 animate-spin text-brand-600" /></div> : <>
              {mode === 'submit' && <form onSubmit={submit} className="space-y-8">
                {approval && <div className="border-l-4 border-amber-500 bg-amber-50 p-4 text-sm text-amber-900">The prior approval expired, was revoked, or no longer matches the event. Submit a new immutable snapshot.</div>}
                <div className="grid gap-5 sm:grid-cols-2">
                  <label className="text-sm font-semibold text-neutral-800">Restricted evidence reference<input required value={form.evidence_reference} onChange={changeEvent => setForm(current => ({ ...current, evidence_reference: changeEvent.target.value }))} className="input mt-2" /></label>
                  <label className="text-sm font-semibold text-neutral-800">Evidence SHA-256<input required aria-describedby="pilot-digest-help" pattern="[0-9a-f]{64}" minLength={64} maxLength={64} value={form.evidence_digest} onChange={changeEvent => setForm(current => ({ ...current, evidence_digest: changeEvent.target.value.trim().toLowerCase() }))} className="input mt-2 font-mono text-xs" /><span id="pilot-digest-help" className="mt-1 block text-xs font-normal text-neutral-500">Digest the signed readiness sheet and privacy-safe supporting bundle.</span></label>
                  <label className="text-sm font-semibold text-neutral-800">Effective<input required type="datetime-local" value={form.effective_at} onChange={changeEvent => setForm(current => ({ ...current, effective_at: changeEvent.target.value }))} className="input mt-2" /></label>
                  <label className="text-sm font-semibold text-neutral-800">Review by<input required type="datetime-local" value={form.expires_at} onChange={changeEvent => setForm(current => ({ ...current, expires_at: changeEvent.target.value }))} className="input mt-2" /></label>
                </div>

                <fieldset><legend className="flex items-center gap-2 text-sm font-bold text-neutral-950"><UsersRound className="h-4 w-4 text-brand-700" /> Named operational ownership</legend><p className="mt-1 text-sm text-neutral-600">Contact references should point to the restricted on-call directory; do not paste phone numbers into source control.</p><div className="mt-4 grid gap-4 sm:grid-cols-2">{assignmentRoles.map(([key, label]) => <div key={key} className="border-l-2 border-stone-300 bg-white p-4"><p className="text-sm font-bold text-neutral-900">{label}</p><label className="mt-3 block text-xs font-semibold text-neutral-600">Name<input required aria-label={`${label} name`} value={form.assignments[key].name} onChange={changeEvent => updateAssignment(key, 'name', changeEvent.target.value)} className="input mt-1" /></label><label className="mt-3 block text-xs font-semibold text-neutral-600">Private contact reference<input required aria-label={`${label} private contact reference`} value={form.assignments[key].contact_reference} onChange={changeEvent => updateAssignment(key, 'contact_reference', changeEvent.target.value)} className="input mt-1" /></label></div>)}</div></fieldset>

                <fieldset><legend className="text-sm font-bold text-neutral-950">Readiness controls</legend><p className="mt-1 text-sm text-neutral-600">Each affirmation must be supported by the referenced, signed evidence bundle.</p><div className="mt-4 grid gap-3 sm:grid-cols-2">{controls.map(([key, label]) => <label key={key} className="flex min-h-14 cursor-pointer items-start gap-3 border-l-2 border-stone-300 bg-white px-4 py-3 text-sm leading-snug text-neutral-700 hover:border-brand-400 hover:bg-brand-50/40"><input type="checkbox" checked={form.controls[key]} onChange={changeEvent => setForm(current => ({ ...current, controls: { ...current.controls, [key]: changeEvent.target.checked } }))} className="mt-0.5 h-5 w-5 rounded border-neutral-300 text-brand-700 focus:ring-brand-500" /><span>{label}</span></label>)}</div></fieldset>

                <div className="flex flex-col-reverse gap-3 border-t border-stone-200 pt-6 sm:flex-row sm:items-center sm:justify-between"><p className="text-xs text-neutral-500">A different administrator must approve the exact event-state digest.</p><button type="submit" disabled={busy || !allControlsChecked || !allAssignmentsComplete} className="btn-primary min-h-11 disabled:cursor-not-allowed disabled:opacity-50">{busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <ClipboardCheck className="h-4 w-4" />} Submit readiness</button></div>
              </form>}

              {mode === 'pending' && <div className="space-y-7"><div className="border-l-4 border-amber-500 bg-amber-50 p-4"><p className="font-semibold text-amber-950">Independent decision required</p><p className="mt-1 text-sm text-amber-900">Admin #{pending.actor_user_id} submitted this exact event snapshot. That administrator cannot approve it.</p></div><EvidenceSummary review={pending} /><div><h3 className="text-sm font-bold text-neutral-950">Affirmed controls</h3><ul className="mt-3 grid gap-2 sm:grid-cols-2">{controls.map(([key, label]) => <li key={key} className="flex items-start gap-2 text-sm text-neutral-700"><Check className={`mt-0.5 h-4 w-4 shrink-0 ${pending.controls?.[key] ? 'text-emerald-700' : 'text-red-700'}`} /><span>{label}</span></li>)}</ul></div><p className="text-sm text-neutral-600">Effective {formatDate(pending.effective_at)} · expires {formatDate(pending.expires_at)}</p><label className="block text-sm font-semibold text-neutral-800">Rejection or correction reason<input value={reason} onChange={changeEvent => setReason(changeEvent.target.value)} className="input mt-2" /></label><div className="flex flex-col-reverse gap-3 border-t border-stone-200 pt-6 sm:flex-row sm:justify-end"><button type="button" onClick={reject} disabled={busy || !reason.trim()} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-full border border-red-300 px-5 py-2.5 text-sm font-semibold text-red-800 hover:bg-red-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-600 disabled:opacity-50"><ShieldAlert className="h-4 w-4" /> Reject readiness</button><button type="button" onClick={approve} disabled={busy} className="btn-primary min-h-11 disabled:opacity-50">{busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <ShieldCheck className="h-4 w-4" />} Approve exact snapshot</button></div></div>}

              {mode === 'approved' && <form onSubmit={revoke} className="space-y-7"><div className="flex items-start gap-3 border-l-4 border-emerald-600 bg-emerald-50 p-4"><ShieldCheck className="mt-0.5 h-5 w-5 shrink-0 text-emerald-800" /><div><p className="font-semibold text-emerald-950">Current event-specific approval</p><p className="mt-1 text-sm text-emerald-900">Approved by admin #{approval.actor_user_id}; expires {formatDate(approval.expires_at)}.</p></div></div><EvidenceSummary review={approval} /><label className="block text-sm font-semibold text-neutral-800">Revocation reason<input required value={reason} onChange={changeEvent => setReason(changeEvent.target.value)} className="input mt-2" placeholder="Describe the changed condition" /></label><div className="flex justify-end border-t border-stone-200 pt-6"><button type="submit" disabled={busy || !reason.trim()} className="inline-flex min-h-11 items-center gap-2 rounded-full bg-red-700 px-5 py-2.5 text-sm font-semibold text-white hover:bg-red-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-600 focus-visible:ring-offset-2 disabled:opacity-50"><ShieldAlert className="h-4 w-4" /> Revoke readiness</button></div></form>}
            </>}
          </div>
        </section>
      </div>}
    </>
  )
}
