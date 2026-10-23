import { CheckCircle2, Circle, ListChecks } from 'lucide-react'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import OrganizerAgreementDialog from '../../components/OrganizerAgreementDialog'
import SupportLink from '../../components/SupportLink'

const VERIFICATION = {
  unverified: { done: false, status: 'Not submitted yet', next: 'HåfaPass reviews your organization after you submit. We contact you if we need anything.' },
  pending: { done: false, status: 'Submitted — HåfaPass is reviewing it', next: 'Nothing to do right now. HåfaPass contacts you if anything is missing.' },
  verified: { done: true, status: 'Verified by HåfaPass' },
  rejected: { done: false, status: 'Changes needed', next: 'Read the review note, update your profile, then submit again.' },
  suspended: { done: false, status: 'Sales paused by HåfaPass' },
}

// The organizer's guided setup: one list, in order, with the next action
// and what HåfaPass does at each step. Only the owner can accept the
// agreement or submit for review; an admin viewing the workspace sees status.
export default function OrganizerSetupChecklist({ profile, canCreate, adminView = false, busy, agreementError = null, onOpenAgreement, onEditProfile, onAcceptPolicy, onSubmitVerification }) {
  const { t } = useTranslation()
  const [agreementOpen, setAgreementOpen] = useState(false)
  const progress = profile.setup_progress || {}
  const verification = VERIFICATION[profile.verification_status] || VERIFICATION.unverified
  const payoutMethod = progress.payout_method || profile.connected_account?.provider
  const hasDescription = Boolean(profile.business_description?.trim())

  const steps = [
    {
      key: 'profile', title: 'Organizer profile', done: hasDescription,
      status: hasDescription ? `${profile.business_name} — shown on your event pages` : 'Add a short description of who you are',
      action: !hasDescription && !adminView && <button type="button" onClick={onEditProfile} className="btn-secondary !px-4 !py-2 text-sm">Add description</button>,
    },
    {
      key: 'agreement', title: 'Organizer agreement', done: profile.policy_accepted,
      status: profile.policy_accepted ? 'Accepted' : profile.policy_accepted_at ? 'A new version needs your acceptance' : 'Not accepted yet',
      action: !profile.policy_accepted && !adminView && <button type="button" disabled={busy} onClick={() => { onOpenAgreement?.(); setAgreementOpen(true) }} className="btn-secondary !px-4 !py-2 text-sm">Review and accept</button>,
    },
    {
      key: 'verification', title: 'HåfaPass verifies your organization (tickets go on sale after this)', done: verification.done,
      status: verification.status, next: profile.verification_status === 'suspended' ? t('organizerVerification.suspendedChecklist') : verification.next,
      action: !adminView && (['unverified', 'rejected'].includes(profile.verification_status)
        ? <button type="button" disabled={busy || !hasDescription} onClick={onSubmitVerification} className="btn-secondary !px-4 !py-2 text-sm">{profile.verification_status === 'rejected' ? 'Submit again' : 'Submit for review'}</button>
        : profile.verification_status === 'suspended' ? <SupportLink subject={`Organizer review — ${profile.business_name}`} className="btn-secondary !px-4 !py-2 text-sm">Contact HåfaPass</SupportLink> : null),
      hint: !hasDescription && ['unverified', 'rejected'].includes(profile.verification_status) ? 'Add a profile description first.' : null,
    },
    {
      key: 'payout', title: 'How you get paid', done: profile.payout_ready,
      status: profile.payout_ready ? 'Approved' : payoutMethod ? `${payoutMethod === 'check' ? 'Check' : payoutMethod === 'manual' ? 'Bank transfer' : payoutMethod} saved — waiting for HåfaPass finance review` : 'Only needed for paid tickets. Free events can skip this.',
      next: payoutMethod && !profile.payout_ready ? 'HåfaPass finance confirms the details. Paid events can go live after that.' : null,
      action: !profile.payout_ready && <Link to="/dashboard/settings" className="btn-secondary !px-4 !py-2 text-sm">{payoutMethod ? 'View payout details' : 'Choose check or bank transfer'}</Link>,
    },
    {
      key: 'event', title: 'Create your first event', done: (progress.events_count || 0) > 0,
      status: (progress.events_count || 0) > 0 ? `${progress.events_count} event${progress.events_count === 1 ? '' : 's'} created` : 'Start a draft — nothing is public until you publish',
      action: !(progress.events_count > 0) && canCreate && <Link to="/dashboard/events/new" className="btn-primary !px-4 !py-2 text-sm">Start a draft</Link>,
    },
    {
      key: 'publish', title: 'Publish', done: (progress.published_events_count || 0) > 0,
      status: (progress.published_events_count || 0) > 0 ? profile.verification_status === 'verified' ? 'Live on HåfaPass' : t('organizerVerification.publishedInPreview') : 'Open your event and publish it when its checklist is complete',
      next: (progress.published_events_count || 0) > 0 ? null : 'HåfaPass may confirm launch details with you before the first sale.',
    },
  ]
  const nextIndex = steps.findIndex(step => !step.done)
  if (nextIndex === -1) return null
  const doneCount = steps.filter(step => step.done).length

  return (
    <section className="mb-8 rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6" aria-labelledby="organizer-setup-title">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h2 id="organizer-setup-title" className="flex items-center gap-2 text-lg font-semibold text-neutral-900"><ListChecks aria-hidden="true" className="h-5 w-5 text-brand-600" />Get ready to sell tickets</h2>
        <p className="text-sm font-medium text-content-muted">{doneCount} of {steps.length} done</p>
      </div>
      {profile.policy_version && !profile.policy_accepted && (
        <p role="status" data-testid="agreement-update-notice" className="mt-3 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
          The organizer agreement was updated to version {profile.current_policy_version}. Review what changed and accept it to keep publishing events.
        </p>
      )}
      {adminView && <p className="mt-2 text-sm text-amber-900">You’re viewing as a HåfaPass admin. Only the owner can accept the agreement or submit for review.</p>}
      <ol className="mt-4 space-y-2">
        {steps.map((step, index) => {
          const isNext = index === nextIndex
          return (
            <li key={step.key} aria-current={isNext ? 'step' : undefined} className={`rounded-xl border p-4 ${isNext ? 'border-brand-300 bg-brand-50/60' : 'border-neutral-200'}`}>
              <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div className="flex min-w-0 gap-3">
                  {step.done ? <CheckCircle2 aria-hidden="true" className="mt-0.5 h-5 w-5 shrink-0 text-emerald-600" /> : <Circle aria-hidden="true" className={`mt-0.5 h-5 w-5 shrink-0 ${isNext ? 'text-brand-600' : 'text-neutral-300'}`} />}
                  <div className="min-w-0">
                    <p className="font-medium text-neutral-900">{step.title}{isNext && <span className="ml-2 rounded-full bg-brand-600 px-2 py-0.5 text-xs font-semibold text-white">Next</span>}<span className="sr-only">{step.done ? ' (done)' : ''}</span></p>
                    <p className="text-sm text-neutral-700 [overflow-wrap:anywhere]">{step.status}</p>
                    {!step.done && step.next && <p className="mt-1 text-sm text-content-muted">{step.next}</p>}
                    {step.key === 'verification' && profile.verification_notes && !step.done && <p className="mt-2 rounded-lg bg-amber-50 p-3 text-sm text-amber-900">Review note: {profile.verification_notes}</p>}
                    {step.hint && <p className="mt-1 text-sm text-amber-900">{step.hint}</p>}
                  </div>
                </div>
                {!step.done && step.action && <div className="shrink-0 sm:pl-4">{step.action}</div>}
              </div>
            </li>
          )
        })}
      </ol>
      {agreementOpen && !profile.policy_accepted && <OrganizerAgreementDialog version={profile.current_policy_version}
        reaccept={Boolean(profile.policy_version)} busy={busy} error={agreementError}
        onClose={() => setAgreementOpen(false)}
        onAccept={async () => { if (await onAcceptPolicy()) setAgreementOpen(false) }} />}
    </section>
  )
}
