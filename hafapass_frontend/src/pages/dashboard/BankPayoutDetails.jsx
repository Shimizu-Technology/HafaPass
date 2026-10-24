import { useState } from 'react'

const fromAccount = account => ({ bank_name: account?.payout_details?.bank_name || '', account_holder_name: account?.payout_details?.account_holder_name || '', account_number: '' })

export default function BankPayoutDetails({ account, busy, onSave }) {
  const [editing, setEditing] = useState(!account?.payout_details?.masked_account)
  const [details, setDetails] = useState(() => fromAccount(account))
  const [errors, setErrors] = useState({})
  const existingNumber = Boolean(account?.payout_details?.masked_account)
  const save = async event => {
    event.preventDefault()
    if (busy) return
    const found = {}
    if (!details.bank_name.trim()) found.bank_name = 'Enter your bank’s name.'
    if (!details.account_holder_name.trim()) found.account_holder_name = 'Enter the account holder’s name.'
    if (!existingNumber && !details.account_number.trim()) found.account_number = 'Enter the bank account number.'
    setErrors(found)
    if (Object.keys(found).length) return
    const saved = await onSave({ provider: 'manual', accountId: account?.id, payout_details: {
      bank_name: details.bank_name.trim(), account_holder_name: details.account_holder_name.trim(),
      ...(details.account_number.trim() ? { account_number: details.account_number.trim() } : {}),
    } })
    if (saved) { setDetails(value => ({ ...value, account_number: '' })); setEditing(false) }
  }
  if (!editing) return <div className="rounded-xl border border-neutral-200 p-4 text-sm">
    <dl className="space-y-2 [overflow-wrap:anywhere]">{[['Bank', account?.payout_details?.bank_name], ['Account holder', account?.payout_details?.account_holder_name], ['Account', account?.payout_details?.masked_account]].map(([label, value]) => <div key={label}><dt className="text-content-muted">{label}</dt><dd className="font-medium text-neutral-900">{value}</dd></div>)}</dl>
    <button type="button" disabled={busy} onClick={() => { setDetails(fromAccount(account)); setEditing(true) }} className="btn-secondary mt-4">Change bank details</button>
    <p className="mt-2 text-xs text-content-muted">Changing bank details needs a fresh HåfaPass review before the next payout.</p>
  </div>
  return <form onSubmit={save} noValidate className="space-y-4">
    <p className="text-sm text-neutral-700">Enter bank details here. Never email your account number or ID documents.</p>
    {[
      ['bank_name', 'Bank name', 200], ['account_holder_name', 'Account holder name', 200], ['account_number', existingNumber ? 'Account number (leave blank to keep the saved number)' : 'Account number', 100],
    ].map(([key, label, maxLength]) => <div key={key}><label className="block text-sm font-medium text-neutral-900">{label}<input type={key === 'account_number' ? 'password' : 'text'} autoComplete="off" spellCheck={false} disabled={busy} value={details[key]} onChange={event => setDetails(value => ({ ...value, [key]: event.target.value }))} maxLength={maxLength} aria-invalid={!!errors[key]} aria-describedby={errors[key] ? `bank-${key}-error` : undefined} className="input mt-1" /></label>{errors[key] && <p id={`bank-${key}-error`} className="mt-1 text-sm text-red-700">{errors[key]}</p>}</div>)}
    {existingNumber && <p className="text-sm text-content-muted">Saved account: {account.payout_details.masked_account}</p>}
    <div className="flex flex-wrap gap-3"><button type="submit" disabled={busy} className="btn-primary">{busy ? 'Saving…' : 'Save bank details'}</button>{existingNumber && <button type="button" disabled={busy} onClick={() => { setDetails(fromAccount(account)); setErrors({}); setEditing(false) }} className="btn-secondary">Cancel</button>}</div>
  </form>
}
