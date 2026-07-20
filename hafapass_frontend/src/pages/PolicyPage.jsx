import { Link, Navigate, useParams } from 'react-router-dom'
import SEO from '../components/SEO'

const policies = {
  'buyer-terms': {
    title: 'Buyer Terms',
    summary: 'The rules for purchasing, receiving, using, transferring, and requesting help with HafaPass tickets.',
    sections: [
      ['Your purchase', 'Event details, prices, fees, refund eligibility, and the organizer identity are shown before checkout. A ticket is issued only after payment is confirmed or a free/approved order is completed.'],
      ['Ticket use', 'Keep ticket links and entry codes private. A ticket may be refused when it is cancelled, refunded, transferred, disputed, already used, or otherwise invalid.'],
      ['Event responsibility', 'The event organizer is responsible for event content, venue access, schedules, age rules, and delivery of the event. HafaPass operates the ticketing platform and support tools.'],
      ['Changes and disputes', 'Cancellation, postponement, reschedule, and refund rights follow the disclosed event policy and applicable law. Contact support promptly when an order or charge is incorrect.'],
    ],
  },
  'organizer-agreement': {
    title: 'Organizer Agreement',
    summary: 'The operating responsibilities an organizer must accept before publishing on HafaPass.',
    sections: [
      ['Accurate listings', 'Organizers must publish accurate dates, Guam time, venue, accessibility, age, inventory, pricing, fee, and refund information and must have authority to operate the event.'],
      ['Buyer obligations', 'Organizers must honor valid tickets, cooperate with support, communicate material changes, and fund refunds, disputes, taxes, reserves, and negative balances according to approved terms.'],
      ['Operations and safety', 'Organizers remain responsible for permits, staffing, security, accessibility, emergency planning, venue rules, and legal compliance.'],
      ['Platform controls', 'HafaPass may pause sales, hold payouts, preserve records, investigate risk, or remove prohibited events where needed to protect buyers or the platform.'],
    ],
  },
  privacy: {
    title: 'Privacy Policy',
    summary: 'What HafaPass collects, why it is used, and the controls around personal information.',
    sections: [
      ['Information collected', 'Account identifiers, contact details, order and ticket records, event interactions, support history, device/security signals, and provider references are collected as needed to operate the service. Card details remain with approved payment providers.'],
      ['Use and sharing', 'Information is used for checkout, fulfillment, admission, fraud prevention, support, accounting, legal compliance, and privacy-safe analytics. It is shared only with relevant organizers and contracted providers for those purposes.'],
      ['Security and choices', 'Access is role-limited and sensitive actions are audited. Buyers may request access, correction, export, or deletion where retention duties do not require preservation.'],
      ['Contact', 'Privacy requests and suspected misuse should be sent to privacy@hafapass.com. Production launch remains gated on professional Guam and US privacy review.'],
    ],
  },
  refunds: {
    title: 'Refund & Cancellation Policy',
    summary: 'How event changes, ticket cancellations, refunds, fees, and timing are handled.',
    sections: [
      ['Before purchase', 'Each event must disclose its refund rules. HafaPass shows totals and fees before payment and records the version accepted at checkout.'],
      ['Event cancellation or change', 'Cancelled events require an organizer-approved refund workflow. Postponed or materially rescheduled events provide an accept-or-request-refund path when eligible.'],
      ['Ticket-level requests', 'Unused active tickets may be cancelled or refunded only when the event policy and platform controls allow it. Used, transferred, disputed, or already-refunded value cannot be refunded twice.'],
      ['Timing', 'Approved refunds return through the original supported payment path. Provider and bank processing time may apply, and unknown provider results must be reconciled before another refund is attempted.'],
    ],
  },
  'acceptable-use': {
    title: 'Acceptable Use Policy',
    summary: 'Events and behavior that are not allowed on HafaPass.',
    sections: [
      ['Prohibited activity', 'No unlawful, deceptive, unsafe, hateful, exploitative, infringing, sanctions-evading, or unauthorized events, sales, content, or account access.'],
      ['Ticket integrity', 'No speculative inventory, credential harvesting, automated abuse, duplicate admission, payment manipulation, or attempts to bypass holds, limits, refunds, or access controls.'],
      ['Enforcement', 'HafaPass may investigate, preserve evidence, restrict access, pause sales or payouts, cancel invalid credentials, and cooperate with affected parties and authorities as legally appropriate.'],
    ],
  },
  retention: {
    title: 'Data Retention Schedule',
    summary: 'The pilot retention baseline for operational, financial, security, and support records.',
    sections: [
      ['Financial and audit records', 'Orders, payments, refunds, settlements, payouts, disputes, admissions, and append-only audit evidence are retained for the legally and contractually approved accounting and dispute period.'],
      ['Operational data', 'Provider events, delivery history, support notes, and security evidence are retained only as long as needed for delivery, incident response, disputes, and abuse prevention.'],
      ['Device data', 'Offline scanner manifests and queues must be removed from devices after event closeout and the approved dispute window. Lost devices must be revoked immediately.'],
      ['Deletion and holds', 'Deletion requests are honored where possible. Legal holds, active disputes, fraud investigations, and statutory duties may pause deletion for specifically required records.'],
    ],
  },
}

export default function PolicyPage() {
  const { policy } = useParams()
  const content = policies[policy]
  if (!content) return <Navigate to="/policies/buyer-terms" replace />

  return (
    <main className="min-h-screen bg-neutral-50 px-4 py-12">
      <SEO title={`${content.title} — HafaPass`} description={content.summary} />
      <article className="mx-auto max-w-3xl rounded-2xl border border-neutral-200 bg-white p-6 shadow-sm sm:p-10">
        <p className="text-xs font-semibold uppercase tracking-[0.18em] text-brand-800">Pilot policy · version 2026-07-pilot-draft</p>
        <h1 className="mt-3 text-3xl font-bold tracking-tight text-neutral-950">{content.title}</h1>
        <p className="mt-4 text-base leading-7 text-neutral-600">{content.summary}</p>
        <div className="mt-5 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900" role="note">
          This is an engineering-ready pilot draft, not a representation of completed legal approval. Production sales remain blocked until Guam/US counsel, privacy, accounting, and payment-provider reviewers approve and date the governing documents.
        </div>
        <div className="mt-8 space-y-7">
          {content.sections.map(([heading, body]) => (
            <section key={heading}>
              <h2 className="text-lg font-semibold text-neutral-900">{heading}</h2>
              <p className="mt-2 leading-7 text-neutral-600">{body}</p>
            </section>
          ))}
        </div>
        <p className="mt-10 border-t border-neutral-200 pt-6 text-sm text-neutral-700">
          See also <Link className="text-brand-800 underline" to="/policies/privacy">Privacy</Link>,{' '}
          <Link className="text-brand-800 underline" to="/policies/refunds">Refunds</Link>, and{' '}
          <Link className="text-brand-800 underline" to="/policies/acceptable-use">Acceptable Use</Link>.
        </p>
      </article>
    </main>
  )
}
