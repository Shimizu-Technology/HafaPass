import TranslatedTicketContent from './TranslatedTicketContent'
import MachineTranslationNotice from './MachineTranslationNotice'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Minus, Plus, ShoppingCart, Clock, Zap, ChevronDown, Sparkles } from 'lucide-react'
import PaidCheckoutGate from './PaidCheckoutGate'
import PriceOdometer from './PriceOdometer'
import usePaidCheckoutAdminOnly from '../hooks/usePaidCheckoutAdminOnly'
import { formatTicketPrice, ticketPriceCents, ticketAllInCents, ticketServiceFeeCents, remainingTickets, isTicketPurchasable } from '../utils/ticketPricing'
import { formatScheduleTime, getServerNow } from '../utils/serverClock'
import { DEFAULT_EVENT_TIME_ZONE, formatEventDate } from '../utils/eventTime'

// Rows and the buy button lead with all-in prices (ticket + the buyer's
// service fee), with the breakdown as a smaller secondary line.
// In production test mode free tickets stay buyable for everyone but paid
// ones only for platform admins.
// `showOriginal` follows the event page's "Show original" switch for
// machine-translated ticket names.
export default function TicketTypesSection({ ticketTypes = [], onCheckout, showOriginal = false, showTranslationNotice = true }) {
  const { t } = useTranslation()
  const [quantities, setQuantities] = useState({})
  const [expandedPasses, setExpandedPasses] = useState({})

  const togglePassSchedule = (id) => setExpandedPasses(prev => ({ ...prev, [id]: !prev[id] }))

  const setQty = (id, qty) => setQuantities(prev => ({ ...prev, [id]: Math.max(0, qty) }))
  const getQty = (id) => quantities[id] || 0

  const formatPrice = (cents) => formatTicketPrice(cents, t('events.free'))

  const getMaxQty = (tt) => !isTicketPurchasable(tt) || ticketPriceCents(tt) === null ? 0
    : Math.max(0, Math.min(tt.max_per_order || 10, tt.max_per_buyer || Infinity, remainingTickets(tt) ?? 0))
  const getClampedQty = (tt) => Math.min(getQty(tt.id), getMaxQty(tt))

  const totalSelected = ticketTypes.reduce((sum, tt) => sum + getClampedQty(tt), 0)
  const totalCents = ticketTypes.reduce((sum, tt) => sum + (getClampedQty(tt) * ticketAllInCents(tt)), 0)
  const paidAdminOnly = usePaidCheckoutAdminOnly(totalCents > 0)

  const handleCheckout = () => {
    const lineItems = ticketTypes
      .map(tt => {
        const qty = getClampedQty(tt)
        return qty > 0 ? { ticket_type_id: tt.id, quantity: qty } : null
      })
      .filter(Boolean)
    if (lineItems.length > 0) onCheckout(lineItems)
  }

  const daysUntil = (dateStr) => {
    if (!dateStr) return null
    const diff = Date.parse(dateStr) - getServerNow()
    return Math.max(0, Math.ceil(diff / (1000 * 60 * 60 * 24)))
  }

  return (
    <div className="tabular-nums">
      <h2 className="text-lg font-semibold text-neutral-900 mb-4">{t('eventDetail.buyTickets')}</h2>
      <div className="space-y-3">
        {ticketTypes.map(tt => {
          const available = remainingTickets(tt) ?? 0
          const soldOut = getMaxQty(tt) === 0
          const maxQty = getMaxQty(tt)
          const qty = getClampedQty(tt)
          const basePrice = ticketPriceCents(tt)
          const currentPrice = ticketAllInCents(tt)
          const feeCents = ticketServiceFeeCents(tt)
          const regularPrice = Number.isSafeInteger(tt.regular_all_in_price_cents) ? tt.regular_all_in_price_cents : tt.price_cents
          const schedule = tt.pricing_schedule
          const activeTier = schedule ? schedule.active_tier : tt.active_tier
          const hasDiscount = activeTier && basePrice < tt.price_cents
          // The struck-through regular price already says what comes next when
          // the next tier returns to it; don't repeat the same price twice.
          const nextTierPrice = !tt.next_tier ? null
            : Number.isSafeInteger(tt.next_tier.all_in_price_cents) ? tt.next_tier.all_in_price_cents : tt.next_tier.price_cents

          const nextWindow = activeTier?.tier_type === 'quantity_based' ? null : schedule?.next_tier
          const salesClose = schedule?.sales_end_at
          const activeEnd = activeTier?.tier_type === 'time_based' ? activeTier.ends_at : null
          const transitionAt = [activeEnd, nextWindow?.starts_at].filter(Boolean)
            .map(value => [value, Date.parse(value)]).sort((a, b) => a[1] - b[1])[0]
          const showTransition = schedule && transitionAt && (!salesClose || transitionAt[1] < Date.parse(salesClose))
          const activeWindowEnds = activeEnd && transitionAt?.[1] === Date.parse(activeEnd)
          const changesToNext = transitionAt && transitionAt[1] === Date.parse(nextWindow?.starts_at)
          const upcomingTier = changesToNext ? nextWindow : null
          const followingTier = (activeWindowEnds ? tt.next_tier : null) || upcomingTier
          const followingPrice = followingTier ? `${followingTier.name} ${formatPrice(followingTier.all_in_price_cents)}`
            : activeWindowEnds ? t('pricing.basePrice', { price: formatPrice(regularPrice) }) : ''
          const transitionDate = showTransition ? formatScheduleTime(transitionAt[0], schedule.timezone) : null
          const transitionKey = activeWindowEnds
            ? (followingPrice ? 'pricing.scheduleEndsThen' : 'pricing.scheduleEnds')
            : 'pricing.nextWindowStarts'


          return (
            <TranslatedTicketContent key={tt.id} record={tt} showOriginal={showOriginal}>{content => <div data-selected={qty > 0 ? 'true' : 'false'} className={`rounded-xl border p-4 transition-[border-color,background-color,box-shadow] duration-200 ease-out-strong ${qty > 0 ? 'border-brand-600 bg-brand-50/25 shadow-soft ring-1 ring-brand-500/20' : 'border-neutral-200 bg-white'}`}>
              <div className="flex flex-col gap-3">
                <div className="min-w-0 w-full sm:flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <h3 className="font-medium text-neutral-900 break-words max-w-full">{content.name}</h3>
                    {tt.is_pass && tt.included_events?.length > 0 && (
                      <span className="inline-flex items-center gap-1 rounded-full border border-brand-200 bg-brand-50 px-2.5 py-0.5 text-xs font-semibold text-brand-900">
                        <Sparkles aria-hidden="true" className="h-3 w-3" />
                        {t('buyer.TicketTypesSection.multiNightPass', { count: tt.included_events.length })}
                      </span>
                    )}
                    {soldOut && (
                      <span className="text-xs bg-accent-50 text-accent-600 px-2 py-0.5 rounded-full font-medium">{available <= 0 ? t('events.soldOut') : t('buyer.TicketTypesSection.salesUnavailable')}</span>
                    )}
                  </div>
                  {content.description && <p className="text-sm text-neutral-600 mt-0.5 break-words">{content.description}</p>}

                  {tt.is_pass && tt.included_events?.length > 0 && (
                    <div className="mt-2 rounded-lg border border-neutral-200/80 bg-neutral-50/70 px-3 py-2">
                      <button
                        type="button"
                        aria-expanded={Boolean(expandedPasses[tt.id])}
                        aria-controls={`pass-nights-${tt.id}`}
                        onClick={() => togglePassSchedule(tt.id)}
                        className="flex min-h-9 w-full items-center justify-between gap-2 text-left text-xs font-semibold text-brand-800 hover:text-brand-950"
                      >
                        <span>
                          {expandedPasses[tt.id]
                            ? t('buyer.TicketTypesSection.hideIncludedNights')
                            : t('buyer.TicketTypesSection.viewIncludedNights', { count: tt.included_events.length })}
                        </span>
                        <ChevronDown
                          aria-hidden="true"
                          className={`h-3.5 w-3.5 shrink-0 transition-transform ${expandedPasses[tt.id] ? 'rotate-180' : ''}`}
                        />
                      </button>
                      {expandedPasses[tt.id] && (
                        <ul id={`pass-nights-${tt.id}`} className="mt-2 space-y-1.5 border-t border-neutral-200/80 pt-2 text-xs text-neutral-700">
                          {tt.included_events.map(night => (
                            <li key={night.id} className="flex flex-wrap items-baseline justify-between gap-x-2 gap-y-0.5">
                              <span className="font-medium text-neutral-900 [overflow-wrap:anywhere]">{night.title}</span>
                              {night.starts_at && (
                                <span className="shrink-0 text-neutral-600">
                                  {formatEventDate(night.starts_at, night.timezone || DEFAULT_EVENT_TIME_ZONE, { weekday: 'short', year: undefined })}
                                </span>
                              )}
                            </li>
                          ))}
                        </ul>
                      )}
                    </div>
                  )}

                  {showTranslationNotice && content.notice && <MachineTranslationNotice {...content.notice} />}

                  {/* Pricing with tier info */}
                  <div className="mt-1">
                    {activeTier ? (
                      <div>
                        <p className={schedule ? "inline-flex rounded-full bg-brand-50 px-2.5 py-1 text-sm font-semibold text-brand-900" : "text-sm font-semibold text-neutral-900"}>
                          {t(schedule ? 'pricing.scheduledPrice' : 'pricing.currentPrice', { name: activeTier.name, price: formatPrice(currentPrice) })}
                        </p>
                        {hasDiscount && (
                          <p className="text-xs text-neutral-600 line-through">{formatPrice(regularPrice)}</p>
                        )}
                      </div>
                    ) : (
                      <p className="text-sm font-semibold text-neutral-900">{formatPrice(currentPrice)}</p>
                    )}
                    {feeCents > 0 && (
                      <p className="text-xs text-neutral-500">
                        {t('pricing.ticketPlusFee', { price: formatTicketPrice(basePrice), fee: formatTicketPrice(feeCents) })}
                      </p>
                    )}
                    {currentPrice === 0 && !soldOut && <p className="text-sm text-neutral-700">{t('buyer.TicketTypesSection.freeNoPayment')}</p>}
                  </div>

                  {/* Urgency indicators */}
                  {tt.active_tier && (
                    <div className="mt-1.5 space-y-0.5">
                      {tt.active_tier.tier_type === 'quantity_based' && tt.active_tier.remaining != null && tt.active_tier.remaining <= 20 && (
                        <p className="text-xs text-amber-600 font-medium flex items-center gap-1">
                          <Zap className="w-3 h-3" />
                          {t('pricing.onlyLeft', { count: tt.active_tier.remaining })}
                        </p>
                      )}
                      {!schedule && tt.active_tier.tier_type === 'time_based' && tt.active_tier.ends_at && daysUntil(tt.active_tier.ends_at) <= 7 && (
                        <p className="text-xs text-amber-600 font-medium flex items-center gap-1">
                          <Clock className="w-3 h-3" />
                          {t('pricing.endsIn', { count: daysUntil(tt.active_tier.ends_at) })}
                        </p>
                      )}
                    </div>
                  )}

                  {/* Next tier info */}
                  {(!schedule || (activeTier?.tier_type === 'quantity_based' && !nextWindow)) && nextTierPrice !== null && !(hasDiscount && nextTierPrice === regularPrice) && (
                    <p className="text-xs text-neutral-600 mt-1">
                      {t('pricing.regularPrice', { price: formatPrice(nextTierPrice) })}
                    </p>
                  )}
                  {transitionDate && <p className="mt-1 text-xs text-neutral-700">
                    {t(transitionKey, { date: transitionDate, price: followingPrice })}
                  </p>}
                  {salesClose && <p className="mt-1 text-xs text-neutral-700">
                    {t('pricing.salesClose', { date: formatScheduleTime(salesClose, schedule.timezone) })}
                  </p>}
                </div>

                {!soldOut && (
                  <div className="flex shrink-0 items-center gap-3 self-end">
                    <button
                      onClick={() => setQty(tt.id, qty - 1)}
                      disabled={qty === 0}
                      className="tactile-press min-h-12 min-w-12 rounded-xl border-2 border-neutral-300 flex items-center justify-center text-neutral-800 hover:bg-neutral-50 disabled:border-neutral-200 disabled:text-neutral-400" aria-label={t('buyer.TicketTypesSection.decreaseQuantityFor', { value1: tt.name })}
                    >
                      <Minus aria-hidden="true" className="w-5 h-5" />
                    </button>
                    <span className="w-10 text-center text-lg font-semibold text-neutral-900">{qty}</span>
                    <button
                      onClick={() => setQty(tt.id, Math.min(qty + 1, maxQty))}
                      disabled={qty >= maxQty}
                      className="tactile-press min-h-12 min-w-12 rounded-xl border-2 border-brand-700 flex items-center justify-center text-brand-800 hover:bg-brand-50 disabled:border-neutral-200 disabled:text-neutral-400" aria-label={t('buyer.TicketTypesSection.increaseQuantityFor', { value1: tt.name })}
                    >
                      <Plus aria-hidden="true" className="w-5 h-5" />
                    </button>
                  </div>
                )}
              </div>
            </div>}</TranslatedTicketContent>
          )
        })}
      </div>

      {totalSelected > 0 && <PaidCheckoutGate active={paidAdminOnly && totalCents > 0}>
        <button onClick={handleCheckout} className="w-full mt-5 btn-primary text-base !py-4 gap-2">
          <ShoppingCart className="w-5 h-5" />
          {t('eventDetail.buyTickets')} &mdash; <PriceOdometer value={formatPrice(totalCents)} />
        </button>
      </PaidCheckoutGate>}
    </div>
  )
}
