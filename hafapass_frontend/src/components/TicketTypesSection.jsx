import { useState } from 'react'
import { Minus, Plus, ShoppingCart } from 'lucide-react'

export default function TicketTypesSection({ ticketTypes = [], onCheckout }) {
  const [quantities, setQuantities] = useState({})

  const setQty = (id, qty) => setQuantities(prev => ({ ...prev, [id]: Math.max(0, qty) }))
  const getQty = (id) => quantities[id] || 0

  const formatPrice = (cents) => cents === 0 ? 'Free' : `$${(cents / 100).toFixed(2)}`

  // Clamp quantities to current availability to prevent stale totals
  const getMaxQty = (tt) => Math.max(0, Math.min(tt.max_per_order || 10, tt.quantity_available - tt.quantity_sold))
  const getClampedQty = (tt) => Math.min(getQty(tt.id), getMaxQty(tt))

  const totalSelected = ticketTypes.reduce((sum, tt) => sum + getClampedQty(tt), 0)
  const totalCents = ticketTypes.reduce((sum, tt) => sum + (getClampedQty(tt) * tt.price_cents), 0)

  const handleCheckout = () => {
    const lineItems = ticketTypes
      .map(tt => {
        const qty = getClampedQty(tt)
        return qty > 0 ? { ticket_type_id: tt.id, quantity: qty } : null
      })
      .filter(Boolean)
    if (lineItems.length > 0) onCheckout(lineItems)
  }

  return (
    <div>
      <h2 className="text-lg font-semibold text-neutral-900 mb-4">Tickets</h2>
      <div className="space-y-3">
        {ticketTypes.map(tt => {
          const available = tt.quantity_available - tt.quantity_sold
          const soldOut = available <= 0
          const rawQty = getQty(tt.id)
          const maxQty = Math.min(tt.max_per_order || 10, available)
          const qty = Math.min(rawQty, maxQty) // Clamped to current availability

          return (
            <div key={tt.id} className={`card p-4 transition-all duration-200 ${qty > 0 ? 'border-brand-500/40 shadow-sm' : ''}`}>
              <div className="flex items-center justify-between">
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2">
                    <h3 className="font-medium text-neutral-900">{tt.name}</h3>
                    {soldOut && (
                      <span className="text-xs bg-neutral-100 text-neutral-500 px-2 py-0.5 rounded-full font-medium">Sold Out</span>
                    )}
                  </div>
                  {tt.description && <p className="text-sm text-neutral-500 mt-0.5">{tt.description}</p>}
                  <p className="text-sm font-semibold text-accent-600 mt-1">{formatPrice(tt.price_cents)}</p>
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
          Get Tickets &mdash; {formatPrice(totalCents)}
        </button>
      )}
    </div>
  )
}
