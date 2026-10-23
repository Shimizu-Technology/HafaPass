import { useEffect, useState } from 'react'
import apiClient from '../api/client'
import FeeTermsNote from './FeeTermsNote'
import usePlatformFeeTerms from '../hooks/usePlatformFeeTerms'
import { feeExample } from '../utils/feeTerms'

const EXAMPLE_PRICE_CENTS = 2500

const POLICIES = [
  { value: 'buyer_pays', label: 'Buyer pays the fee', hint: 'Recommended. The fee is included in the ticket price buyers see.' },
  { value: 'organizer_absorbs', label: 'I cover the fee', hint: 'Buyers pay only the ticket price.' },
  { value: 'split_fees', label: 'Split the fee', hint: 'Choose the share buyers pay.' },
]

function dollars(cents) {
  return `$${(cents / 100).toFixed(2)}`
}

function savedChoice(event) {
  return { fee_policy: event?.fee_policy || 'buyer_pays', buyer_fee_percent: event?.buyer_fee_percent ?? 100 }
}

// Requests the server applies to buyer_fee_percent for each policy; split
// shares are 1–99 so a split never silently becomes one of the other policies.
function requestBody(choice) {
  if (choice.fee_policy === 'buyer_pays') return { fee_policy: 'buyer_pays', buyer_fee_percent: 100 }
  if (choice.fee_policy === 'organizer_absorbs') return { fee_policy: 'organizer_absorbs', buyer_fee_percent: 0 }
  return { fee_policy: 'split_fees', buyer_fee_percent: Number(choice.buyer_fee_percent) }
}

// Who pays the HåfaPass service fee for this event. Saved on its own, like
// ticket types; the choice applies to new orders only.
export default function FeePolicyPanel({ eventId, event, canEdit, beginRequest, onSaved, onDirtyChange }) {
  const feeTerms = usePlatformFeeTerms()
  const [choice, setChoice] = useState(() => savedChoice(event))
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState(null)
  const [notice, setNotice] = useState('')
  const saved = savedChoice(event)
  const body = requestBody(choice)
  const dirty = body.fee_policy !== saved.fee_policy || body.buyer_fee_percent !== Number(saved.buyer_fee_percent)
  const splitInvalid = choice.fee_policy === 'split_fees' &&
    !(Number.isInteger(Number(choice.buyer_fee_percent)) && Number(choice.buyer_fee_percent) >= 1 && Number(choice.buyer_fee_percent) <= 99)

  // Read-only viewers cannot save, so they never hold unsaved changes.
  useEffect(() => { onDirtyChange?.(canEdit && dirty) }, [canEdit, dirty, onDirtyChange])
  // Follow a reloaded saved value (for example after another tab's change).
  useEffect(() => {
    setChoice({ fee_policy: event?.fee_policy || 'buyer_pays', buyer_fee_percent: event?.buyer_fee_percent ?? 100 })
  }, [event?.fee_policy, event?.buyer_fee_percent])

  const save = async () => {
    if (!canEdit || saving || !dirty || splitInvalid) return
    const request = beginRequest()
    if (!request) return
    setSaving(true); setError(null); setNotice('')
    try {
      const response = await apiClient.put(`/organizer/events/${eventId}`, body, request.config)
      if (!request.current()) return
      onSaved(response.data)
      if (response.data?.fee_policy !== body.fee_policy || Number(response.data?.buyer_fee_percent) !== body.buyer_fee_percent) {
        setError('The fee choice was not changed. Your access may not include event management; refresh to see the saved choice.')
        return
      }
      setNotice('Fee choice saved. It applies to new orders.')
    } catch (requestError) {
      if (!request.current()) return
      const uncertain = !requestError.response || requestError.response.status >= 500
      setError(uncertain
        ? 'We could not confirm the save. Refresh the page to check the saved fee choice before trying again.'
        : requestError.response?.data?.errors?.join(', ') || requestError.response?.data?.error || 'Unable to save the fee choice.')
    } finally {
      request.release()
      if (request.current()) setSaving(false)
    }
  }

  const example = feeTerms.terms && !splitInvalid
    ? feeExample(feeTerms.terms, EXAMPLE_PRICE_CENTS, body.fee_policy, body.buyer_fee_percent)
    : null

  return (
    <section id="fee-policy" aria-labelledby="fee-policy-heading" className="mt-10 border-t border-neutral-200 pt-6">
      <h2 id="fee-policy-heading" className="text-lg font-semibold text-neutral-900">Who pays the service fee</h2>
      <p className="mt-1 text-sm text-neutral-500">Saved separately from event details.</p>
      <fieldset disabled={!canEdit || saving} className="mt-4 min-w-0">
        <legend className="sr-only">Service fee policy</legend>
        <div className="grid gap-2 sm:grid-cols-3">
          {POLICIES.map(policy => (
            <label key={policy.value} className={`flex min-h-11 cursor-pointer items-start gap-3 rounded-xl border p-3 text-sm transition-colors duration-150 ease-out-strong ${choice.fee_policy === policy.value ? 'border-brand-500 bg-brand-50' : 'border-neutral-200 bg-white'}`}>
              <input type="radio" name="fee_policy" value={policy.value} checked={choice.fee_policy === policy.value}
                onChange={() => { setChoice(current => ({ ...current, fee_policy: policy.value, buyer_fee_percent: policy.value === 'split_fees' ? 50 : current.buyer_fee_percent })); setNotice('') }}
                className="mt-0.5" />
              <span><span className="block font-semibold text-neutral-900">{policy.label}</span><span className="block text-neutral-500">{policy.hint}</span></span>
            </label>
          ))}
        </div>
        {choice.fee_policy === 'split_fees' && (
          <label className="mt-3 flex max-w-xs flex-col gap-1 text-sm font-medium text-neutral-700">
            Buyer share of the fee (%)
            <input className="input font-normal" type="number" inputMode="numeric" min="1" max="99" step="1"
              aria-invalid={splitInvalid || undefined} aria-describedby={splitInvalid ? 'fee-split-error' : undefined}
              value={choice.buyer_fee_percent} onChange={e => setChoice(current => ({ ...current, buyer_fee_percent: e.target.value }))} />
            {splitInvalid && <span id="fee-split-error" className="text-sm text-red-700">Enter a whole number from 1 to 99.</span>}
          </label>
        )}
      </fieldset>

      <FeeTermsNote className="mt-4" feeTerms={feeTerms} feePolicy={body.fee_policy} buyerFeePercent={body.buyer_fee_percent} />
      {example && (
        <p className="mt-3 text-sm text-neutral-700" data-testid="fee-example">
          On a {dollars(EXAMPLE_PRICE_CENTS)} ticket: buyer pays {dollars(example.buyerPaysCents)}, you receive {dollars(example.organizerReceivesCents)}{feeTerms.terms.bearer === 'organizer' ? ' before card processing' : ''}.
        </p>
      )}

      {error && <p role="alert" className="mt-3 rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-700">{error}</p>}
      {notice && <p role="status" className="mt-3 text-sm text-emerald-700">{notice}</p>}
      {!canEdit && <p className="mt-3 text-sm text-neutral-500">Only members who can manage this event can change who pays the fee.</p>}
      {canEdit && (
        <button type="button" onClick={save} disabled={saving || !dirty || splitInvalid} className="btn-primary mt-4 w-full active:scale-[0.97] sm:w-auto">
          {saving ? 'Saving…' : 'Save fee choice'}
        </button>
      )}
    </section>
  )
}
