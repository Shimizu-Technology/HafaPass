import { useEffect, useState } from 'react'

import { TAX_CLASSIFICATIONS } from '../../utils/taxInformation'

const empty = { legal_name: '', business_name: '', tax_classification: '', tin_type: 'ein', tin: '', mailing_address: '', exempt_payee_code: '', signer_name: '', certified: false }

export default function TaxInformationSection({ request, mailingAddress = '', onSaved }) {
  const [data, setData] = useState(null)
  const [form, setForm] = useState(empty)
  const [editing, setEditing] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const [notice, setNotice] = useState(null)
  useEffect(() => {
    let active = true
    request('get', '/organizer/tax_information').then(response => {
      if (active) setData(response.data)
    }).catch(e => { if (active && e.name !== 'AbortError') setError('Could not load tax information. Reload settings to retry.') })
    return () => { active = false }
  }, [request])
  const set = field => event => setForm(current => ({ ...current, [field]: field === 'certified' ? event.target.checked : event.target.value }))
  const start = () => {
    setForm({ ...empty, ...data?.tax_information, tin: '', certified: false })
    setError(null); setNotice(null); setEditing(true)
  }
  const save = async event => {
    event.preventDefault()
    if (!/^[0-9]{9}$/.test(form.tin)) { setError('Enter exactly 9 digits for the TIN.'); return }
    setBusy(true); setError(null)
    try {
      const payload = Object.fromEntries(Object.keys(empty).map(key => [key, form[key]]))
      const response = await request('patch', '/organizer/tax_information', { tax_information: payload })
      setForm(empty); setData(response.data); setEditing(false)
      setNotice('Tax information saved. HåfaPass must review payout approval again.')
      onSaved?.()
    } catch (e) { if (e.name !== 'AbortError') setError(e.response?.data?.error || 'Could not save tax information. Please retry.') }
    finally { setBusy(false) }
  }
  const field = (name, label, options = {}) => <label className="block text-sm font-medium text-neutral-900">{label}<input className="input mt-1" value={form[name]} onChange={set(name)} maxLength={200} {...options} /></label>
  return <section aria-labelledby="tax-heading" className="rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6">
    <h2 id="tax-heading" className="text-lg font-semibold text-neutral-900">Tax information (W-9)</h2>
    <p className="mt-2 text-sm text-neutral-700">We need your tax information before paid payouts, for required tax reporting. Your TIN is encrypted and shown only by its last four digits. Never send it by email.</p>
    {error && <p role="alert" className="mt-4 text-sm text-red-800">{error}</p>}
    {notice && <p role="status" className="mt-4 text-sm text-emerald-800">{notice}</p>}
    {!data && !error && <p role="status" className="mt-4">Loading tax information…</p>}
    {data?.edit_locked && <p role="status" className="mt-4 text-sm text-amber-900">A check payout is in progress. Tax information can be changed after HåfaPass records it.</p>}
    {data && !editing && <div className="mt-4 space-y-3 text-sm">
      {data.tax_information ? <><p className="[overflow-wrap:anywhere]">{data.tax_information.legal_name} · {data.tax_information.masked_tin}</p><p>Certified by {data.tax_information.signer_name} on {new Date(data.tax_information.certified_at).toLocaleDateString()}</p></> : <p>Required before paid payouts. Free events do not need a W-9.</p>}
      <button type="button" className="btn-secondary" onClick={start} disabled={data.edit_locked}>{data.tax_information ? 'Change tax information' : 'Add tax information'}</button>
    </div>}
    {editing && <form onSubmit={save} className="mt-5 space-y-4">
      <fieldset disabled={busy || data?.edit_locked} className="space-y-4">
        <legend className="sr-only">Payee tax information</legend>
        {field('legal_name', 'Legal name', { required: true })}
        <p className="text-sm text-neutral-700">For a disregarded single-member LLC, use the owner’s legal name and tax classification; enter the LLC name as the business name.</p>
        {field('business_name', 'Business name if different (optional)')}
        <label className="block text-sm font-medium">Federal tax classification<select required className="input mt-1" value={form.tax_classification} onChange={set('tax_classification')}><option value="">Choose classification</option>{TAX_CLASSIFICATIONS.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
        <label className="block text-sm font-medium">TIN type<select className="input mt-1" value={form.tin_type} onChange={set('tin_type')}><option value="ein">EIN</option><option value="ssn">SSN</option></select></label>
        {field('tin', 'Taxpayer identification number (9 digits)', { type: 'password', inputMode: 'numeric', autoComplete: 'off', required: true, maxLength: 9, pattern: '[0-9]{9}', 'aria-describedby': 'tin-help' })}
        <p id="tin-help" className="text-sm text-neutral-700">Enter the full number again when changing this form. It will not be returned to this screen.</p>
        <label className="block text-sm font-medium">Tax mailing address<textarea required rows={3} maxLength={1000} className="input mt-1" value={form.mailing_address} onChange={set('mailing_address')} /></label>
        {mailingAddress && <button type="button" className="btn-secondary" onClick={() => setForm(current => ({ ...current, mailing_address: mailingAddress }))}>Use check mailing address</button>}
        {field('exempt_payee_code', 'Exempt-payee code (optional)', { maxLength: 2, inputMode: 'numeric' })}
        <div className="rounded-xl border border-neutral-300 p-4">
          <h3 className="font-semibold">Tax certification</h3>
          <p className="mt-2 text-sm">{data.certification}</p>
          <p className="mt-2 text-sm">If you cannot make this certification, including if backup withholding applies or you are not a U.S. person, contact HåfaPass for the appropriate form before proceeding.</p>
          <label className="mt-3 flex min-h-11 items-start gap-3 text-sm"><input type="checkbox" required checked={form.certified} onChange={set('certified')} className="mt-1 h-4 w-4 shrink-0" /><span>I confirm the tax certification above under penalties of perjury.</span></label>
          {field('signer_name', 'Signer’s typed name', { required: true })}
          <p className="mt-2 text-xs text-content-muted">Your typed name is your electronic signature. We record the date and time when you save.</p>
        </div>
        <div className="flex flex-wrap gap-3"><button className="btn-primary" type="submit">{busy ? 'Saving…' : 'Sign and save tax information'}</button><button className="btn-secondary" type="button" onClick={() => { setForm(empty); setEditing(false); setError(null) }}>Cancel</button></div>
      </fieldset>
    </form>}
  </section>
}
