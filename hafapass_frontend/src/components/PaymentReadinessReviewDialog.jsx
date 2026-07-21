import { useEffect, useMemo, useRef, useState } from 'react'
import { Check, FileCheck2, Loader2, ShieldAlert, ShieldCheck, X } from 'lucide-react'
import apiClient from '../api/client'

const controls = [
  ['guam_territory_confirmed', 'Guam territory is covered in writing'],
  ['platform_entity_model_confirmed', 'HafaPass entity and merchant model are covered'],
  ['organizer_onboarding_confirmed', 'Organizer onboarding is complete'],
  ['charges_confirmed', 'Production charges are approved'],
  ['payouts_confirmed', 'Organizer payouts are approved'],
  ['refunds_disputes_confirmed', 'Refund and dispute authority is approved'],
  ['bank_account_confirmed', 'Settlement bank account is verified'],
  ['fee_tax_schedule_approved', 'Fee and Guam tax schedule is approved'],
  ['liability_schedule_approved', 'Liability schedule is approved'],
]

const localDateTimeValue = date => {
  const pad = value => String(value).padStart(2, '0')
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`
}

const initialForm = () => {
  const effective = new Date()
  const expires = new Date(effective)
  expires.setMonth(expires.getMonth() + 6)
  return {
    evidence_reference: '',
    evidence_digest: '',
    provider_approval_reference: '',
    merchant_of_record: 'organizer',
    fee_tax_schedule_reference: '',
    liability_schedule_reference: '',
    effective_at: localDateTimeValue(effective),
    expires_at: localDateTimeValue(expires),
    controls: Object.fromEntries(controls.map(([key]) => [key, false])),
  }
}

const formatDate = value => value ? new Date(value).toLocaleString() : 'Not recorded'

function ReferenceList({ review }) {
  return (
    <dl className="grid gap-3 text-sm sm:grid-cols-2">
      <div className="border-l-2 border-brand-200 pl-3">
        <dt className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Evidence</dt>
        <dd className="mt-1 break-all font-medium text-neutral-900">{review.evidence_reference}</dd>
      </div>
      <div className="border-l-2 border-brand-200 pl-3">
        <dt className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Provider approval</dt>
        <dd className="mt-1 break-all font-medium text-neutral-900">{review.provider_approval_reference}</dd>
      </div>
      <div className="border-l-2 border-neutral-200 pl-3">
        <dt className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Fee and tax schedule</dt>
        <dd className="mt-1 break-all text-neutral-800">{review.fee_tax_schedule_reference}</dd>
      </div>
      <div className="border-l-2 border-neutral-200 pl-3">
        <dt className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Liability schedule</dt>
        <dd className="mt-1 break-all text-neutral-800">{review.liability_schedule_reference}</dd>
      </div>
      <div className="sm:col-span-2 border-l-2 border-neutral-200 pl-3">
        <dt className="text-xs font-semibold uppercase tracking-wide text-neutral-500">SHA-256</dt>
        <dd className="mt-1 break-all font-mono text-xs text-neutral-700">{review.evidence_digest}</dd>
      </div>
      {review.provider_state_digest && <div className="sm:col-span-2 border-l-2 border-neutral-200 pl-3">
        <dt className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Provider-state SHA-256</dt>
        <dd className="mt-1 break-all font-mono text-xs text-neutral-700">{review.provider_state_digest}</dd>
      </div>}
    </dl>
  )
}

export default function PaymentReadinessReviewDialog({ account, onComplete }) {
  const [open, setOpen] = useState(false)
  const [form, setForm] = useState(initialForm)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const triggerRef = useRef(null)
  const dialogRef = useRef(null)
  const closeRef = useRef(null)
  const pending = account.readiness_submission
  const approval = account.readiness_approval
  const approvalActive = account.readiness_approval_active ?? account.payout_ready ?? false
  const mode = approvalActive ? 'approved' : pending ? 'pending' : 'submit'
  const allControlsChecked = useMemo(() => controls.every(([key]) => form.controls[key]), [form.controls])

  useEffect(() => {
    if (!open) return undefined
    const trigger = triggerRef.current
    const previousOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    const animationFrame = window.requestAnimationFrame(() => closeRef.current?.focus())
    const onKeyDown = event => {
      if (event.key === 'Escape') setOpen(false)
      if (event.key !== 'Tab' || !dialogRef.current) return
      const focusable = [...dialogRef.current.querySelectorAll('button:not([disabled]), input:not([disabled]), select:not([disabled]), [href], [tabindex]:not([tabindex="-1"])')]
      if (!focusable.length) return
      const first = focusable[0]
      const last = focusable[focusable.length - 1]
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => {
      window.cancelAnimationFrame(animationFrame)
      window.removeEventListener('keydown', onKeyDown)
      document.body.style.overflow = previousOverflow
      trigger?.focus()
    }
  }, [open])

  const request = async operation => {
    setBusy(true)
    setError('')
    try {
      await operation()
      setOpen(false)
      setForm(initialForm())
      setReason('')
      onComplete()
    } catch (requestError) {
      setError(requestError.response?.data?.error || 'The readiness decision could not be recorded.')
    } finally {
      setBusy(false)
    }
  }

  const submit = event => {
    event.preventDefault()
    request(() => apiClient.post(`/admin/connected_accounts/${account.id}/payment_readiness_reviews`, {
      ...form,
      effective_at: new Date(form.effective_at).toISOString(),
      expires_at: new Date(form.expires_at).toISOString(),
    }))
  }

  const approve = () => request(() => apiClient.patch(`/admin/payment_readiness_reviews/${pending.id}/approve`))
  const reject = () => request(() => apiClient.post(`/admin/payment_readiness_reviews/${pending.id}/reject`, { reason }))
  const revoke = event => {
    event.preventDefault()
    request(() => apiClient.post(`/admin/payment_readiness_reviews/${approval.id}/revoke`, { reason }))
  }

  return (
    <>
      <button
        type="button"
        ref={triggerRef}
        onClick={() => { setError(''); setOpen(true) }}
        className="inline-flex min-h-11 items-center gap-2 rounded-full border border-brand-200 bg-brand-50 px-3 py-2 text-xs font-semibold text-brand-700 transition-colors duration-200 hover:border-brand-300 hover:bg-brand-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2"
      >
        {approvalActive ? <ShieldCheck className="h-4 w-4" /> : <FileCheck2 className="h-4 w-4" />}
        {approvalActive ? 'Review approval' : pending ? 'Review pending evidence' : approval ? 'Replace expired evidence' : 'Submit Gate B evidence'}
      </button>

      {open && (
        <div className="fixed inset-0 z-[100] flex items-end justify-center bg-neutral-950/60 p-0 backdrop-blur-sm sm:items-center sm:p-6" onMouseDown={event => {
          if (event.target === event.currentTarget && !busy) setOpen(false)
        }}>
          <section ref={dialogRef} role="dialog" aria-modal="true" aria-labelledby="payment-readiness-title" className="max-h-[94vh] w-full overflow-y-auto rounded-t-3xl bg-stone-50 shadow-2xl sm:max-w-3xl sm:rounded-3xl">
            <header className="sticky top-0 z-10 flex items-start justify-between gap-4 border-b border-stone-200 bg-stone-50/95 px-6 py-5 backdrop-blur sm:px-8">
              <div>
                <p className="text-xs font-bold uppercase tracking-[0.18em] text-brand-600">Gate B · two-person control</p>
                <h2 id="payment-readiness-title" className="mt-1 text-2xl font-bold tracking-tight text-neutral-950">
                  {account.provider} payment readiness
                </h2>
                <p className="mt-1 max-w-2xl text-sm leading-relaxed text-neutral-600">
                  References and a digest belong here. Contracts, bank details, identity documents, and secrets do not.
                </p>
              </div>
              <button ref={closeRef} type="button" aria-label="Close payment readiness review" disabled={busy} onClick={() => setOpen(false)} className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full text-neutral-500 transition-colors hover:bg-stone-200 hover:text-neutral-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 disabled:opacity-50">
                <X className="h-5 w-5" />
              </button>
            </header>

            <div className="px-6 py-6 sm:px-8 sm:py-8">
              {error && <div role="alert" className="mb-6 flex items-start gap-3 border-l-4 border-red-500 bg-red-50 p-4 text-sm text-red-800"><ShieldAlert className="mt-0.5 h-5 w-5 shrink-0" /><p>{error}</p></div>}

              {mode === 'submit' && (
                <form onSubmit={submit} className="space-y-8">
                  {approval && <div className="flex items-start gap-3 border-l-4 border-amber-400 bg-amber-50 p-4 text-sm text-amber-900"><ShieldAlert className="mt-0.5 h-5 w-5 shrink-0" /><p>The previous approval is expired or revoked. Submit a new immutable evidence snapshot; the old decision remains in the audit chain.</p></div>}
                  <div className="grid gap-5 sm:grid-cols-2">
                    {[
                      ['evidence_reference', 'Restricted evidence reference'],
                      ['provider_approval_reference', 'Provider or bank approval reference'],
                      ['fee_tax_schedule_reference', 'Approved fee and tax schedule'],
                      ['liability_schedule_reference', 'Approved liability schedule'],
                    ].map(([key, label]) => (
                      <label key={key} className="text-sm font-semibold text-neutral-800">
                        {label}
                        <input required value={form[key]} onChange={event => setForm(current => ({ ...current, [key]: event.target.value }))} className="input mt-2" />
                      </label>
                    ))}
                    <label className="text-sm font-semibold text-neutral-800 sm:col-span-2">
                      Evidence SHA-256
                      <input required pattern="[0-9a-f]{64}" minLength={64} maxLength={64} value={form.evidence_digest} onChange={event => setForm(current => ({ ...current, evidence_digest: event.target.value.trim().toLowerCase() }))} className="input mt-2 font-mono text-xs" aria-describedby="digest-help" />
                      <span id="digest-help" className="mt-1 block text-xs font-normal leading-relaxed text-neutral-500">Hash the approved redacted bundle so reviewers can prove they inspected the same artifact.</span>
                    </label>
                    <label className="text-sm font-semibold text-neutral-800">
                      Merchant of record
                      <select value={form.merchant_of_record} onChange={event => setForm(current => ({ ...current, merchant_of_record: event.target.value }))} className="input mt-2">
                        <option value="organizer">Organizer</option>
                        <option value="platform">HafaPass platform</option>
                        <option value="provider_managed">Provider-managed</option>
                      </select>
                    </label>
                    <div className="grid grid-cols-2 gap-3">
                      <label className="text-sm font-semibold text-neutral-800">Effective<input required type="datetime-local" value={form.effective_at} onChange={event => setForm(current => ({ ...current, effective_at: event.target.value }))} className="input mt-2" /></label>
                      <label className="text-sm font-semibold text-neutral-800">Review by<input required type="datetime-local" value={form.expires_at} onChange={event => setForm(current => ({ ...current, expires_at: event.target.value }))} className="input mt-2" /></label>
                    </div>
                  </div>

                  <fieldset>
                    <legend className="text-sm font-bold text-neutral-950">Decision controls</legend>
                    <p className="mt-1 text-sm leading-relaxed text-neutral-600">Every item must be supported by the referenced evidence—not assumed from a sandbox test.</p>
                    <div className="mt-4 grid gap-3 sm:grid-cols-2">
                      {controls.map(([key, label]) => (
                        <label key={key} className="flex min-h-14 cursor-pointer items-start gap-3 border-l-2 border-stone-300 bg-white px-4 py-3 text-sm leading-snug text-neutral-700 transition-colors hover:border-brand-300 hover:bg-brand-50/40">
                          <input type="checkbox" checked={form.controls[key]} onChange={event => setForm(current => ({ ...current, controls: { ...current.controls, [key]: event.target.checked } }))} className="mt-0.5 h-5 w-5 rounded border-neutral-300 text-brand-600 focus:ring-brand-500" />
                          <span>{label}</span>
                        </label>
                      ))}
                    </div>
                  </fieldset>

                  <div className="flex flex-col-reverse gap-3 border-t border-stone-200 pt-6 sm:flex-row sm:items-center sm:justify-between">
                    <p className="text-xs leading-relaxed text-neutral-500">A different administrator must approve this exact snapshot.</p>
                    <button type="submit" disabled={busy || !allControlsChecked} className="btn-primary min-h-11 disabled:cursor-not-allowed disabled:opacity-50">{busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <FileCheck2 className="h-4 w-4" />} Submit evidence</button>
                  </div>
                </form>
              )}

              {mode === 'pending' && (
                <div className="space-y-7">
                  <div className="border-l-4 border-amber-400 bg-amber-50 p-4">
                    <p className="font-semibold text-amber-900">Independent approval required</p>
                    <p className="mt-1 text-sm leading-relaxed text-amber-800">Admin #{pending.actor_user_id} submitted this snapshot. The API rejects approval by that same administrator.</p>
                  </div>
                  <ReferenceList review={pending} />
                  <div>
                    <h3 className="text-sm font-bold text-neutral-950">Affirmed controls</h3>
                    <ul className="mt-3 grid gap-2 sm:grid-cols-2">{controls.map(([key, label]) => <li key={key} className="flex items-start gap-2 text-sm text-neutral-700"><Check className={`mt-0.5 h-4 w-4 shrink-0 ${pending.controls?.[key] ? 'text-emerald-600' : 'text-red-600'}`} /><span>{label}</span></li>)}</ul>
                  </div>
                  <p className="text-sm text-neutral-600">Effective {formatDate(pending.effective_at)} · expires {formatDate(pending.expires_at)} · merchant of record: <span className="font-semibold text-neutral-900">{pending.merchant_of_record}</span></p>
                  <label className="block text-sm font-semibold text-neutral-800">Rejection or correction reason<input value={reason} onChange={event => setReason(event.target.value)} className="input mt-2" placeholder="Explain what the submitter must correct" /></label>
                  <div className="flex flex-col-reverse gap-3 border-t border-stone-200 pt-6 sm:flex-row sm:justify-end">
                    <button type="button" onClick={reject} disabled={busy || !reason.trim()} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-full border border-red-200 px-5 py-2.5 text-sm font-semibold text-red-700 transition-colors hover:bg-red-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-600 focus-visible:ring-offset-2 disabled:opacity-50"><ShieldAlert className="h-4 w-4" /> Reject evidence</button>
                    <button type="button" onClick={approve} disabled={busy} className="btn-primary min-h-11 disabled:opacity-50">{busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <ShieldCheck className="h-4 w-4" />} Approve exact evidence</button>
                  </div>
                </div>
              )}

              {mode === 'approved' && (
                <form onSubmit={revoke} className="space-y-7">
                  <div className="flex items-start gap-3 border-l-4 border-emerald-500 bg-emerald-50 p-4"><ShieldCheck className="mt-0.5 h-5 w-5 shrink-0 text-emerald-700" /><div><p className="font-semibold text-emerald-900">Current independent approval</p><p className="mt-1 text-sm text-emerald-800">Approved by admin #{approval.actor_user_id}; expires {formatDate(approval.expires_at)}.</p></div></div>
                  <ReferenceList review={approval} />
                  <label className="block text-sm font-semibold text-neutral-800">Revocation reason<input required value={reason} onChange={event => setReason(event.target.value)} className="input mt-2" placeholder="What changed or became invalid?" /></label>
                  <div className="flex justify-end border-t border-stone-200 pt-6"><button type="submit" disabled={busy || !reason.trim()} className="inline-flex min-h-11 items-center gap-2 rounded-full bg-red-700 px-5 py-2.5 text-sm font-semibold text-white transition-colors hover:bg-red-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-600 focus-visible:ring-offset-2 disabled:opacity-50">{busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <ShieldAlert className="h-4 w-4" />} Revoke readiness</button></div>
                </form>
              )}
            </div>
          </section>
        </div>
      )}
    </>
  )
}
