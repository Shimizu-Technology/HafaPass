import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react'
import { Loader2 } from 'lucide-react'
import { Link } from 'react-router-dom'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'
import AdminSessionGate from './AdminSessionGate'
import Dialog from '../../components/Dialog'
import FormErrorSummary from '../../components/FormErrorSummary'
import { usePlatformRequests } from '../../hooks/usePlatformContext'
import { feeExample, feeRateLabel, quoteBuyerFeeCents } from '../../utils/feeTerms'
import { money } from './adminOperations'
import PaymentModeSwitch from './PaymentModeSwitch'

// Mirrors SiteSetting validation so most mistakes are caught before saving;
// the server stays the authority and its messages are shown the same way.
const MAX_FEE_PERCENT = 25
const MAX_FLAT_CENTS = 1000
const MAX_SCHEDULE_LENGTH = 200
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const FEE_FIELDS = ['service_fee_percent', 'service_fee_flat_cents', 'processing_fee_bearer', 'payout_schedule_text']
const FIELD_LABELS = {
  platform_name: 'Platform name', platform_email: 'Support email', platform_phone: 'Support phone',
  business_mailing_address: 'Business mailing address',
  service_fee_percent: 'Service fee percentage', service_fee_flat_cents: 'Flat fee per paid ticket',
  processing_fee_bearer: 'Card processing', payout_schedule_text: 'Payout timing',
}
const BEARERS = {
  platform: { title: 'HåfaPass covers card processing', body: 'Card processing on tickets is paid out of the service fee. Organizers keep the full ticket price.' },
  organizer: { title: 'Deducted from organizer proceeds', body: 'The actual card processing cost of each order is taken out of the organizer’s payout.' },
}
const toForm = settings => ({
  platform_name: settings.platform_name || '',
  platform_email: settings.platform_email || '',
  platform_phone: settings.platform_phone || '',
  business_mailing_address: settings.business_mailing_address || '',
  service_fee_percent: settings.service_fee_percent == null ? '' : String(Number(settings.service_fee_percent)),
  service_fee_flat: settings.service_fee_flat_cents == null ? '' : (settings.service_fee_flat_cents / 100).toFixed(2),
  processing_fee_bearer: settings.processing_fee_bearer || 'platform',
  payout_schedule_text: settings.payout_schedule_text || '',
  backup_withholding_mode: settings.backup_withholding_mode || 'block',
  backup_withholding_rate_bps: String(settings.backup_withholding_rate_bps ?? 2400),
  threshold_nec: String(settings.tax_reporting_thresholds?.['1099-nec'] ?? 200000),
  threshold_misc: String(settings.tax_reporting_thresholds?.['1099-misc'] ?? 200000),
  threshold_k: String(settings.tax_reporting_thresholds?.['1099-k'] ?? 2000000),
  fee_notice_days: settings.fee_notice_days == null ? '30' : String(settings.fee_notice_days),
})

// Form values as the API's attributes. Dollars become whole cents.
function toAttributes(form) {
  const flat = form.service_fee_flat.trim()
  return {
    platform_name: form.platform_name.trim(),
    platform_email: form.platform_email.trim(),
    platform_phone: form.platform_phone.trim(),
    business_mailing_address: form.business_mailing_address.trim(),
    service_fee_percent: form.service_fee_percent.trim() === '' ? null : Number(form.service_fee_percent),
    service_fee_flat_cents: flat === '' ? null : Math.round(Number(flat) * 100),
    processing_fee_bearer: form.processing_fee_bearer,
    payout_schedule_text: form.payout_schedule_text.replace(/\s+/g, ' ').trim(),
    backup_withholding_mode: form.backup_withholding_mode,
    backup_withholding_rate_bps: Number(form.backup_withholding_rate_bps),
    tax_reporting_thresholds: { '1099-nec': Number(form.threshold_nec), '1099-misc': Number(form.threshold_misc), '1099-k': Number(form.threshold_k) },
    fee_notice_days: Number(form.fee_notice_days),
  }
}

function validate(form) {
  const values = toAttributes(form)
  const errors = {}
  if (!values.platform_name) errors.platform_name = 'Enter the platform name buyers see.'
  if (values.platform_email && !EMAIL_PATTERN.test(values.platform_email)) errors.platform_email = 'Enter a valid support email address, or leave it blank.'
  if (values.business_mailing_address.length > 500) errors.business_mailing_address = 'Keep the business mailing address under 500 characters.'
  if (values.service_fee_percent == null || !Number.isFinite(values.service_fee_percent) || values.service_fee_percent < 0 || values.service_fee_percent > MAX_FEE_PERCENT) {
    errors.service_fee_percent = `Enter a service fee between 0% and ${MAX_FEE_PERCENT}%.`
  }
  const flat = Number(form.service_fee_flat)
  if (form.service_fee_flat.trim() === '' || !Number.isFinite(flat) || flat < 0 || values.service_fee_flat_cents > MAX_FLAT_CENTS || !/^\d+(\.\d{1,2})?$/.test(form.service_fee_flat.trim())) {
    errors.service_fee_flat_cents = `Enter a flat fee between $0.00 and ${money(MAX_FLAT_CENTS)}, in dollars and cents.`
  }
  if (!values.payout_schedule_text) errors.payout_schedule_text = 'Describe when organizers are paid.'
  else if (values.payout_schedule_text.length > MAX_SCHEDULE_LENGTH) errors.payout_schedule_text = `Keep payout timing under ${MAX_SCHEDULE_LENGTH} characters.`
  if (!form.backup_withholding_rate_bps.trim() || !Number.isInteger(values.backup_withholding_rate_bps) || values.backup_withholding_rate_bps < 1 || values.backup_withholding_rate_bps > 9999) errors.backup_withholding_rate_bps = 'Enter a rate from 1 to 9999 basis points.'
  for (const [field, value] of Object.entries({ threshold_nec: form.threshold_nec, threshold_misc: form.threshold_misc, threshold_k: form.threshold_k })) {
    if (!/^\d+$/.test(value) || Number(value) > 1000000000) errors[field] = 'Enter a whole-cent threshold.'
  }
  if (!Number.isInteger(values.fee_notice_days) || values.fee_notice_days < 1 || values.fee_notice_days > 365) errors.fee_notice_days = 'Enter 1 to 365 notice days.'
  return errors
}

// Server messages are full sentences that start with the attribute name.
function fieldErrorsFrom(messages) {
  const errors = {}
  messages.forEach(message => {
    const field = Object.keys(FIELD_LABELS).find(name => message.toLowerCase().startsWith(name.replaceAll('_', ' ')))
    errors[field || 'form'] = errors[field || 'form'] ? `${errors[field || 'form']} ${message}` : message
  })
  return errors
}

const describe = (field, value) => {
  if (value == null || value === '') return 'Not set'
  if (field === 'service_fee_percent') return `${Number(value)}%`
  if (field === 'service_fee_flat_cents') return money(value)
  if (field === 'processing_fee_bearer') return BEARERS[value]?.title || value
  return String(value)
}

function Field({ id, label, hint, error, children }) {
  return (
    <div>
      <label htmlFor={id} className="block text-sm font-medium text-neutral-900">{label}</label>
      {hint && <p id={`${id}-hint`} className="mt-0.5 text-sm text-content-muted">{hint}</p>}
      <div className="mt-1.5">{children}</div>
      {error && <p id={`${id}-error`} className="mt-1.5 text-sm text-red-700">{error}</p>}
    </div>
  )
}

const describedBy = (id, hint, error) => [hint && `${id}-hint`, error && `${id}-error`].filter(Boolean).join(' ') || undefined

function FeeExample({ form }) {
  const [price, setPrice] = useState('25.00')
  const values = toAttributes(form)
  const valid = Number.isFinite(values.service_fee_percent) && values.service_fee_percent >= 0 && Number.isInteger(values.service_fee_flat_cents) && values.service_fee_flat_cents >= 0
  const priceCents = Math.round(Number(price) * 100)
  const terms = valid ? { percent: values.service_fee_percent, flatCents: values.service_fee_flat_cents, bearer: values.processing_fee_bearer } : null
  const usable = terms && Number.isFinite(priceCents) && priceCents >= 0
  const fee = usable ? quoteBuyerFeeCents(terms, priceCents).platformFeeCents : 0
  const example = usable ? feeExample(terms, priceCents, 'buyer_pays', 100) : null
  return (
    <section aria-labelledby="fee-example-title" className="rounded-xl border border-neutral-200 bg-neutral-50 p-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h3 id="fee-example-title" className="font-semibold text-neutral-900">Fee example</h3>
          <p className="text-sm text-content-muted">Uses the values above with the same rounding as checkout, for an event where buyers pay the fee.</p>
        </div>
        <label className="text-sm font-medium text-neutral-900">
          Ticket price ($)
          <input type="number" inputMode="decimal" min="0" step="0.01" value={price} onChange={event => setPrice(event.target.value)} className="input mt-1 !w-32 !py-2" />
        </label>
      </div>
      {example ? (
        <dl className="mt-4 grid gap-3 sm:grid-cols-3" aria-live="polite">
          <div className="rounded-lg bg-white p-3 ring-1 ring-neutral-200">
            <dt className="text-xs font-medium text-content-muted">Service fee ({feeRateLabel(terms)})</dt>
            <dd className="mt-1 text-lg font-semibold text-neutral-900">{money(fee)}</dd>
          </div>
          <div className="rounded-lg bg-white p-3 ring-1 ring-neutral-200">
            <dt className="text-xs font-medium text-content-muted">Buyer pays</dt>
            <dd className="mt-1 text-lg font-semibold text-neutral-900">{money(example.buyerPaysCents)}</dd>
          </div>
          <div className="rounded-lg bg-white p-3 ring-1 ring-neutral-200">
            <dt className="text-xs font-medium text-content-muted">Organizer receives</dt>
            <dd className="mt-1 text-lg font-semibold text-neutral-900">{money(example.organizerReceivesCents)}</dd>
            {terms.bearer === 'organizer' && priceCents > 0 && <dd className="mt-0.5 text-xs text-content-muted">minus the actual card processing cost</dd>}
          </div>
          <p className="text-sm text-content-muted sm:col-span-3">
            {priceCents === 0 ? 'Free tickets have no fee.'
              : terms.bearer === 'platform' ? `HåfaPass keeps ${money(fee)} and pays card processing on the ticket out of it.`
                : `HåfaPass keeps ${money(fee)}; card processing is charged to the organizer.`}
          </p>
        </dl>
      ) : <p className="mt-4 text-sm text-content-muted">Enter a valid fee and ticket price to see an example.</p>}
    </section>
  )
}

function AdminSettingsSession({ identity, resourcePath }) {
  const { beginRequest } = usePlatformRequests(identity, resourcePath)
  const confirmTitle = useId()
  const pendingLoad = useRef(null)
  const [saved, setSaved] = useState(null)
  const [form, setForm] = useState(null)
  const [loadError, setLoadError] = useState('')
  const [errors, setErrors] = useState({})
  const [saving, setSaving] = useState(false)
  const [notice, setNotice] = useState('')
  const [confirming, setConfirming] = useState(null)
  const [taxYear, setTaxYear] = useState(String(new Date().getFullYear()))
  const [effectiveAt, setEffectiveAt] = useState('')
  const [feePreview, setFeePreview] = useState(null)
  const [futureTermsApproved, setFutureTermsApproved] = useState(false)

  // `keepForm` re-checks the saved settings (for example payment readiness)
  // without discarding edits the admin has not saved yet.
  const load = useCallback(({ keepForm = false } = {}) => {
    const request = beginRequest()
    if (!request) return Promise.resolve()
    pendingLoad.current?.abort()
    pendingLoad.current = request
    setLoadError('')
    return apiClient.get('/admin/settings', { ...request.config, params: { tax_year: taxYear } })
      .then(response => { if (request.current()) { setSaved(response.data); if (!keepForm) setForm(toForm(response.data)) } })
      .catch(failure => { if (request.current() && !request.handleError(failure)) setLoadError('Settings could not be loaded. Nothing has changed.') })
      .finally(() => request.release())
  }, [beginRequest, taxYear])
  useEffect(() => { load(); return () => pendingLoad.current?.abort() }, [load])

  const changes = useMemo(() => {
    if (!saved || !form) return {}
    const values = toAttributes(form)
    const currentValues = toAttributes(toForm(saved))
    return Object.fromEntries(Object.entries(values).filter(([field, value]) => {
      const current = currentValues[field]
      if (field === 'service_fee_percent') return value == null || Number(current) !== value
      if (field === 'tax_reporting_thresholds') return JSON.stringify(current) !== JSON.stringify(value)
      return (current ?? '') !== (value ?? '')
    }))
  }, [saved, form])
  const feeChanges = Object.keys(changes).filter(field => FEE_FIELDS.includes(field))

  const update = field => event => {
    setForm(previous => ({ ...previous, [field]: event.target.value }))
    setNotice('')
    if (errors[field] || errors[field === 'service_fee_flat' ? 'service_fee_flat_cents' : field]) {
      setErrors(previous => ({ ...previous, [field]: undefined, ...(field === 'service_fee_flat' ? { service_fee_flat_cents: undefined } : {}) }))
    }
  }

  const save = async () => {
    const request = beginRequest()
    if (!request) return
    setSaving(true)
    try {
      const response = await apiClient.patch('/admin/settings', {
        ...changes, tax_year: taxYear, ...(feeChanges.length ? { effective_at: new Date(effectiveAt).toISOString(),
          future_terms_approved: futureTermsApproved,
          approved_registry_digest: feePreview.registry_digest } : {}),
      }, request.config)
      if (!request.current()) return
      setSaved(response.data)
      setForm(toForm(response.data))
      setConfirming(null)
      setErrors({})
      setNotice(feeChanges.length ? 'Fee change scheduled. Affected organizer owners have been queued for notice.' : 'Settings saved.')
    } catch (failure) {
      if (request.handleError(failure) || !request.current()) return
      setConfirming(null)
      const messages = failure.response?.data?.errors
      setErrors(Array.isArray(messages) ? fieldErrorsFrom(messages)
        : { form: failure.response?.data?.error || 'Settings were not saved. Check your connection and try again.' })
    } finally { request.release(); setSaving(false) }
  }

  const submit = async event => {
    event.preventDefault()
    setNotice('')
    const found = validate(form)
    setErrors(found)
    if (Object.keys(found).length) return
    if (!Object.keys(changes).length) { setNotice('There are no changes to save.'); return }
    if (feeChanges.length) {
      try {
        const response = await apiClient.get('/admin/settings/fee_change_preview', {
          params: Object.fromEntries(feeChanges.map(field => [field, changes[field]])),
        })
        setFeePreview(response.data)
        setFutureTermsApproved(false)
        setConfirming(feeChanges)
      } catch { setErrors({ form: 'Could not load the affected organizer count. Try again.' }) }
    }
    else save()
  }

  if (loadError) return <AdminLayout><section role="alert" className="rounded-xl border border-neutral-200 bg-white p-5"><p className="text-neutral-700">{loadError}</p><button type="button" onClick={load} className="btn-primary mt-4">Retry settings</button></section></AdminLayout>
  if (!form) return <AdminLayout><div className="flex justify-center py-20"><Loader2 aria-label="Loading settings" className="h-8 w-8 animate-spin text-brand-500" /></div></AdminLayout>

  const summaryErrors = Object.fromEntries(Object.entries(errors).filter(([field, message]) => message && field !== 'form'))
  const inputClass = field => `input ${errors[field] ? 'input-error' : ''}`

  return (
    <AdminLayout>
      <p className="mb-6 max-w-3xl text-sm text-content-muted">Platform-wide details shown to buyers and organizers. Scheduled fee changes apply only to orders placed on or after their effective date.</p>
      {saved.pending_fee_change && <p role="status" className="mb-5 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950">A fee change is scheduled for {new Date(saved.pending_fee_change.effective_at).toLocaleString()}. Current fees remain in effect until then.</p>}
      {saved.blocked_fee_change && <p role="alert" className="mb-5 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-900">Scheduled fee activation was blocked: {saved.blocked_fee_change.activation_error}. Review the policy text and schedule a corrected change.</p>}
      <FormErrorSummary errors={summaryErrors} title="Check these settings" />
      {errors.form && <p role="alert" className="mb-6 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800">{errors.form}</p>}
      {notice && <p role="status" className="mb-6 rounded-xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900">{notice}</p>}

      <form noValidate onSubmit={submit} className="space-y-6">
        <section aria-labelledby="identity-title" className="card p-5 sm:p-6">
          <h2 id="identity-title" className="text-lg font-semibold text-neutral-900">Platform and support contact</h2>
          <div className="mt-4 grid gap-5 md:grid-cols-2">
            <div className="md:col-span-2">
              <Field id="platform_name" label="Platform name" error={errors.platform_name}>
                <input id="platform_name" value={form.platform_name} onChange={update('platform_name')} maxLength={100} aria-invalid={!!errors.platform_name} aria-describedby={describedBy('platform_name', false, errors.platform_name)} className={inputClass('platform_name')} />
              </Field>
            </div>
            <Field id="platform_email" label="Support email" hint="Shown on receipts, help links and error pages." error={errors.platform_email}>
              <input id="platform_email" type="email" inputMode="email" autoComplete="off" value={form.platform_email} onChange={update('platform_email')} aria-invalid={!!errors.platform_email} aria-describedby={describedBy('platform_email', true, errors.platform_email)} className={inputClass('platform_email')} />
            </Field>
            <Field id="platform_phone" label="Support phone" hint="Optional. Shown next to the support email." error={errors.platform_phone}>
              <input id="platform_phone" type="tel" inputMode="tel" autoComplete="off" value={form.platform_phone} onChange={update('platform_phone')} aria-invalid={!!errors.platform_phone} aria-describedby={describedBy('platform_phone', true, errors.platform_phone)} className={inputClass('platform_phone')} />
            </Field>
            <Field id="business_mailing_address" label="Business mailing address" hint="Required before organizers can send promotional emails. Include a physical postal address." error={errors.business_mailing_address}>
              <textarea id="business_mailing_address" rows={3} maxLength={500} value={form.business_mailing_address} onChange={update('business_mailing_address')} className={inputClass('business_mailing_address')} />
            </Field>
          </div>
        </section>

        <section aria-labelledby="tax-controls-settings" className="card p-5 sm:p-6">
          <h2 id="tax-controls-settings" className="text-lg font-semibold">Tax payout controls</h2>
          <p className="mt-1 text-sm text-neutral-700">Backup withholding affects payouts. Choose the tax year for threshold corrections; a CPA should approve changes before filing.</p>
          <div className="mt-4 grid gap-4 sm:grid-cols-2">
            <label className="text-sm font-medium">When backup withholding applies<select className="input mt-1" value={form.backup_withholding_mode} onChange={update('backup_withholding_mode')}><option value="block">Block payout (default)</option><option value="withhold">Withhold and pay the balance</option></select></label>
            <label className="text-sm font-medium">Withholding rate (basis points)<input className="input mt-1" type="number" min="1" max="9999" value={form.backup_withholding_rate_bps} onChange={update('backup_withholding_rate_bps')} /></label>
            <label className="text-sm font-medium">Tax year<select className="input mt-1" value={taxYear} onChange={event => setTaxYear(event.target.value)}>{Array.from({ length: new Date().getFullYear() - 1999 }, (_, index) => new Date().getFullYear() - index).map(value => <option key={value} value={value}>{value}</option>)}</select></label>
            {[['threshold_nec', '1099-NEC'], ['threshold_misc', '1099-MISC'], ['threshold_k', '1099-K']].map(([field, label]) => <label key={field} className="text-sm font-medium">{label} threshold (cents)<input className="input mt-1" type="number" min="0" step="1" value={form[field]} onChange={update(field)} /></label>)}
          </div>
        </section>

        <section aria-labelledby="fees-title" className="card p-5 sm:p-6">
          <h2 id="fees-title" className="text-lg font-semibold text-neutral-900">Fees and payouts</h2>
          <p className="mt-1 text-sm text-content-muted">Applies to new orders only. Existing orders keep their terms.</p>
          <p className="mt-2 text-sm text-amber-900">These terms are part of the organizer agreement. Changing them asks every organizer to accept again and needs a new policy register approval. The platform name and support contact can change at any time without that.</p>
          <div className="mt-4 grid gap-5 md:grid-cols-2">
            <Field id="service_fee_percent" label="Service fee percentage" hint={`Of each paid ticket’s price, 0 to ${MAX_FEE_PERCENT}%.`} error={errors.service_fee_percent}>
              <div className="relative">
                <input id="service_fee_percent" type="number" inputMode="decimal" min="0" max={MAX_FEE_PERCENT} step="0.01" value={form.service_fee_percent} onChange={update('service_fee_percent')} aria-invalid={!!errors.service_fee_percent} aria-describedby={describedBy('service_fee_percent', true, errors.service_fee_percent)} className={`${inputClass('service_fee_percent')} pr-10`} />
                <span aria-hidden="true" className="pointer-events-none absolute right-4 top-1/2 -translate-y-1/2 text-content-muted">%</span>
              </div>
            </Field>
            <Field id="service_fee_flat_cents" label="Flat fee per paid ticket" hint={`In dollars, up to ${money(MAX_FLAT_CENTS)}. Free tickets never carry a fee.`} error={errors.service_fee_flat_cents}>
              <div className="relative">
                <span aria-hidden="true" className="pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 text-content-muted">$</span>
                <input id="service_fee_flat_cents" type="number" inputMode="decimal" min="0" max={MAX_FLAT_CENTS / 100} step="0.01" value={form.service_fee_flat} onChange={update('service_fee_flat')} aria-invalid={!!errors.service_fee_flat_cents} aria-describedby={describedBy('service_fee_flat_cents', true, errors.service_fee_flat_cents)} className={`${inputClass('service_fee_flat_cents')} pl-8`} />
              </div>
            </Field>
          </div>

          <fieldset className="mt-6">
            <legend id="processing_fee_bearer" tabIndex={-1} className="text-sm font-medium text-neutral-900">Who pays card processing?</legend>
            <div className="mt-2 grid gap-3 md:grid-cols-2">
              {Object.entries(BEARERS).map(([value, option]) => (
                <label key={value} className={`flex cursor-pointer gap-3 rounded-xl border p-4 transition-[border-color,background-color] duration-150 ease-out-strong ${form.processing_fee_bearer === value ? 'border-brand-600 bg-brand-50' : 'border-neutral-200 bg-white hover:border-neutral-300'}`}>
                  <input type="radio" name="processing_fee_bearer" value={value} checked={form.processing_fee_bearer === value} onChange={update('processing_fee_bearer')} className="mt-1 h-4 w-4 shrink-0 accent-brand-700" />
                  <span><span className="block font-medium text-neutral-900">{option.title}</span><span className="mt-0.5 block text-sm text-content-muted">{option.body}</span></span>
                </label>
              ))}
            </div>
            {errors.processing_fee_bearer && <p className="mt-1.5 text-sm text-red-700">{errors.processing_fee_bearer}</p>}
          </fieldset>

          <div className="mt-6">
            <FeeExample form={form} />
          </div>

          <div className="mt-6">
            <Field id="payout_schedule_text" label="Payout timing" hint={`Completes the sentence “Payouts are sent …” on organizer screens. ${form.payout_schedule_text.length}/${MAX_SCHEDULE_LENGTH} characters.`} error={errors.payout_schedule_text}>
              <textarea id="payout_schedule_text" rows={2} maxLength={MAX_SCHEDULE_LENGTH + 50} value={form.payout_schedule_text} onChange={update('payout_schedule_text')} aria-invalid={!!errors.payout_schedule_text} aria-describedby={describedBy('payout_schedule_text', true, errors.payout_schedule_text)} className={inputClass('payout_schedule_text')} />
            </Field>
          </div>
          <div className="mt-6">
            <Field id="fee_notice_days" label="Minimum organizer notice (days)" hint="Fee term changes must be scheduled this many days ahead." error={errors.fee_notice_days}>
              <input id="fee_notice_days" type="number" min="1" max="365" step="1" value={form.fee_notice_days} onChange={update('fee_notice_days')} className={inputClass('fee_notice_days')} />
            </Field>
          </div>
        </section>

        <div className="flex flex-wrap items-center gap-3">
          <button type="submit" disabled={saving} className="btn-primary">{saving ? 'Saving…' : 'Save settings'}</button>
          {Object.keys(changes).length > 0 && <button type="button" disabled={saving} onClick={() => { setForm(toForm(saved)); setErrors({}); setNotice('') }} className="btn-secondary">Discard changes</button>}
        </div>
      </form>

      <PaymentModeSwitch settings={saved} beginRequest={beginRequest} onChanged={data => setSaved(previous => ({ ...previous, ...data }))} onRefresh={() => load({ keepForm: true })} />

      {confirming && <Dialog labelledBy={confirmTitle} busy={saving} onClose={() => setConfirming(null)} className="max-w-lg">
        <h2 id={confirmTitle} className="text-lg font-semibold text-neutral-900">Schedule fee term changes?</h2>
        <p className="mt-2 text-sm text-neutral-700">The new terms apply to orders placed on or after the effective date. Existing orders keep their recorded terms. The change and organizer acknowledgments are audited.</p>
        {saved.policy_register_approved === false && <p role="alert" className="mt-2 text-sm text-red-800">Approve the current policy register in <Link to="/admin/provider-readiness" className="font-semibold underline">provider readiness</Link> before scheduling a fee change.</p>}
        <p className="mt-2 font-semibold text-neutral-900">{feePreview?.affected_organizer_count ?? '—'} organizations affected · {feePreview?.owner_email_count ?? '—'} owners will be emailed.</p>
        {feePreview?.unreachable_organizations?.length > 0 && <div role="alert" className="mt-2 text-sm text-red-800"><p>{feePreview.unreachable_organizations.length} affected {feePreview.unreachable_organizations.length === 1 ? 'organization has' : 'organizations have'} no reachable owner:</p><ul className="mt-1 list-disc pl-5">{feePreview.unreachable_organizations.map(organization => <li key={organization.id}>{organization.name}</li>)}</ul></div>}
        <label className="mt-4 block text-sm font-medium text-neutral-900">Effective date and time
          <input type="datetime-local" value={effectiveAt} onChange={event => setEffectiveAt(event.target.value)} className="input mt-1" required />
          <span className="mt-1 block text-xs text-content-muted">At least {form.fee_notice_days} days from now. Time is interpreted in your browser’s time zone.</span>
        </label>
        <div className="mt-3 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950" data-testid="policy-terms-effect">
          <p className="font-semibold">This also changes the organizer agreement.</p>
          <ul className="mt-1 list-disc space-y-0.5 pl-5">
            <li>Every organizer must accept the updated agreement before publishing again.</li>
            <li>The current policy approval applies until this change activates. Approve the exact future terms below so checkout stays available.</li>
          </ul>
        </div>
        <dl className="mt-4 space-y-3 text-sm">
          {confirming.map(field => (
            <div key={field} className="rounded-lg bg-neutral-50 p-3 ring-1 ring-neutral-200">
              <dt className="font-medium text-neutral-900">{FIELD_LABELS[field]}</dt>
              <dd className="mt-1 text-neutral-700"><span className="line-through decoration-neutral-400">{describe(field, saved[field])}</span> <span aria-hidden="true">→</span><span className="sr-only">changes to</span> <strong>{describe(field, changes[field])}</strong></dd>
            </div>
          ))}
        </dl>
        <p className="mt-4 break-all text-xs text-neutral-600">Future policy register digest: <code>{feePreview?.registry_digest}</code></p>
        <label className="mt-4 flex gap-2 text-sm text-neutral-900"><input type="checkbox" checked={futureTermsApproved} onChange={event => setFutureTermsApproved(event.target.checked)} />I approve these exact future fee and policy terms at the effective date.</label>
        <div className="mt-6 flex flex-wrap justify-end gap-3">
          <button type="button" disabled={saving} onClick={() => setConfirming(null)} className="btn-secondary">Keep editing</button>
          <button type="button" disabled={saving || saved.policy_register_approved === false || !feePreview?.registry_digest || !futureTermsApproved || !effectiveAt || new Date(effectiveAt).getTime() < Date.now() + Number(form.fee_notice_days) * 86400000} onClick={save} className="btn-primary">{saving ? 'Scheduling…' : 'Schedule fee change'}</button>
        </div>
      </Dialog>}
    </AdminLayout>
  )
}

export default function AdminSettingsPage() {
  return <AdminSessionGate resourcePath="/admin/settings" Session={AdminSettingsSession} />
}
