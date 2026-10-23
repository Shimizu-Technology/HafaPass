import { useId } from 'react'
import { Link } from 'react-router-dom'
import Dialog from './Dialog'

// Accepting the organizer agreement is a contract step, so it gets a real
// dialog: what changed, a link to the full text, and one clear accept button.
export default function OrganizerAgreementDialog({ version, reaccept = false, busy = false, error = null, onAccept, onClose }) {
  const titleId = useId()
  return (
    <Dialog labelledBy={titleId} busy={busy} onClose={onClose} className="max-w-lg">
      <h2 id={titleId} className="text-lg font-semibold text-neutral-900">
        {reaccept ? 'Review the updated organizer agreement' : 'Accept the organizer agreement'}
      </h2>
      <p className="mt-1 text-sm text-neutral-500">Version {version}</p>
      {reaccept && <p className="mt-3 text-sm text-neutral-700">The agreement changed since you last accepted it. You need to accept this version before publishing events.</p>}
      <p className="mt-3 text-sm font-medium text-neutral-900">Key points</p>
      <ul className="mt-1 list-disc space-y-1.5 pl-5 text-sm text-neutral-700">
        <li>Buyers see all-in ticket prices, including the service fee they pay, from the first price they see.</li>
        <li>You are named as the seller of your tickets. HåfaPass, operated by Shimizu Technology, sells them as your limited agent and collects the service fee.</li>
        <li>The agreement states the current fees, your fee options (buyers pay, you absorb, or split) and payout timing. Payouts are made by check from Shimizu Technology’s business account unless another payout method has been approved.</li>
        <li>It also covers refunds, chargebacks, event cancellations and your responsibilities for the event.</li>
      </ul>
      <p className="mt-3 text-sm">
        <Link to="/policies/organizer-agreement" target="_blank" rel="noopener" className="inline-flex min-h-11 items-center font-semibold text-brand-700 underline underline-offset-2">Read the full organizer agreement</Link>
      </p>
      {error && <p role="alert" className="mt-2 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-800">{error}</p>}
      <div className="mt-5 flex flex-wrap justify-end gap-3">
        <button type="button" disabled={busy} onClick={onClose} className="btn-secondary">Not now</button>
        <button type="button" disabled={busy} onClick={onAccept} className="btn-primary">{busy ? 'Accepting…' : `Accept version ${version}`}</button>
      </div>
    </Dialog>
  )
}
