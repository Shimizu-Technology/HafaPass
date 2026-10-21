import BuyerTicketTypeText from './BuyerTicketTypeText'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Minus, Plus, ShoppingCart, Clock, Zap } from 'lucide-react'
import PaidCheckoutGate from './PaidCheckoutGate'
import usePaidCheckoutAdminOnly from '../hooks/usePaidCheckoutAdminOnly'
import { formatTicketPrice, ticketPriceCents, ticketAllInCents, ticketServiceFeeCents, remainingTickets, isTicketPurchasable } from '../utils/ticketPricing'

// Rows and the buy button lead with all-in prices (ticket + the buyer's
// service fee), with the breakdown as a smaller secondary line.
// In production test mode free tickets stay buyable for everyone but paid
// ones only for platform admins.
// `showOriginal` follows the event page's "Show original" switch for
// machine-translated ticket names.
export default function TicketTypesSection({ ticketTypes = [], onCheckout, showOriginal = false }) {
  const { t } = useTranslation()
  const [quantities, setQuantities] = useState({})

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
    const diff = new Date(dateStr) - new Date()
    return Math.max(0, Math.ceil(diff / (1000 * 60 * 60 * 24)))
  }

  return (
    <div>
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
          const hasDiscount = tt.active_tier && basePrice < tt.price_cents
          // The struck-through regular price already says what comes next when
          // the next tier returns to it; don't repeat the same price twice.
          const nextTierPrice = !tt.next_tier ? null
            : Number.isSafeInteger(tt.next_tier.all_in_price_cents) ? tt.next_tier.all_in_price_cents : tt.next_tier.price_cents

          return (
            <div key={tt.id} className={`card p-4 transition-[border-color,box-shadow] duration-200 ease-out-strong ${qty > 0 ? 'border-brand-500/40 shadow-sm' : ''}`}>
              <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
                <div className="min-w-0 w-full sm:flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <h3 className="font-medium text-neutral-900 break-words max-w-full"><BuyerTicketTypeText ticketType={tt} showOriginal={showOriginal} /></h3>
                    {soldOut && (
                      <span className="text-xs bg-accent-50 text-accent-600 px-2 py-0.5 rounded-full font-medium">{available <= 0 ? t('events.soldOut') : t('buyer.TicketTypesSection.salesUnavailable')}</span>
                    )}
                  </div>
                  {(showOriginal && tt.machine_translated ? tt.original_description : tt.description) && <p className="text-sm text-neutral-600 mt-0.5 break-words">{showOriginal && tt.machine_translated ? tt.original_description : tt.description}</p>}

                  {/* Pricing with tier info */}
                  <div className="mt-1">
                    {tt.active_tier ? (
                      <div>
                        <p className="text-sm font-semibold text-neutral-900">
                          {tt.active_tier.name} — {formatPrice(currentPrice)}
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
                      {tt.active_tier.tier_type === 'time_based' && tt.active_tier.ends_at && daysUntil(tt.active_tier.ends_at) <= 7 && (
                        <p className="text-xs text-amber-600 font-medium flex items-center gap-1">
                          <Clock className="w-3 h-3" />
                          {t('pricing.endsIn', { days: daysUntil(tt.active_tier.ends_at) })}
                        </p>
                      )}
                    </div>
                  )}

                  {/* Next tier info */}
                  {nextTierPrice !== null && !(hasDiscount && nextTierPrice === regularPrice) && (
                    <p className="text-xs text-neutral-600 mt-1">
                      {t('pricing.regularPrice', { price: formatPrice(nextTierPrice) })}
                    </p>
                  )}
                </div>

                {!soldOut && (
                  <div className="flex shrink-0 items-center gap-2 self-end sm:ml-4">
                    <button
                      onClick={() => setQty(tt.id, qty - 1)}
                      disabled={qty === 0}
                      className="w-11 h-11 rounded-xl border border-neutral-200 flex items-center justify-center text-neutral-600 hover:bg-neutral-50 disabled:opacity-30 transition-colors" aria-label={t('buyer.TicketTypesSection.decreaseQuantityFor', { value1: tt.name })}
                    >
                      <Minus className="w-3.5 h-3.5" />
                    </button>
                    <span className="w-8 text-center text-sm font-semibold text-neutral-900">{qty}</span>
                    <button
                      onClick={() => setQty(tt.id, Math.min(qty + 1, maxQty))}
                      disabled={qty >= maxQty}
                      className="w-11 h-11 rounded-xl border border-neutral-200 flex items-center justify-center text-neutral-600 hover:bg-neutral-50 disabled:opacity-30 transition-colors" aria-label={t('buyer.TicketTypesSection.increaseQuantityFor', { value1: tt.name })}
                    >
                      <Plus className="w-3.5 h-3.5" />
                    </button>
                  </div>
                )}
              </div>
            </div>
          )
        })}
      </div>

      {totalSelected > 0 && <PaidCheckoutGate active={paidAdminOnly && totalCents > 0}>
        <button onClick={handleCheckout} className="w-full mt-5 btn-primary text-base !py-4 gap-2">
          <ShoppingCart className="w-5 h-5" />
          {t('eventDetail.buyTickets')} &mdash; {formatPrice(totalCents)}
        </button>
      </PaidCheckoutGate>}
    </div>
  )
}
