import { useTranslation } from 'react-i18next'
import { useEffect, useId, useState } from 'react'
import { Link } from 'react-router-dom'
import { useAuth } from '@clerk/clerk-react'
import { ArrowRight, Banknote, Check, CheckCircle2, ChevronDown, Mail, ScanLine, Users, WifiOff } from 'lucide-react'
import GuamPhoto from '../components/GuamPhoto'
import apiClient from '../api/client'
import SEO from '../components/SEO'
import { activeIntlLocale } from '../utils/locale'
import { formatMoneyCents } from '../utils/money'
import { PUBLIC_WEB_URL } from '../utils/site'
import SupportLink from '../components/SupportLink'
import { useSupportContact } from '../utils/supportContact'
import {
  calculateHostPayout, formatPercent, hostCtaTargets, MAX_QUANTITY, parseHostPricing, parsePriceInput, parseQuantityInput,
} from '../utils/hostPricing'


function describeFee({ basisPoints, flatCents }, t) {
  const parts = []
  if (basisPoints > 0) parts.push(formatPercent(basisPoints))
  if (flatCents > 0) parts.push(formatMoneyCents(flatCents))
  return parts.length ? t('buyerDiscovery.host.perPaidTicket', { fee: parts.join(' + ') }) : t('buyerDiscovery.host.noFeeOnTickets')
}

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY
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
  const { t } = useTranslation()
  const signInClass = tone === 'dark'
    ? 'font-semibold text-white underline underline-offset-4 hover:text-brand-200'
    : 'font-semibold text-brand-800 underline underline-offset-4 hover:text-brand-900'
  return (
    <div className={`flex flex-col gap-3 ${align === 'center' ? 'items-center text-center' : 'items-start'}`}>
      <Link to={targets.primary} className="btn-primary gap-2 text-base">
        {targets.signedIn ? t('buyerDiscovery.host.goToYourDashboard') : t('buyerDiscovery.host.startHosting')} <ArrowRight aria-hidden="true" className="h-4 w-4" />
      </Link>
      {targets.signIn && (
        <p className={`text-sm ${tone === 'dark' ? 'text-content-inverse-muted' : 'text-content-muted'}`}>{t('buyerDiscovery.host.alreadyHaveAnAccount')}<Link to={targets.signIn} className={`rounded focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2 ${signInClass}`}>{t('buyerDiscovery.host.signIn')}</Link>
        </p>
      )}
    </div>
  )
}

// Illustrative only: shows what the door looks like without implying real sales.
function DoorPreview() {
  const { t } = useTranslation()
  return (
    <div aria-hidden="true" className="relative mx-auto w-full max-w-sm select-none lg:max-w-none">
      <div className="host-preview-back absolute -right-2 -top-4 z-10 hidden w-56 rounded-2xl border border-neutral-200 bg-white p-4 shadow-card sm:block lg:-right-4">
        <p className="text-xs font-semibold text-content-muted">{t('buyerDiscovery.host.checkedIn')}</p>
        <p className="mt-1 font-display text-2xl font-bold text-neutral-950">186 <span className="text-base font-medium text-content-muted">{t('buyerDiscovery.host.of240')}</span></p>
        <div className="mt-3 h-2 overflow-hidden rounded-full bg-neutral-100"><div className="h-full w-[78%] rounded-full bg-brand-500" /></div>
        <p className="mt-3 flex items-center gap-1.5 text-xs text-content-muted"><WifiOff className="h-3.5 w-3.5" />{t('buyerDiscovery.host.offlineScansSyncLater')}</p>
      </div>
      <div className="host-preview-front relative mr-auto w-full max-w-[18rem] rounded-[1.75rem] border border-neutral-200 bg-white p-3 shadow-card sm:ml-4">
        <div className="rounded-[1.25rem] bg-brand-950 px-5 pb-6 pt-5 text-white">
          <p className="text-sm font-semibold text-brand-200">{t('buyerDiscovery.host.doorScanner')}</p>
          <div className="mt-6 flex flex-col items-center text-center">
            <span className="host-preview-check flex h-16 w-16 items-center justify-center rounded-full bg-brand-500/20">
              <CheckCircle2 className="h-9 w-9 text-brand-300" />
            </span>
            <p className="mt-4 font-display text-2xl font-bold">{t('buyerDiscovery.host.admitted')}</p>
            <p className="mt-1 text-sm text-content-inverse-muted">{t('buyerDiscovery.host.generalAdmission1Ticket')}</p>
          </div>
        </div>
        <div className="flex items-center justify-between px-3 pb-1 pt-3 text-xs text-content-muted">
          <span>{t('buyerDiscovery.host.exampleEvent')}</span><span className="font-semibold text-brand-800">{t('buyerDiscovery.host.nextGuest')}</span>
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
  const { t } = useTranslation()
  const id = useId()
  const [priceInput, setPriceInput] = useState('25')
  const [quantityInput, setQuantityInput] = useState('1')
  const priceCents = parsePriceInput(priceInput)
  const quantity = parseQuantityInput(quantityInput)
  const priceError = priceInput.trim() && priceCents === null ? t('buyerDiscovery.host.enterATicketPriceLike25Or') : null
  const quantityError = quantityInput.trim() && quantity === null ? t('buyerDiscovery.host.enterAWholeNumberFrom1To', { value1: MAX_QUANTITY.toLocaleString(activeIntlLocale()) }) : null
  const ready = priceCents !== null && quantity !== null
  const result = ready ? calculateHostPayout({ priceCents, quantity, pricing }) : null
  const money = cents => (result ? formatMoneyCents(cents) : '—')
  const ticketsLabel = t('buyerDiscovery.host.ticketCount', { count: quantity || 1, formattedCount: (quantity || 1).toLocaleString(activeIntlLocale()) })
  const absorbsMoreThanPrice = Boolean(result?.feeExceedsPrice)
  // Only a confirmed platform bearer means the organizer keeps the full price.
  const receiveLabel = pricing.processingIncluded === true ? t('buyerDiscovery.host.youReceive') : t('buyerDiscovery.host.youReceiveBeforeCardProcessing')
  const summary = result
    ? t('buyerDiscovery.host.buyerPaysYouReceiveIfYouAbsorb', { value1: money(result.buyerPays.buyerTotalCents), value2: money(result.buyerPays.organizerReceivesCents), value3: money(result.organizerAbsorbs.organizerReceivesCents), value4: pricing.processingIncluded === true ? '' : t('buyerDiscovery.host.beforeCardProcessing') })
    : ''

  return (
    <div className="rounded-2xl bg-white p-5 shadow-card sm:p-7">
      <h2 className="font-display text-xl font-bold text-neutral-950">{t('buyerDiscovery.host.feeCalculator')}</h2>
      <p className="mt-1 text-sm text-content-muted">{t('buyerDiscovery.host.compareWhatYouPay')}</p>
      <div className="mt-5 grid grid-cols-[minmax(0,1fr)_7rem] gap-3">
        <div>
          <label htmlFor={`${id}-price`} className="mb-1.5 block text-sm font-medium text-neutral-800">{t('buyerDiscovery.host.ticketPrice')}</label>
          <div className="relative">
            <span aria-hidden="true" className="pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 text-neutral-500">$</span>
            <input id={`${id}-price`} type="text" inputMode="decimal" autoComplete="off" enterKeyHint="done" value={priceInput}
              onChange={event => setPriceInput(event.target.value)} placeholder="25.00"
              aria-invalid={priceError ? true : undefined} aria-describedby={priceError ? `${id}-price-error` : undefined}
              className={`input !pl-8 text-base tabular-nums ${priceError ? 'input-error' : ''}`} />
          </div>
        </div>
        <div>
          <label htmlFor={`${id}-quantity`} className="mb-1.5 block text-sm font-medium text-neutral-800">{t('buyerDiscovery.host.tickets2')}</label>
          <input id={`${id}-quantity`} type="text" inputMode="numeric" pattern="[0-9]*" autoComplete="off" enterKeyHint="done" value={quantityInput}
            onChange={event => setQuantityInput(event.target.value)}
            aria-invalid={quantityError ? true : undefined} aria-describedby={quantityError ? `${id}-quantity-error` : undefined}
            className={`input text-base tabular-nums ${quantityError ? 'input-error' : ''}`} />
        </div>
      </div>
      {priceError && <p id={`${id}-price-error`} className="mt-2 text-sm text-red-700">{priceError}</p>}
      {quantityError && <p id={`${id}-quantity-error`} className="mt-2 text-sm text-red-700">{quantityError}</p>}

      <p role="status" className="sr-only">{summary}</p>
      <div className="mt-5">
        {result && result.subtotalCents === 0 && (
          <p className="mb-3 flex items-start gap-2 rounded-xl bg-brand-50 px-4 py-3 text-sm text-brand-900"><Check aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" />{t('buyerDiscovery.host.freeTicketsHaveNoHåfaPassFee')}</p>
        )}
        <div className="grid gap-3 sm:grid-cols-2">
          <section aria-labelledby={`${id}-pass`} className="rounded-xl border border-neutral-200 bg-white px-4 py-3">
            <h3 id={`${id}-pass`} className="text-sm font-semibold text-brand-800">{t('buyerDiscovery.host.buyerPaysTheFee')}</h3>
            <dl className="mt-1 divide-y divide-neutral-100">
              <ResultRow label={t('buyerDiscovery.host.buyerPaysFor', { ticketsLabel: ticketsLabel })} value={money(result?.buyerPays.buyerTotalCents)} />
              <ResultRow label={t('buyerDiscovery.host.håfapassFee')} value={money(result?.feeCents)} />
              <ResultRow label={receiveLabel} value={money(result?.buyerPays.organizerReceivesCents)} strong />
            </dl>
          </section>
          <section aria-labelledby={`${id}-absorb`} className="rounded-xl border border-neutral-200 bg-white px-4 py-3">
            <h3 id={`${id}-absorb`} className="text-sm font-semibold text-brand-800">{t('buyerDiscovery.host.youAbsorbTheFee')}</h3>
            <dl className="mt-1 divide-y divide-neutral-100">
              <ResultRow label={t('buyerDiscovery.host.buyerPaysFor', { ticketsLabel: ticketsLabel })} value={money(result?.organizerAbsorbs.buyerTotalCents)} />
              <ResultRow label={t('buyerDiscovery.host.håfapassFee')} value={money(result?.feeCents)} />
              <ResultRow label={receiveLabel} value={money(result?.organizerAbsorbs.organizerReceivesCents)} strong />
            </dl>
          </section>
        </div>
        {absorbsMoreThanPrice && (
          <p className="mt-3 text-sm text-content-muted">{t('buyerDiscovery.host.atThisPriceTheFeeIsMore')}</p>
        )}
        {!ready && !priceError && !quantityError && <p className="mt-3 text-sm text-content-muted">{t('buyerDiscovery.host.enterATicketPriceAndNumberOf')}</p>}
      </div>
      <p className="mt-4 text-xs leading-relaxed text-content-muted">{t('buyerDiscovery.host.estimateForOneOrderBeforePromoCodes')}{pricing.processingIncluded === true
          ? t('buyerDiscovery.host.cardProcessingIsIncludedInTheHåfaPass')
          : t('buyerDiscovery.host.cardProcessingIsDeductedFromYourProceeds')}
        {' '}{t('buyerDiscovery.host.yourDashboardShowsTheExactAmountsFor')}</p>
    </div>
  )
}

function WorkedExamples({ pricing }) {
  const { t } = useTranslation()
  const receiveLabel = pricing.processingIncluded === true ? t('buyerDiscovery.host.youReceive') : t('buyerDiscovery.host.youReceiveBeforeCardProcessing')
  return (
    <div className="mt-10 rounded-2xl bg-brand-50 p-5 sm:p-7">
      <h2 className="font-display text-xl font-bold text-neutral-950">{t('buyerDiscovery.host.twoTicketExamples')}</h2>
      <p className="mt-2 text-sm text-content-muted">{t(pricing.processingIncluded === true ? 'buyerDiscovery.host.examplesIntro' : 'buyerDiscovery.host.examplesBeforeProcessing')}</p>
      <div className="mt-6 grid gap-7 sm:grid-cols-2 sm:gap-10">
        {[2500, 5900].map(priceCents => {
          const result = calculateHostPayout({ priceCents, quantity: 1, pricing })
          return <section key={priceCents} aria-label={t('buyerDiscovery.host.ticketExample', { price: formatMoneyCents(priceCents) })}>
            <h3 className="font-display text-2xl font-bold text-brand-900">{t('buyerDiscovery.host.ticketExample', { price: formatMoneyCents(priceCents) })}</h3>
            <dl className="mt-3">
              <ResultRow label={t('buyerDiscovery.host.exampleBuyerPays')} value={formatMoneyCents(result.buyerPays.buyerTotalCents)} />
              <ResultRow label={receiveLabel} value={formatMoneyCents(result.buyerPays.organizerReceivesCents)} strong />
              <ResultRow label={t('buyerDiscovery.host.exampleAbsorb')} value={formatMoneyCents(result.organizerAbsorbs.organizerReceivesCents)} />
            </dl>
          </section>
        })}
      </div>
    </div>
  )
}

function PricingSection({ configState, targets }) {
  const { t } = useTranslation()
  const pricing = configState.status === 'loaded' ? parseHostPricing(configState.config) : null
  const points = [
    t('buyerDiscovery.host.noSetupOrMonthlyFees'),
    t('buyerDiscovery.host.freeTicketsAreAlwaysFree'),
    t('buyerDiscovery.host.chooseWhetherBuyersPayTheFeeOr'),
  ]

  return (
    <section id="pricing" aria-labelledby="pricing-heading" className="scroll-mt-20 pb-12 pt-10 sm:py-16 lg:py-20">
      <div className="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8">
        <div className="grid items-start gap-9 lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)] lg:gap-12">
          <div>
            <h1 id="pricing-heading" className="font-display text-4xl font-bold leading-[1.08] tracking-tight text-neutral-950 sm:text-5xl">{t('buyerDiscovery.host.hostYourEventWithHåfaPass')}</h1>
            <div className="flow-root min-h-[14rem] sm:min-h-[11rem] lg:min-h-[15rem]">
              {configState.status === 'loading' && (
                <div role="status" aria-label={t('buyerDiscovery.host.loadingPricing')} className="mt-6 h-24 w-full max-w-sm rounded-lg bg-neutral-100" />
              )}
              {pricing && <>
                <p className="mt-6 font-display text-2xl font-bold text-brand-800 sm:text-3xl" data-testid="host-fee-summary">{describeFee(pricing, t)}</p>
                {pricing.processingIncluded === true && <>
                  <p className="mt-2 text-lg font-semibold text-neutral-950">{t('buyerDiscovery.host.cardProcessingIncluded')}</p>
                  <p className="mt-4 leading-relaxed text-content-muted">{t('buyerDiscovery.host.keepYourTicketPrice')}</p>
                </>}
              </>}
              {configState.status !== 'loading' && !pricing && (
                <div role="status" className="mt-6 rounded-xl bg-white p-4">
                  <p className="font-semibold text-neutral-900">{t('buyerDiscovery.host.currentRatesArenTAvailableRightNow')}</p>
                  <p className="mt-1 text-sm text-content-muted">{t('buyerDiscovery.host.paidTicketsCarryAPerTicketHåfaPass')}</p>
                  <div className="mt-3 flex flex-wrap gap-x-5 gap-y-1">
                    <button type="button" onClick={configState.retry} className="inline-flex min-h-11 items-center rounded text-sm font-semibold text-brand-800 underline underline-offset-4 focus-visible:ring-2 focus-visible:ring-focus">{t('buyerDiscovery.host.tryAgain')}</button>
                    <SupportLink subject={t('buyerDiscovery.host.håfapassPricing')} className="inline-flex min-h-11 items-center rounded text-sm font-semibold text-brand-800 underline underline-offset-4 focus-visible:ring-2 focus-visible:ring-focus">{t('buyerDiscovery.host.emailUs')}</SupportLink>
                  </div>
                </div>
              )}
            </div>
            <ul className="mt-6 space-y-3">
              {points.map(point => <li key={point} className="flex items-start gap-3 text-neutral-800">
                <Check aria-hidden="true" className="mt-1 h-4 w-4 shrink-0 text-brand-700" /><span>{point}</span>
              </li>)}
            </ul>
            <p className="mt-6 text-sm leading-relaxed text-content-muted">{t('buyerDiscovery.host.cancellationPromise')}</p>
            <div className="mt-4 min-h-6">{pricing?.payoutScheduleText && <p className="text-sm leading-relaxed text-content-muted">{t('buyerDiscovery.host.payouts', { payoutScheduleText: pricing.payoutScheduleText })}</p>}</div>
            <div className="mt-7"><CtaGroup targets={targets} /></div>
          </div>
          <div className="min-w-0 lg:pt-1">
            {pricing ? <FeeCalculator pricing={pricing} /> : configState.status === 'loading'
              ? <div aria-hidden="true" className="h-[32rem] rounded-2xl bg-white" /> : null}
          </div>
        </div>
        {pricing && <WorkedExamples pricing={pricing} />}
      </div>
    </section>
  )
}

function faqItems(pricing, t) {
  const feeAnswer = pricing
    ? t('buyerDiscovery.host.håfapassChargesThereAreNoSetupOr', { value1: describeFee(pricing, t), value2: pricing.processingIncluded ? t('buyerDiscovery.host.withCardProcessingIncluded') : '', value3: pricing.processingIncluded ? '' : t('buyerDiscovery.host.processingDeducted') })
    : t('buyerDiscovery.host.paidTicketsCarryAPerTicketHåfaPass2')
  const payoutAnswer = pricing?.payoutScheduleText
    ? t('buyerDiscovery.host.payoutsAreSentYourDashboardShowsA', { payoutScheduleText: pricing.payoutScheduleText })
    : t('buyerDiscovery.host.afterYourEventYourDashboardShowsA')
  return [
    { q: t('buyerDiscovery.host.howMuchDoesHåfaPassCost'), a: feeAnswer },
    { q: t('buyerDiscovery.host.whoPaysTheFeeMeOrMy'), a: t('buyerDiscovery.host.youDecideForEachEventBuyersCan') },
    { q: t('buyerDiscovery.host.canIHostAFreeEvent'), a: t('buyerDiscovery.host.yesFreeTicketsHaveNoHåfaPassFee') },
    { q: t('buyerDiscovery.host.whenDoIGetPaid'), a: <>{payoutAnswer}{' '}{t('buyerDiscovery.host.payoutMethod')}</> },
    { q: t('buyerDiscovery.host.howDoRefundsWork'), a: <>{t('buyerDiscovery.host.cancellationPromise')}{' '}{t('buyerDiscovery.host.youSetTheRefundRulesForYour')}<Link to="/policies/refunds" className="font-semibold text-brand-800 underline underline-offset-4">{t('buyerDiscovery.host.refundCancellationPolicy')}</Link>.</> },
    { q: t('buyerDiscovery.host.doesMyDoorStaffNeedAnApp'), a: t('buyerDiscovery.host.noStaffOpenTheScannerInTheir') },
    { q: t('buyerDiscovery.host.howDoIGetHelp'), a: <>{t('buyerDiscovery.host.emailTheHåfaPassTeamAtAnyPoint')}<SupportLink subject={t('buyerDiscovery.host.hostingOnHåfaPass')} className="font-semibold text-brand-800 underline underline-offset-4">{t('buyerDiscovery.host.contactSupport')}</SupportLink>.</> },
  ]
}

function HostContent({ targets }) {
  const { t } = useTranslation()
  const support = useSupportContact()
  const configState = usePublicConfig()
  const pricing = configState.status === 'loaded' ? parseHostPricing(configState.config) : null

  return (
    <div className="bg-stone-50 text-content">
      <SEO
        title={t('buyerDiscovery.host.hostYourEvent')}
        description={t('buyerDiscovery.host.sellTicketsForYourGuamEventWith')}
        url={`${PUBLIC_WEB_URL}/host`}
        image={`${PUBLIC_WEB_URL}/og-host.jpg`}
      />

      <PricingSection configState={configState} targets={targets} />

      <section aria-labelledby="publish-heading" className="bg-white py-12 sm:py-20">
        <div className="mx-auto grid max-w-6xl items-center gap-9 px-4 sm:px-6 lg:grid-cols-2 lg:gap-16 lg:px-8">
          <GuamPhoto photo="market" />
          <div>
            <h2 id="publish-heading" className="font-display text-3xl font-bold tracking-tight text-neutral-950 sm:text-4xl">{t('buyerDiscovery.host.publishYourself')}</h2>
            <p className="mt-5 text-lg leading-relaxed text-content-muted">{t('buyerDiscovery.host.publishIntro')}</p>
            <ol className="mt-7 space-y-6">
              <li><h3 className="text-lg font-semibold text-neutral-950">{t('buyerDiscovery.host.createYourEvent')}</h3><p className="mt-2 leading-relaxed text-content-muted">{t('buyerDiscovery.host.addYourDateVenueArtworkAndTicket')}</p></li>
              <li><h3 className="text-lg font-semibold text-neutral-950">{t('buyerDiscovery.host.oneTimeVerification')}</h3><p className="mt-2 leading-relaxed text-content-muted">{t('buyerDiscovery.host.verificationBody')}</p></li>
              <li><h3 className="text-lg font-semibold text-neutral-950">{t('buyerDiscovery.host.sellAndShare')}</h3><p className="mt-2 leading-relaxed text-content-muted">{t('buyerDiscovery.host.shareYourEventLinkBuyersPayBy')}</p></li>
            </ol>
          </div>
        </div>
      </section>

      <section aria-labelledby="door-heading" className="py-12 sm:py-20">
        <div className="mx-auto grid max-w-6xl items-center gap-12 px-4 sm:px-6 lg:grid-cols-[minmax(0,7fr)_minmax(0,5fr)] lg:gap-20 lg:px-8">
          <div>
            <h2 id="door-heading" className="font-display text-3xl font-bold tracking-tight text-neutral-950 sm:text-4xl">{t('buyerDiscovery.host.runTheDoor')}</h2>
            <ul className="mt-7 space-y-7">
              {[
                { icon: ScanLine, title: t('buyerDiscovery.host.doorScannerOnAnyPhone'), body: t('buyerDiscovery.host.scanTicketsInThePhoneSBrowser') },
                { icon: Banknote, title: t('buyerDiscovery.host.cashBoxOffice'), body: t('buyerDiscovery.host.sellTicketsAtTheDoorForCash') },
                { icon: Users, title: t('buyerDiscovery.host.teamRoles'), body: t('buyerDiscovery.host.inviteManagersFinanceMarketingBoxOfficeAnd') },
              ].map(({ icon: Icon, title, body }) => <li key={title} className="flex gap-4">
                <Icon aria-hidden="true" className="mt-1 h-5 w-5 shrink-0 text-brand-700" />
                <div><h3 className="text-lg font-semibold text-neutral-950">{title}</h3><p className="mt-2 leading-relaxed text-content-muted">{body}</p></div>
              </li>)}
            </ul>
          </div>
          <DoorPreview />
        </div>
      </section>

      <section aria-labelledby="local-help-heading" className="bg-brand-50 py-12 sm:py-16">
        <div className="mx-auto grid max-w-6xl items-center gap-8 px-4 sm:px-6 md:grid-cols-2 lg:gap-16 lg:px-8">
          <div>
            <h2 id="local-help-heading" className="font-display text-3xl font-bold tracking-tight text-neutral-950 sm:text-4xl">{t('buyerDiscovery.host.localHelp')}</h2>
            <p className="mt-5 text-lg leading-relaxed text-content-muted">{t('buyerDiscovery.host.localHelpBody')}</p>
            {support.email && <SupportLink subject={t('buyerDiscovery.host.hostingOnHåfaPass')} className="btn-secondary mt-6 gap-2">{t('buyerDiscovery.host.firstEventHelp')}<ArrowRight aria-hidden="true" className="h-4 w-4" /></SupportLink>}
          </div>
          <GuamPhoto photo="bay" sizes="(min-width: 768px) 45vw, 100vw" />
        </div>
      </section>

      <section aria-labelledby="faq-heading" className="py-14 sm:py-20">
        <div className="mx-auto max-w-3xl px-4 sm:px-6 lg:px-8">
          <h2 id="faq-heading" className="font-display text-3xl font-bold tracking-tight text-neutral-950 sm:text-4xl">{t('buyerDiscovery.host.questionsOrganizersAsk')}</h2>
          <div className="mt-8 divide-y divide-neutral-200 border-y border-neutral-200">
            {faqItems(pricing, t).map(({ q, a }) => (
              <details key={q} className="host-faq group">
                <summary className="flex min-h-14 cursor-pointer list-none items-center justify-between gap-4 rounded py-4 text-left font-semibold text-neutral-950 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus [&::-webkit-details-marker]:hidden">
                  {q}
                  <ChevronDown aria-hidden="true" className="h-5 w-5 shrink-0 text-content-muted transition-transform duration-200 ease-out-strong group-open:rotate-180" />
                </summary>
                <div className="host-faq-answer pb-5 pr-9 leading-relaxed text-content-muted">{a}</div>
              </details>
            ))}
          </div>
          {support.email && <p className="mt-6 flex items-center gap-2 text-sm text-content-muted"><Mail aria-hidden="true" className="h-4 w-4" />{t('buyerDiscovery.host.somethingElse')}<SupportLink subject={t('buyerDiscovery.host.hostingOnHåfaPass')} className="font-semibold text-brand-800 underline underline-offset-4">{t('buyerDiscovery.host.askUs')}</SupportLink></p>}
        </div>
      </section>

      <section aria-labelledby="final-cta-heading" className="bg-brand-950 py-14 text-white sm:py-20">
        <div className="mx-auto flex max-w-3xl flex-col items-center px-4 text-center sm:px-6 lg:px-8">
          <h2 id="final-cta-heading" className="font-display text-3xl font-bold tracking-tight sm:text-4xl">{t('buyerDiscovery.host.readyToSellYourFirstTicket')}</h2>
          <p className="mt-4 max-w-xl text-content-inverse-muted">{t('buyerDiscovery.host.createYourOrganizerProfileInAMinute')}</p>
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
