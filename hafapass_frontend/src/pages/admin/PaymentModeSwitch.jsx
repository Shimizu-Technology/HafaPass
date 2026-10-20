import { useId, useState } from 'react'
import { Link } from 'react-router-dom'
import { CheckCircle2, CircleAlert } from 'lucide-react'
import apiClient from '../../api/client'
import Dialog from '../../components/Dialog'

const MODES = {
  simulate: { label: 'Simulated payments', tone: 'bg-neutral-100 text-neutral-900 ring-neutral-300', body: 'Checkout runs end to end without contacting Stripe. No card is charged.' },
  test: { label: 'Test payments', tone: 'bg-amber-100 text-amber-950 ring-amber-300', body: 'Payments go to Stripe’s sandbox with test cards. No real money moves, and visitors see a “Test payments” banner.' },
  live: { label: 'Live payments', tone: 'bg-emerald-100 text-emerald-950 ring-emerald-300', body: 'Buyers’ cards are charged real money through Shimizu Technology’s Stripe account.' },
}

const TARGETS = {
  live: {
    action: 'Switch to live payments', title: 'Switch to live payments?', button: 'btn-primary', confirm: 'Yes, take real payments', done: 'Payments are now live. New checkouts charge real cards.',
    effects: [
      'From the next checkout, buyers’ cards are charged real money.',
      'Orders already paid in test mode stay test orders. Their refunds and fee lookups keep using the Stripe sandbox.',
      'Checkouts already in progress finish in the mode they started in.',
      'The “Test payments” banner disappears for visitors.',
    ],
  },
  test: {
    action: 'Switch to test mode', title: 'Switch to test payments?', button: 'btn-secondary', confirm: 'Switch to test mode', done: 'Payments are now in test mode. Cards are not charged.',
    effects: [
      'From the next checkout, payments go to the Stripe sandbox. No real card is charged.',
      'Orders already paid live stay live. Their refunds and fee lookups keep using live Stripe.',
      'Checkouts already in progress finish in the mode they started in.',
      'Visitors see a “Test payments” banner until you switch back.',
    ],
  },
}

function Checklist({ readiness }) {
  return (
    <ul className="mt-3 space-y-2 text-sm">
      {readiness.checks.map(check => (
        <li key={check.key} className="flex gap-2">
          {check.met
            ? <CheckCircle2 aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-emerald-700" />
            : <CircleAlert aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-amber-700" />}
          <span className="min-w-0">
            <span className="font-medium text-neutral-900">{check.label}</span>
            <span className="sr-only">{check.met ? ': done' : ': missing'}</span>
            {!check.met && check.help && <span className="block [overflow-wrap:anywhere] text-content-muted">{check.help}</span>}
          </span>
        </li>
      ))}
    </ul>
  )
}

export default function PaymentModeSwitch({ settings, beginRequest, onChanged }) {
  const titleId = useId()
  const [target, setTarget] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const current = settings.payment_mode
  const mode = MODES[current] || { label: current, tone: MODES.simulate.tone, body: '' }
  const readiness = settings.payment_mode_readiness || {}
  const counts = settings.payments_by_mode || {}
  const targets = ['live', 'test'].filter(name => name !== current && readiness[name])

  const close = () => { if (!busy) { setTarget(null); setError('') } }
  const switchMode = async () => {
    const request = beginRequest()
    if (!request) return
    setBusy(true)
    setError('')
    try {
      const response = await apiClient.patch('/admin/settings', { payment_mode: target }, request.config)
      if (!request.current()) return
      onChanged(response.data)
      setNotice(TARGETS[target].done)
      setTarget(null)
    } catch (failure) {
      if (request.handleError(failure) || !request.current()) return
      setError(failure.response?.data?.error || 'The payment mode did not change. Check your connection and try again.')
    } finally { request.release(); setBusy(false) }
  }

  return (
    <section aria-labelledby="payment-mode-title" className="card mt-8 p-5 sm:p-6">
      <h2 id="payment-mode-title" className="text-lg font-semibold text-neutral-900">Payment mode</h2>
      <div className="mt-3 flex flex-wrap items-center gap-3">
        <span className={`rounded-full px-4 py-1.5 text-base font-semibold ring-1 ${mode.tone}`}>{mode.label}</span>
        <span className="text-sm text-content-muted">Current mode</span>
      </div>
      <p className="mt-3 max-w-3xl text-sm text-neutral-700">{mode.body}</p>
      {(counts.test > 0 || counts.live > 0) && (
        <p className="mt-2 text-sm text-content-muted">Stripe payments so far: {counts.test || 0} test, {counts.live || 0} live. Each keeps the mode it was charged in.</p>
      )}
      {notice && <p role="status" className="mt-4 rounded-xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900">{notice}</p>}

      <div className="mt-5 grid gap-4 lg:grid-cols-2">
        {targets.map(name => {
          const ready = readiness[name].ready
          return (
            <div key={name} className="rounded-xl border border-neutral-200 bg-neutral-50 p-4">
              <h3 className="font-semibold text-neutral-900">{name === 'live' ? 'Ready for live payments?' : 'Ready for test payments?'}</h3>
              <p className="mt-1 text-sm text-content-muted">{ready ? 'Everything is in place.' : 'Finish the items marked below, then reload this page.'}</p>
              <Checklist readiness={readiness[name]} />
              <button type="button" disabled={!ready || busy} onClick={() => { setNotice(''); setTarget(name) }} className={`${TARGETS[name].button} mt-4`}>
                {TARGETS[name].action}
              </button>
            </div>
          )
        })}
      </div>
      <Link to="/admin/provider-readiness" className="mt-4 inline-flex min-h-11 items-center font-semibold text-brand-700 underline underline-offset-2 hover:text-brand-900">Review provider readiness</Link>

      {target && <Dialog labelledBy={titleId} busy={busy} onClose={close} className="max-w-lg">
        <h2 id={titleId} className="text-lg font-semibold text-neutral-900">{TARGETS[target].title}</h2>
        <ul className="mt-3 list-disc space-y-2 pl-5 text-sm text-neutral-700">
          {TARGETS[target].effects.map(effect => <li key={effect}>{effect}</li>)}
          <li>The change is recorded in the audit log under your name. You can switch back at any time.</li>
        </ul>
        {error && <p role="alert" className="mt-4 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">{error}</p>}
        <div className="mt-6 flex flex-wrap justify-end gap-3">
          <button type="button" disabled={busy} onClick={close} className="btn-secondary">Cancel</button>
          <button type="button" disabled={busy} onClick={switchMode} className={target === 'live' ? 'btn-danger' : 'btn-primary'}>{busy ? 'Switching…' : TARGETS[target].confirm}</button>
        </div>
      </Dialog>}
    </section>
  )
}
