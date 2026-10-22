import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react'
import { Loader2 } from 'lucide-react'
import { Link } from 'react-router-dom'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'
import AdminSessionGate from './AdminSessionGate'
import Dialog from '../../components/Dialog'
import FormErrorSummary from '../../components/FormErrorSummary'
import { usePlatformRequests } from '../../hooks/usePlatformContext'
import { feeExample, feeRateLabel, platformFeeCents } from '../../utils/feeTerms'
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
  const fee = usable ? platformFeeCents(terms, priceCents, priceCents > 0 ? 1 : 0) : 0
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
  const [purgeAcknowledged, setPurgeAcknowledged] = useState(false)
  const [purgeSaving, setPurgeSaving] = useState(false)

  // `keepForm` re-checks the saved settings (for example payment readiness)
  // without discarding edits the admin has not saved yet.
  const load = useCallback(({ keepForm = false } = {}) => {
    const request = beginRequest()
    if (!request) return Promise.resolve()
    pendingLoad.current?.abort()
    pendingLoad.current = request
    setLoadError('')
    return apiClient.get('/admin/settings', request.config)
      .then(response => { if (request.current()) { setSaved(response.data); if (!keepForm) setForm(toForm(response.data)) } })
      .catch(failure => { if (request.current() && !request.handleError(failure)) setLoadError('Settings could not be loaded. Nothing has changed.') })
      .finally(() => request.release())
  }, [beginRequest])
  useEffect(() => { load(); return () => pendingLoad.current?.abort() }, [load])

  const changes = useMemo(() => {
    if (!saved || !form) return {}
    const values = toAttributes(form)
    return Object.fromEntries(Object.entries(values).filter(([field, value]) => {
      const current = saved[field]
      if (field === 'service_fee_percent') return value == null || Number(current) !== value
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
      const response = await apiClient.patch('/admin/settings', changes, request.config)
      if (!request.current()) return
      setSaved(response.data)
      setForm(toForm(response.data))
      setConfirming(null)
      setErrors({})
      setNotice(feeChanges.length ? 'Settings saved. New orders use the new fee terms; existing orders keep theirs.' : 'Settings saved.')
    } catch (failure) {
      if (request.handleError(failure) || !request.current()) return
      setConfirming(null)
      const messages = failure.response?.data?.errors
      setErrors(Array.isArray(messages) ? fieldErrorsFrom(messages)
        : { form: failure.response?.data?.error || 'Settings were not saved. Check your connection and try again.' })
    } finally { request.release(); setSaving(false) }
  }

  const submit = event => {
    event.preventDefault()
    setNotice('')
    const found = validate(form)
    setErrors(found)
    if (Object.keys(found).length) return
    if (!Object.keys(changes).length) { setNotice('There are no changes to save.'); return }
    if (feeChanges.length) setConfirming(feeChanges)
    else save()
  }

  const setPurgeEnabled = async enabled => {
    const request = beginRequest()
    if (!request) return
    setPurgeSaving(true); setErrors({}); setNotice('')
    try {
      const response = await apiClient.patch('/admin/settings', { retention_purge_enabled: enabled }, request.config)
      if (request.current()) {
        setSaved(response.data)
        setPurgeAcknowledged(false)
        setNotice(enabled ? 'Scheduled retention purge is enabled. The environment dry-run flag still takes precedence.' : 'Scheduled retention purge is in dry-run mode.')
      }
    } catch (failure) {
      if (request.current() && !request.handleError(failure)) setErrors({ form: failure.response?.data?.error || 'Retention setting was not saved.' })
    } finally { request.release(); setPurgeSaving(false) }
  }

  if (loadError) return <AdminLayout><section role="alert" className="rounded-xl border border-neutral-200 bg-white p-5"><p className="text-neutral-700">{loadError}</p><button type="button" onClick={load} className="btn-primary mt-4">Retry settings</button></section></AdminLayout>
  if (!form) return <AdminLayout><div className="flex justify-center py-20"><Loader2 aria-label="Loading settings" className="h-8 w-8 animate-spin text-brand-500" /></div></AdminLayout>

  const summaryErrors = Object.fromEntries(Object.entries(errors).filter(([field, message]) => message && field !== 'form'))
  const inputClass = field => `input ${errors[field] ? 'input-error' : ''}`

  return (
    <AdminLayout>
      <p className="mb-6 max-w-3xl text-sm text-content-muted">Platform-wide details shown to buyers and organizers. Fee changes apply to new orders only; orders already placed keep the fee and processing terms they were sold with.</p>
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
        </section>

        <div className="flex flex-wrap items-center gap-3">
          <button type="submit" disabled={saving} className="btn-primary">{saving ? 'Saving…' : 'Save settings'}</button>
          {Object.keys(changes).length > 0 && <button type="button" disabled={saving} onClick={() => { setForm(toForm(saved)); setErrors({}); setNotice('') }} className="btn-secondary">Discard changes</button>}
        </div>
      </form>

      <PaymentModeSwitch settings={saved} beginRequest={beginRequest} onChanged={data => setSaved(previous => ({ ...previous, ...data }))} onRefresh={() => load({ keepForm: true })} />

      <section aria-labelledby="retention-purge-title" className="mt-6 card p-5 sm:p-6">
        <h2 id="retention-purge-title" className="text-lg font-semibold text-neutral-900">Data retention purge</h2>
        <p className="mt-2 text-sm text-neutral-700">Production starts in dry-run mode. Scheduled runs count eligible records without changing them until you enable purge here. A legal hold always prevents disposal.</p>
        <p className="mt-2 text-sm font-semibold text-neutral-900">Current mode: {saved.retention_dry_run ? 'Dry run' : 'Live purge'}</p>
        {saved.environment === 'production' && !saved.retention_purge_enabled && <label className="mt-4 flex items-start gap-2 text-sm text-neutral-800"><input type="checkbox" checked={purgeAcknowledged} onChange={event => setPurgeAcknowledged(event.target.checked)} className="mt-1" />I have reviewed the retention schedule with counsel and the CPA.</label>}
        <button type="button" disabled={purgeSaving || (!saved.retention_purge_enabled && saved.environment === 'production' && !purgeAcknowledged)}
          onClick={() => setPurgeEnabled(!saved.retention_purge_enabled)} className="btn-secondary mt-4">
          {purgeSaving ? 'Saving…' : saved.retention_purge_enabled ? 'Return to dry run' : 'Enable scheduled purge'}
        </button>
      </section>

      {confirming && <Dialog labelledBy={confirmTitle} busy={saving} onClose={() => setConfirming(null)} className="max-w-lg">
        <h2 id={confirmTitle} className="text-lg font-semibold text-neutral-900">Change fee terms for new orders?</h2>
        <p className="mt-2 text-sm text-neutral-700">These changes apply to orders placed after you save. Existing orders, settlements and payouts keep the terms they were sold with. The change is recorded in the audit log under your name.</p>
        <div className="mt-3 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950" data-testid="policy-terms-effect">
          <p className="font-semibold">This also changes the organizer agreement.</p>
          <ul className="mt-1 list-disc space-y-0.5 pl-5">
            <li>Every organizer must accept the updated agreement before publishing again.</li>
            <li>Any production policy register approval stops applying; it needs a new approval in <Link to="/admin/provider-readiness" className="font-semibold underline">provider readiness</Link>.</li>
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
        <div className="mt-6 flex flex-wrap justify-end gap-3">
          <button type="button" disabled={saving} onClick={() => setConfirming(null)} className="btn-secondary">Keep editing</button>
          <button type="button" disabled={saving} onClick={save} className="btn-primary">{saving ? 'Saving…' : 'Save fee terms'}</button>
        </div>
      </Dialog>}
    </AdminLayout>
  )
}

export default function AdminSettingsPage() {
  return <AdminSessionGate resourcePath="/admin/settings" Session={AdminSettingsSession} />
}
