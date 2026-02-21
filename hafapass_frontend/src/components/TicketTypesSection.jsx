import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Minus, Plus, ShoppingCart, Clock, Zap } from 'lucide-react'

export default function TicketTypesSection({ ticketTypes = [], onCheckout }) {
  const { t } = useTranslation()
  const [quantities, setQuantities] = useState({})

  const setQty = (id, qty) => setQuantities(prev => ({ ...prev, [id]: Math.max(0, qty) }))
  const getQty = (id) => quantities[id] || 0

  const formatPrice = (cents) => cents === 0 ? t('events.free') : `$${(cents / 100).toFixed(2)}`

  const getMaxQty = (tt) => Math.max(0, Math.min(tt.max_per_order || 10, tt.quantity_available - tt.quantity_sold))
  const getClampedQty = (tt) => Math.min(getQty(tt.id), getMaxQty(tt))

  // Use current_price_cents if available, fallback to price_cents
  const getPrice = (tt) => tt.current_price_cents ?? tt.price_cents

  const totalSelected = ticketTypes.reduce((sum, tt) => sum + getClampedQty(tt), 0)
  const totalCents = ticketTypes.reduce((sum, tt) => sum + (getClampedQty(tt) * getPrice(tt)), 0)

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
          const available = tt.quantity_available - tt.quantity_sold
          const soldOut = available <= 0
          const rawQty = getQty(tt.id)
          const maxQty = Math.min(tt.max_per_order || 10, available)
          const qty = Math.min(rawQty, maxQty)
          const currentPrice = getPrice(tt)
          const hasDiscount = tt.active_tier && currentPrice < tt.price_cents

          return (
            <div key={tt.id} className={`card p-4 transition-all duration-200 ${qty > 0 ? 'border-brand-500/40 shadow-sm' : ''}`}>
              <div className="flex items-center justify-between">
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2">
                    <h3 className="font-medium text-neutral-900">{tt.name}</h3>
                    {soldOut && (
                      <span className="text-xs bg-accent-50 text-accent-600 px-2 py-0.5 rounded-full font-medium">{t('events.soldOut')}</span>
                    )}
                  </div>
                  {tt.description && <p className="text-sm text-neutral-500 mt-0.5">{tt.description}</p>}

                  {/* Pricing with tier info */}
                  <div className="mt-1">
                    {tt.active_tier ? (
                      <div>
                        <p className="text-sm font-semibold text-accent-600">
                          {tt.active_tier.name} — {formatPrice(currentPrice)}
                        </p>
                        {hasDiscount && (
                          <p className="text-xs text-neutral-400 line-through">{formatPrice(tt.price_cents)}</p>
                        )}
                      </div>
                    ) : (
                      <p className="text-sm font-semibold text-accent-600">{formatPrice(currentPrice)}</p>
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
                  {tt.next_tier && (
                    <p className="text-xs text-neutral-400 mt-1">
                      {t('pricing.regularPrice', { price: formatPrice(tt.next_tier.price_cents) })}
                    </p>
                  )}
                </div>

                {!soldOut && (
                  <div className="flex items-center gap-2 ml-4">
                    <button
                      onClick={() => setQty(tt.id, qty - 1)}
                      disabled={qty === 0}
                      className="w-11 h-11 rounded-xl border border-neutral-200 flex items-center justify-center text-neutral-600 hover:bg-neutral-50 disabled:opacity-30 transition-colors" aria-label="Decrease quantity"
                    >
                      <Minus className="w-3.5 h-3.5" />
                    </button>
                    <span className="w-8 text-center text-sm font-semibold text-neutral-900">{qty}</span>
                    <button
                      onClick={() => setQty(tt.id, Math.min(qty + 1, maxQty))}
                      disabled={qty >= maxQty}
                      className="w-11 h-11 rounded-xl border border-neutral-200 flex items-center justify-center text-neutral-600 hover:bg-neutral-50 disabled:opacity-30 transition-colors" aria-label="Increase quantity"
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

      {totalSelected > 0 && (
        <button onClick={handleCheckout} className="w-full mt-5 btn-primary text-base !py-4 gap-2">
          <ShoppingCart className="w-5 h-5" />
          {t('eventDetail.buyTickets')} &mdash; {formatPrice(totalCents)}
        </button>
      )}
    </div>
  )
}
