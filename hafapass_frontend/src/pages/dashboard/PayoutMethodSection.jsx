import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { payoutReviewLabel, payoutRequirementLabel } from '../../utils/payoutLabels'
import { CheckCircle2, CircleAlert, Landmark, Mail, WalletCards } from 'lucide-react'
import { useState } from 'react'
import BankPayoutDetails from './BankPayoutDetails'

const emptyCheck = { payee_name: '', delivery_method: 'mail', mailing_address: '', pickup_note: '', memo: '' }

function AccountStatus({ account }) {
  if (!account) return null
  return (
    <div className="mt-4 rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm">
      <p className={`flex items-center gap-2 font-semibold ${account.payout_ready ? 'text-emerald-800' : 'text-amber-900'}`}>
        {account.payout_ready ? <CheckCircle2 aria-hidden="true" className="h-4 w-4" /> : <CircleAlert aria-hidden="true" className="h-4 w-4" />}
        {account.payout_review ? payoutReviewLabel(account) : account.payout_ready ? 'Paid-ticket setup approved' : 'Saved — waiting for HåfaPass review'}
      </p>
      {account.payout_review?.note && <p className="mt-2 whitespace-pre-line [overflow-wrap:anywhere]">Review note: {account.payout_review.note}</p>}
      {account.payout_review?.missing?.length > 0 && <ul className="mt-2 list-disc space-y-1 pl-5 [overflow-wrap:anywhere]">{account.payout_review.missing.map((item, index) => <li key={index}>{item}</li>)}</ul>}
      {account.payout_review?.review_by && <p className="mt-2">Review again by {account.payout_review.review_by}</p>}
      {!account.payout_review && !account.payout_ready && account.requirements_due?.length > 0 && (
        <>
          <p className="mt-2 text-neutral-700">What HåfaPass does next:</p>
          <ul className="mt-1 list-disc space-y-1 pl-5 text-neutral-700">{account.requirements_due.map(code => <li key={code}>{payoutRequirementLabel(code)}</li>)}</ul>
          <p className="mt-2 text-neutral-700">Complete and certify your W-9 in Tax information too. Free events do not need paid-ticket setup.</p>
        </>
      )}
    </div>
  )
}

// How an organizer gets paid. HåfaPass collects ticket money and pays the
// organizer after each event settles.
export default function PayoutMethodSection({ accounts, busy, onSave, error, notice }) {
  const { t } = useTranslation()
  const checkAccount = accounts.find(item => item.provider === 'check')
  const bankAccount = accounts.find(item => item.provider === 'manual')
  const selectedMethod = checkAccount?.selected ? 'check' : 'manual'
  const [viewedMethod, setViewedMethod] = useState(null)
  const method = viewedMethod || selectedMethod
  const [details, setDetails] = useState(() => ({ ...emptyCheck, ...(checkAccount?.payout_details || {}) }))
  const [errors, setErrors] = useState({})
  const [editing, setEditing] = useState(!checkAccount)
  const set = field => event => setDetails(current => ({ ...current, [field]: event.target.value }))

  const saveCheck = async event => {
    event.preventDefault()
    const found = {}
    if (!details.payee_name.trim()) found.payee_name = 'Enter the name to write on the check.'
    if (details.delivery_method === 'mail' && !details.mailing_address.trim()) found.mailing_address = 'Enter the mailing address.'
    setErrors(found)
    if (Object.keys(found).length) return
    const saved = await onSave({ provider: 'check', accountId: checkAccount?.id, payout_details: details })
    if (saved) setEditing(false)
  }

  const fieldError = name => errors[name] && <p id={`payout-${name}-error`} className="mt-1 text-sm text-red-700">{errors[name]}</p>

  return (
    <section className="rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6" aria-labelledby="payout-heading">
      <div className="flex items-center gap-3"><WalletCards aria-hidden="true" className="h-5 w-5 text-brand-600" /><h2 id="payout-heading" className="text-lg font-semibold text-neutral-900">How you get paid</h2></div>
      <p className="mt-2 text-sm text-neutral-700">{t('buyerDiscovery.host.payouts')}{' '}{t('buyerDiscovery.host.payoutMethod')}{' '}<Link to="/policies/organizer-agreement" className="underline underline-offset-4">{t('buyerDiscovery.host.payoutAgreementLink')}</Link></p>

      <fieldset className="mt-5" disabled={busy}>
        <legend className="sr-only">Payout method</legend>
        <div className="grid gap-2 sm:grid-cols-2">
          {[
            { value: 'manual', icon: Landmark, title: 'Bank transfer', body: 'HåfaPass sends the payout to your approved bank account.' },
            { value: 'check', icon: Mail, title: 'Check', body: 'For approved exceptions. Mailed to you or ready for pickup.' },
          ].map(option => (
            <label key={option.value} className={`flex min-h-11 gap-3 rounded-xl border p-3 transition-colors duration-150 ease-out-strong ${method === option.value ? 'border-brand-600 bg-brand-50' : 'border-neutral-200 [@media(hover:hover)]:hover:border-neutral-300'}`}>
              <input type="radio" name="payout-method" value={option.value} checked={method === option.value} onChange={() => setViewedMethod(option.value)} className="mt-1 h-4 w-4 shrink-0 accent-brand-600" />
              <span><span className="flex items-center gap-2 text-sm font-semibold text-neutral-900"><option.icon aria-hidden="true" className="h-4 w-4" />{option.title}</span><span className="block text-sm text-content-muted">{option.body}</span></span>
            </label>
          ))}
        </div>
      </fieldset>

      {error && <p role="alert" className="mt-4 rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-800">{error}</p>}
      {notice && <p role="status" className="mt-4 rounded-xl border border-brand-200 bg-brand-50 p-3 text-sm text-brand-900">{notice}</p>}

      {method === 'check' && (
        <div className="mt-5">
          {checkAccount && !editing ? (
            <div className="rounded-xl border border-neutral-200 p-4 text-sm">
              <dl className="grid gap-2 sm:grid-cols-[10rem_1fr]">
                <dt className="text-content-muted">Pay to</dt><dd className="font-medium text-neutral-900 [overflow-wrap:anywhere]">{checkAccount.payout_details?.payee_name}</dd>
                <dt className="text-content-muted">Delivery</dt><dd className="whitespace-pre-line text-neutral-900 [overflow-wrap:anywhere]">{checkAccount.payout_details?.delivery_method === 'pickup' ? `Pickup${checkAccount.payout_details?.pickup_note ? ` — ${checkAccount.payout_details.pickup_note}` : ''}` : `Mail to ${checkAccount.payout_details?.mailing_address || ''}`}</dd>
                {checkAccount.payout_details?.memo && <><dt className="text-content-muted">Memo</dt><dd className="text-neutral-900 [overflow-wrap:anywhere]">{checkAccount.payout_details.memo}</dd></>}
              </dl>
              {!checkAccount.selected && <button type="button" disabled={busy} onClick={() => onSave({ provider: 'check', accountId: checkAccount.id })} className="btn-primary mt-4 mr-3">Use this check payout method</button>}
              {checkAccount.selected && <p className="mt-3 font-semibold text-neutral-800">Selected payout method</p>}
              <button type="button" onClick={() => setEditing(true)} disabled={busy} className="btn-secondary mt-4 !px-4 !py-2 text-sm">Change check details</button>
              <p className="mt-2 text-xs text-content-muted">Changing who the check is for or where it goes needs a fresh HåfaPass review before the next payout.</p>
            </div>
          ) : (
            <form onSubmit={saveCheck} noValidate className="space-y-4">
              <label className="block text-sm font-medium text-neutral-900">
                Pay to (name on the check)
                <input value={details.payee_name} onChange={set('payee_name')} maxLength={200} className={`input mt-1 ${errors.payee_name ? 'input-error' : ''}`} aria-invalid={!!errors.payee_name} aria-describedby={errors.payee_name ? 'payout-payee_name-error' : undefined} placeholder="Your business or legal name" />
              </label>
              {fieldError('payee_name')}
              <fieldset>
                <legend className="text-sm font-medium text-neutral-900">How should we get the check to you?</legend>
                <div className="mt-2 flex flex-wrap gap-2">
                  {[['mail', 'Mail it to me'], ['pickup', 'I’ll pick it up']].map(([value, text]) => (
                    <label key={value} className={`flex min-h-11 cursor-pointer items-center gap-2 rounded-xl border px-3 text-sm ${details.delivery_method === value ? 'border-brand-600 bg-brand-50 font-semibold' : 'border-neutral-200'}`}>
                      <input type="radio" name="check-delivery" value={value} checked={details.delivery_method === value} onChange={set('delivery_method')} className="h-4 w-4 accent-brand-600" />{text}
                    </label>
                  ))}
                </div>
              </fieldset>
              {details.delivery_method === 'mail' ? (
                <>
                  <label className="block text-sm font-medium text-neutral-900">
                    Mailing address
                    <textarea value={details.mailing_address} onChange={set('mailing_address')} rows={3} maxLength={500} className={`input mt-1 ${errors.mailing_address ? 'input-error' : ''}`} aria-invalid={!!errors.mailing_address} aria-describedby={errors.mailing_address ? 'payout-mailing_address-error' : undefined} placeholder="PO Box or street, village, GU 969xx" />
                  </label>
                  {fieldError('mailing_address')}
                </>
              ) : (
                <label className="block text-sm font-medium text-neutral-900">
                  Pickup note <span className="font-normal text-content-muted">(optional)</span>
                  <input value={details.pickup_note} onChange={set('pickup_note')} maxLength={300} className="input mt-1" placeholder="Who will pick it up, best days or times" />
                </label>
              )}
              <label className="block text-sm font-medium text-neutral-900">
                Memo <span className="font-normal text-content-muted">(optional)</span>
                <input value={details.memo} onChange={set('memo')} maxLength={200} className="input mt-1" placeholder="Anything you’d like written on the memo line" />
              </label>
              <div className="flex flex-wrap gap-3">
                <button type="submit" disabled={busy} className="btn-primary">{busy ? 'Saving…' : 'Save check details'}</button>
                {checkAccount && <button type="button" onClick={() => { setDetails({ ...emptyCheck, ...(checkAccount.payout_details || {}) }); setErrors({}); setEditing(false) }} disabled={busy} className="btn-secondary">Cancel</button>}
              </div>
            </form>
          )}
          <AccountStatus account={checkAccount} />
        </div>
      )}

      {method === 'manual' && (
        <div className="mt-5">
          <BankPayoutDetails account={bankAccount} busy={busy} onSave={onSave} />
          {bankAccount?.selected && <p className="mt-3 text-sm font-semibold text-neutral-800">Selected payout method</p>}
          {bankAccount?.payout_details?.masked_account && !bankAccount.selected && (
            <button type="button" disabled={busy} onClick={() => onSave({ provider: 'manual', accountId: bankAccount.id })} className="btn-primary mt-4">Use this bank payout method</button>
          )}
          <AccountStatus account={bankAccount} />
        </div>
      )}

      {accounts.some(item => ['paypal', 'stripe'].includes(item.provider)) && (
        <details className="mt-5 rounded-xl border border-neutral-200 p-4 text-sm">
          <summary className="min-h-11 cursor-pointer font-semibold text-neutral-800">Earlier PayPal or Stripe setup</summary>
          {accounts.filter(item => ['paypal', 'stripe'].includes(item.provider)).map(item => (
            <p key={item.id} className="mt-2 text-neutral-700">{item.provider === 'paypal' ? 'PayPal' : 'Stripe'}: {item.payout_ready ? 'ready' : 'not in use'}. Choose a payout method above for your event proceeds.</p>
          ))}
        </details>
      )}
    </section>
  )
}
