import { useEffect, useId, useState } from 'react'
import { Link } from 'react-router-dom'
import { useAuth } from '@clerk/clerk-react'
import {
  ArrowRight, BarChart3, Banknote, CalendarPlus, Check, CheckCircle2, ChevronDown, ClipboardList, Download,
  FileText, Hourglass, Layers, Mail, ScanLine, Share2, Tag, Users, WifiOff,
} from 'lucide-react'
import apiClient from '../api/client'
import SEO from '../components/SEO'
import { PUBLIC_WEB_URL } from '../utils/site'
import { supportMailto } from '../utils/supportContact'
import {
  calculateHostPayout, describeFee, formatSignedMoney, hostCtaTargets, MAX_QUANTITY, parseHostPricing, parsePriceInput, parseQuantityInput,
} from '../utils/hostPricing'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY
const steps = [
  { icon: CalendarPlus, title: 'Create your event', body: 'Add your date, venue, artwork and ticket types. Save a draft and publish when it’s ready.' },
  { icon: Share2, title: 'Sell and share', body: 'Share your event link. Buyers pay by card and get tickets on their phone, ready for the door.' },
  { icon: ScanLine, title: 'Scan at the door and get paid', body: 'Your team checks guests in from their phones. After the event, review your settlement and get paid.' },
]

const featureGroups = [
  {
    title: 'Sell more tickets',
    features: [
      { icon: Layers, title: 'Ticket types and price tiers', body: 'General, VIP or table tickets, with early-bird prices that change on schedule.' },
      { icon: Tag, title: 'Promo codes', body: 'Percent or dollar discounts with usage limits for partners, sponsors and regulars.' },
      { icon: Hourglass, title: 'Waitlist', body: 'When you sell out, interested buyers join a waitlist and hear first if tickets open up.' },
      { icon: ClipboardList, title: 'Guest list', body: 'Add comps, performers and VIPs so they’re checked in like everyone else.' },
    ],
  },
  {
    title: 'Run the door',
    features: [
      { icon: ScanLine, title: 'Door scanner on any phone', body: 'Scan tickets in the phone’s browser, with no app to install. Keeps scanning if the Wi‑Fi drops and syncs when it’s back.' },
      { icon: Banknote, title: 'Cash box office', body: 'Sell tickets at the door for cash and keep them in the same count as online sales.' },
      { icon: Users, title: 'Team roles', body: 'Invite managers, finance, marketing, box office and door staff with only the access they need.' },
    ],
  },
  {
    title: 'Know your numbers',
    features: [
      { icon: BarChart3, title: 'Sales analytics', body: 'See tickets sold, revenue and check-ins for each event as they happen.' },
      { icon: Download, title: 'Attendee CSV', body: 'Download your attendee list as a spreadsheet whenever you need it.' },
      { icon: FileText, title: 'Settlement statements and payouts', body: 'A clear statement of sales, fees and refunds for every event, then your payout.' },
    ],
  },
]

function usePublicConfig() {
  const [state, setState] = useState({ status: 'loading', config: null })
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    let current = true
    setState({ status: 'loading', config: null })
    apiClient.get('/config')
      .then(response => { if (current) setState({ status: 'loaded', config: response.data }) })
      .catch(() => { if (current) setState({ status: 'failed', config: null }) })
    return () => { current = false }
  }, [attempt])
  return { ...state, retry: () => setAttempt(value => value + 1) }
}

function CtaGroup({ targets, tone = 'light', align = 'start' }) {
  const signInClass = tone === 'dark'
    ? 'font-semibold text-white underline underline-offset-4 hover:text-brand-200'
    : 'font-semibold text-brand-800 underline underline-offset-4 hover:text-brand-900'
  return (
    <div className={`flex flex-col gap-3 ${align === 'center' ? 'items-center text-center' : 'items-start'}`}>
      <Link to={targets.primary} className="btn-primary gap-2 text-base">
        {targets.signedIn ? 'Go to your dashboard' : 'Start hosting'} <ArrowRight aria-hidden="true" className="h-4 w-4" />
      </Link>
      {targets.signIn && (
        <p className={`text-sm ${tone === 'dark' ? 'text-content-inverse-muted' : 'text-content-muted'}`}>
          Already have an account? <Link to={targets.signIn} className={`rounded focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2 ${signInClass}`}>Sign in</Link>
        </p>
      )}
    </div>
  )
}

// Illustrative only: shows what the door looks like without implying real sales.
function DoorPreview() {
  return (
    <div aria-hidden="true" className="relative mx-auto w-full max-w-sm select-none lg:max-w-none">
      <div className="host-preview-back absolute -right-2 -top-4 z-10 hidden w-56 rounded-2xl border border-neutral-200 bg-white p-4 shadow-card sm:block lg:-right-4">
        <p className="text-xs font-semibold text-content-muted">Checked in</p>
        <p className="mt-1 font-display text-2xl font-bold text-neutral-950">186 <span className="text-base font-medium text-content-muted">of 240</span></p>
        <div className="mt-3 h-2 overflow-hidden rounded-full bg-neutral-100"><div className="h-full w-[78%] rounded-full bg-brand-500" /></div>
        <p className="mt-3 flex items-center gap-1.5 text-xs text-content-muted"><WifiOff className="h-3.5 w-3.5" /> Offline scans sync later</p>
      </div>
      <div className="host-preview-front relative mr-auto w-full max-w-[18rem] rounded-[1.75rem] border border-neutral-200 bg-white p-3 shadow-card sm:ml-4">
        <div className="rounded-[1.25rem] bg-brand-950 px-5 pb-6 pt-5 text-white">
          <p className="text-xs font-semibold uppercase tracking-wider text-brand-200">Door scanner</p>
          <div className="mt-6 flex flex-col items-center text-center">
            <span className="host-preview-check flex h-16 w-16 items-center justify-center rounded-full bg-brand-500/20">
              <CheckCircle2 className="h-9 w-9 text-brand-300" />
            </span>
            <p className="mt-4 font-display text-2xl font-bold">Admitted</p>
            <p className="mt-1 text-sm text-content-inverse-muted">General Admission · 1 ticket</p>
          </div>
        </div>
        <div className="flex items-center justify-between px-3 pb-1 pt-3 text-xs text-content-muted">
          <span>Example event</span><span className="font-semibold text-brand-800">Next guest</span>
        </div>
      </div>
    </div>
  )
}

function ResultRow({ label, value, strong = false }) {
  return (
    <div className="flex items-baseline justify-between gap-3 py-2">
      <dt className={`text-sm ${strong ? 'font-semibold text-neutral-900' : 'text-content-muted'}`}>{label}</dt>
      <dd className={`tabular-nums ${strong ? 'font-display text-xl font-bold text-neutral-950' : 'font-medium text-neutral-900'}`}>{value}</dd>
    </div>
  )
}

function FeeCalculator({ pricing }) {
  const id = useId()
  const [priceInput, setPriceInput] = useState('25')
  const [quantityInput, setQuantityInput] = useState('1')
  const priceCents = parsePriceInput(priceInput)
  const quantity = parseQuantityInput(quantityInput)
  const priceError = priceInput.trim() && priceCents === null ? 'Enter a ticket price like 25 or 12.50, up to $10,000.' : null
  const quantityError = quantityInput.trim() && quantity === null ? `Enter a whole number from 1 to ${MAX_QUANTITY.toLocaleString('en-US')}.` : null
  const ready = priceCents !== null && quantity !== null
  const result = ready ? calculateHostPayout({ priceCents, quantity, pricing }) : null
  const money = cents => (result ? formatSignedMoney(cents) : '—')
  const ticketsLabel = quantity && quantity !== 1 ? `${quantity.toLocaleString('en-US')} tickets` : '1 ticket'
  const absorbsMoreThanPrice = result && result.organizerAbsorbs.organizerReceivesCents < 0

  return (
    <div className="card p-5 sm:p-6">
      <h3 className="font-display text-xl font-bold text-neutral-950">Fee calculator</h3>
      <p className="mt-1 text-sm text-content-muted">Try a ticket price to see what buyers pay and what you receive.</p>
      <div className="mt-5 grid grid-cols-[minmax(0,1fr)_7rem] gap-3">
        <div>
          <label htmlFor={`${id}-price`} className="mb-1.5 block text-sm font-medium text-neutral-800">Ticket price</label>
          <div className="relative">
            <span aria-hidden="true" className="pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 text-neutral-500">$</span>
            <input id={`${id}-price`} type="text" inputMode="decimal" autoComplete="off" enterKeyHint="done" value={priceInput}
              onChange={event => setPriceInput(event.target.value)} placeholder="25.00"
              aria-invalid={priceError ? true : undefined} aria-describedby={priceError ? `${id}-price-error` : undefined}
              className={`input !pl-8 text-base tabular-nums ${priceError ? 'input-error' : ''}`} />
          </div>
        </div>
        <div>
          <label htmlFor={`${id}-quantity`} className="mb-1.5 block text-sm font-medium text-neutral-800">Tickets</label>
          <input id={`${id}-quantity`} type="text" inputMode="numeric" pattern="[0-9]*" autoComplete="off" enterKeyHint="done" value={quantityInput}
            onChange={event => setQuantityInput(event.target.value)}
            aria-invalid={quantityError ? true : undefined} aria-describedby={quantityError ? `${id}-quantity-error` : undefined}
            className={`input text-base tabular-nums ${quantityError ? 'input-error' : ''}`} />
        </div>
      </div>
      {priceError && <p id={`${id}-price-error`} className="mt-2 text-sm text-red-700">{priceError}</p>}
      {quantityError && <p id={`${id}-quantity-error`} className="mt-2 text-sm text-red-700">{quantityError}</p>}

      <div aria-live="polite" className="mt-5">
        {result && result.subtotalCents === 0 && (
          <p className="mb-3 flex items-start gap-2 rounded-xl bg-brand-50 px-4 py-3 text-sm text-brand-900"><Check aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" />Free tickets have no HåfaPass fee.</p>
        )}
        <div className="grid gap-3 sm:grid-cols-2">
          <section aria-labelledby={`${id}-pass`} className="rounded-xl border border-neutral-200 bg-white px-4 py-3">
            <h4 id={`${id}-pass`} className="text-sm font-semibold text-brand-800">Buyer pays the fee</h4>
            <dl className="mt-1 divide-y divide-neutral-100">
              <ResultRow label={`Buyer pays for ${ticketsLabel}`} value={money(result?.buyerPays.buyerTotalCents)} />
              <ResultRow label="HåfaPass fee" value={money(result?.feeCents)} />
              <ResultRow label="You receive" value={money(result?.buyerPays.organizerReceivesCents)} strong />
            </dl>
          </section>
          <section aria-labelledby={`${id}-absorb`} className="rounded-xl border border-neutral-200 bg-white px-4 py-3">
            <h4 id={`${id}-absorb`} className="text-sm font-semibold text-brand-800">You absorb the fee</h4>
            <dl className="mt-1 divide-y divide-neutral-100">
              <ResultRow label={`Buyer pays for ${ticketsLabel}`} value={money(result?.organizerAbsorbs.buyerTotalCents)} />
              <ResultRow label="HåfaPass fee" value={money(result?.feeCents)} />
              <ResultRow label="You receive" value={money(result?.organizerAbsorbs.organizerReceivesCents)} strong />
            </dl>
          </section>
        </div>
        {absorbsMoreThanPrice && (
          <p className="mt-3 text-sm text-content-muted">At this price the fee is more than the ticket. Let buyers pay the fee or raise the price.</p>
        )}
        {!ready && !priceError && !quantityError && <p className="mt-3 text-sm text-content-muted">Enter a ticket price and number of tickets to see the totals.</p>}
      </div>
      <p className="mt-4 text-xs leading-relaxed text-content-muted">
        Estimate for one order, before promo codes and refunds.
        {pricing.processingIncluded === true && ' Card processing is included in the HåfaPass fee.'}
        {pricing.processingIncluded === false && ' Card processing is charged separately from the HåfaPass fee.'}
        {' '}Your dashboard shows the exact amounts for every sale.
      </p>
    </div>
  )
}

function PricingSection({ configState }) {
  const pricing = configState.status === 'loaded' ? parseHostPricing(configState.config) : null
  const points = [
    'Free tickets are always free',
    'No setup or monthly fees',
    ...(pricing?.processingIncluded ? ['Card processing included'] : []),
    'Choose whether buyers pay the fee or you absorb it',
    ...(pricing?.payoutScheduleText ? [`Payouts ${pricing.payoutScheduleText}`] : []),
  ]

  return (
    <section id="pricing" aria-labelledby="pricing-heading" className="scroll-mt-20 border-y border-neutral-200 bg-white py-14 sm:py-20">
      <div className="mx-auto grid max-w-6xl gap-10 px-4 sm:px-6 lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)] lg:gap-14 lg:px-8">
        <div>
          <p className="text-sm font-semibold text-brand-800">Pricing</p>
          <h2 id="pricing-heading" className="mt-2 font-display text-3xl font-bold tracking-tight text-neutral-950 sm:text-4xl">Simple pricing. You only pay when you sell.</h2>
          {configState.status === 'loading' && (
            <div role="status" aria-label="Loading pricing" className="mt-6 h-9 w-64 max-w-full animate-pulse rounded-lg bg-neutral-100" />
          )}
          {pricing && (
            <p className="mt-6 font-display text-2xl font-bold text-neutral-950 sm:text-3xl" data-testid="host-fee-summary">{describeFee(pricing)}</p>
          )}
          {configState.status !== 'loading' && !pricing && (
            <div role="status" className="mt-6 rounded-xl border border-neutral-200 bg-stone-50 p-4">
              <p className="font-semibold text-neutral-900">Current rates aren’t available right now</p>
              <p className="mt-1 text-sm text-content-muted">Paid tickets carry a per-ticket HåfaPass fee, which buyers see before they pay. Try again in a moment, or email us for the current rate.</p>
              <div className="mt-3 flex flex-wrap gap-x-5 gap-y-1">
                <button type="button" onClick={configState.retry} className="inline-flex min-h-11 items-center text-sm font-semibold text-brand-800 underline underline-offset-4">Try again</button>
                <a href={supportMailto('HåfaPass pricing')} className="inline-flex min-h-11 items-center text-sm font-semibold text-brand-800 underline underline-offset-4">Email us</a>
              </div>
            </div>
          )}
          <ul className="mt-6 space-y-3">
            {points.map(point => (
              <li key={point} className="flex items-start gap-3 text-neutral-800">
                <span className="mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-brand-50"><Check aria-hidden="true" className="h-3.5 w-3.5 text-brand-700" /></span>
                <span>{point}</span>
              </li>
            ))}
          </ul>
        </div>
        <div className="min-w-0">
          {pricing ? <FeeCalculator pricing={pricing} /> : configState.status === 'loading'
            ? <div aria-hidden="true" className="card h-80 animate-pulse bg-neutral-50" />
            : null}
        </div>
      </div>
    </section>
  )
}

function faqItems(pricing) {
  const feeAnswer = pricing
    ? `HåfaPass charges ${describeFee(pricing)}${pricing.processingIncluded ? ', with card processing included' : ''}. There are no setup or monthly fees, and free tickets are free.`
    : 'Paid tickets carry a per-ticket HåfaPass fee. There are no setup or monthly fees, and free tickets are free. Buyers always see the full total before they pay.'
  const payoutAnswer = pricing?.payoutScheduleText
    ? `Payouts are sent ${pricing.payoutScheduleText}. Your dashboard shows a settlement statement for each event with sales, fees and refunds, so you can see exactly what you’re owed.`
    : 'After your event, your dashboard shows a settlement statement with sales, fees and refunds. Your payout is based on that statement, and you can follow its status from the dashboard.'
  return [
    { q: 'How much does HåfaPass cost?', a: feeAnswer },
    { q: 'Who pays the fee, me or my buyers?', a: 'You decide for each event. Buyers can pay the fee at checkout, you can absorb it so buyers pay exactly your ticket price, or you can split it. You can change it in your event’s sales settings.' },
    { q: 'Can I host a free event?', a: 'Yes. Free tickets have no HåfaPass fee, and you still get the guest list, door scanner, waitlist and attendee export.' },
    { q: 'When do I get paid?', a: payoutAnswer },
    { q: 'How do refunds work?', a: <>You set the refund rules for your event and handle refund requests from your dashboard. Refunds go back to the buyer’s original payment method and come out of your event’s sales. See the <Link to="/policies/refunds" className="font-semibold text-brand-800 underline underline-offset-4">Refund &amp; Cancellation Policy</Link>.</> },
    { q: 'Does my door staff need an app?', a: 'No. Staff open the scanner in their phone’s browser and scan tickets with the camera. If the venue Wi‑Fi drops, scanning keeps working and syncs when the connection is back.' },
    { q: 'How do I get help?', a: <>Email the HåfaPass team at any point, from setting up your first event to closing out after it. <a href={supportMailto('Hosting on HåfaPass')} className="font-semibold text-brand-800 underline underline-offset-4">Contact support</a>.</> },
  ]
}

function HostContent({ targets }) {
  const configState = usePublicConfig()
  const pricing = configState.status === 'loaded' ? parseHostPricing(configState.config) : null

  return (
    <div className="bg-stone-50 text-content">
      <SEO
        title="Host your event"
        description="Sell tickets for your Guam event with HåfaPass. Ticket tiers, promo codes, a door scanner on any phone, cash box office and clear payouts. No setup fees."
        url={`${PUBLIC_WEB_URL}/host`}
        image={`${PUBLIC_WEB_URL}/og-host.jpg`}
      />

      <section className="overflow-hidden py-12 sm:py-16 lg:py-20">
        <div className="mx-auto grid max-w-6xl items-center gap-12 px-4 sm:px-6 lg:grid-cols-[minmax(0,7fr)_minmax(0,5fr)] lg:px-8">
          <div className="max-w-2xl">
            <p className="text-sm font-semibold text-brand-800">For event organizers on Guam</p>
            <h1 className="mt-3 font-display text-4xl font-bold leading-[1.08] tracking-tight text-neutral-950 sm:text-5xl lg:text-[3.5rem]">Host your event with HåfaPass</h1>
            <p className="mt-5 max-w-xl text-lg leading-relaxed text-content-muted">Sell tickets online, check guests in from any phone and get paid after your event. No setup fees, and free events stay free.</p>
            <div className="mt-8"><CtaGroup targets={targets} /></div>
            <a href="#pricing" className="mt-4 inline-flex min-h-11 items-center gap-1.5 rounded text-sm font-semibold text-neutral-700 hover:text-neutral-950 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2">
              See pricing <ChevronDown aria-hidden="true" className="h-4 w-4" />
            </a>
          </div>
          <DoorPreview />
        </div>
      </section>

      <section aria-labelledby="how-heading" className="border-t border-neutral-200 py-14 sm:py-20">
        <div className="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8">
          <h2 id="how-heading" className="font-display text-3xl font-bold tracking-tight text-neutral-950 sm:text-4xl">How it works</h2>
          <ol className="mt-10 grid gap-8 md:grid-cols-3 md:gap-6">
            {steps.map(({ icon: Icon, title, body }, index) => (
              <li key={title} className="relative">
                <div className="flex items-center gap-3">
                  <span className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-brand-700 text-white"><Icon aria-hidden="true" className="h-5 w-5" /></span>
                  <span className="font-display text-sm font-semibold text-content-muted">Step {index + 1}</span>
                </div>
                <h3 className="mt-4 text-xl font-semibold text-neutral-950">{title}</h3>
                <p className="mt-2 leading-relaxed text-content-muted">{body}</p>
              </li>
            ))}
          </ol>
        </div>
      </section>

      <section aria-labelledby="features-heading" className="border-t border-neutral-200 py-14 sm:py-20">
        <div className="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8">
          <h2 id="features-heading" className="max-w-2xl font-display text-3xl font-bold tracking-tight text-neutral-950 sm:text-4xl">Everything you need from first ticket to final payout</h2>
          <div className="mt-10 grid gap-10 lg:grid-cols-3 lg:gap-8">
            {featureGroups.map(group => (
              <div key={group.title}>
                <h3 className="border-b border-neutral-200 pb-3 text-sm font-semibold uppercase tracking-wider text-brand-800">{group.title}</h3>
                <ul className="mt-2 divide-y divide-neutral-200">
                  {group.features.map(({ icon: Icon, title, body }) => (
                    <li key={title} className="flex gap-4 py-4">
                      <Icon aria-hidden="true" className="mt-0.5 h-5 w-5 shrink-0 text-brand-700" />
                      <div><p className="font-semibold text-neutral-950">{title}</p><p className="mt-1 text-sm leading-relaxed text-content-muted">{body}</p></div>
                    </li>
                  ))}
                </ul>
              </div>
            ))}
          </div>
        </div>
      </section>

      <PricingSection configState={configState} />

      <section aria-labelledby="faq-heading" className="py-14 sm:py-20">
        <div className="mx-auto max-w-3xl px-4 sm:px-6 lg:px-8">
          <h2 id="faq-heading" className="font-display text-3xl font-bold tracking-tight text-neutral-950 sm:text-4xl">Questions organizers ask</h2>
          <div className="mt-8 divide-y divide-neutral-200 border-y border-neutral-200">
            {faqItems(pricing).map(({ q, a }) => (
              <details key={q} className="host-faq group">
                <summary className="flex min-h-14 cursor-pointer list-none items-center justify-between gap-4 rounded py-4 text-left font-semibold text-neutral-950 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus [&::-webkit-details-marker]:hidden">
                  {q}
                  <ChevronDown aria-hidden="true" className="h-5 w-5 shrink-0 text-content-muted transition-transform duration-200 ease-out-strong group-open:rotate-180" />
                </summary>
                <div className="host-faq-answer pb-5 pr-9 leading-relaxed text-content-muted">{a}</div>
              </details>
            ))}
          </div>
          <p className="mt-6 flex items-center gap-2 text-sm text-content-muted"><Mail aria-hidden="true" className="h-4 w-4" />Something else? <a href={supportMailto('Hosting on HåfaPass')} className="font-semibold text-brand-800 underline underline-offset-4">Ask us</a></p>
        </div>
      </section>

      <section aria-labelledby="final-cta-heading" className="bg-brand-950 py-14 text-white sm:py-20">
        <div className="mx-auto flex max-w-3xl flex-col items-center px-4 text-center sm:px-6 lg:px-8">
          <h2 id="final-cta-heading" className="font-display text-3xl font-bold tracking-tight sm:text-4xl">Ready to sell your first ticket?</h2>
          <p className="mt-4 max-w-xl text-content-inverse-muted">Create your organizer profile in a minute, then set up your event at your own pace.</p>
          <div className="mt-8"><CtaGroup targets={targets} tone="dark" align="center" /></div>
        </div>
      </section>
    </div>
  )
}

function ClerkHostPage() {
  const { isLoaded, isSignedIn } = useAuth()
  return <HostContent targets={hostCtaTargets({ clerkEnabled: true, isLoaded, isSignedIn })} />
}

export default function HostPage() {
  return clerkPubKey ? <ClerkHostPage /> : <HostContent targets={hostCtaTargets({ clerkEnabled: false })} />
}
