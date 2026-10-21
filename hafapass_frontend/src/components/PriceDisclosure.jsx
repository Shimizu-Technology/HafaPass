import { useTranslation } from 'react-i18next'
import { isTicketPurchasable, ticketPriceCents, ticketServiceFeeCents } from '../utils/ticketPricing'

const DEFAULT_PLATFORM = 'HåfaPass'

// "Sold by <organizer> · Tickets by HåfaPass". The organizer is the seller of
// the ticket; the platform sells as its agent and collects the service fee.
export function SellerLine({ seller, className = '' }) {
  const { t } = useTranslation()
  if (!seller?.seller_name) return null
  return (
    <p className={`text-xs leading-5 text-neutral-500 break-words ${className}`} data-testid="seller-line">
      {t('pricing.sellerLine', { seller: seller.seller_name, platform: seller.ticketing_service || DEFAULT_PLATFORM })}
    </p>
  )
}

// One plain sentence near the prices saying they are all-in and what the
// service fee pays for. Nothing renders for free-only events.
export function AllInPriceNote({ ticketTypes = [], includesProcessing = false, platform = DEFAULT_PLATFORM, className = '' }) {
  const { t } = useTranslation()
  const paid = ticketTypes.filter(ticket => isTicketPurchasable(ticket) && ticketPriceCents(ticket) > 0)
  if (!paid.length) return null
  const charged = paid.some(ticket => ticketServiceFeeCents(ticket) > 0)
  const text = !charged ? t('pricing.noAddedFees')
    : includesProcessing ? t('pricing.allInNote', { platform }) : t('pricing.allInNoteNoProcessing', { platform })
  return <p className={`text-xs leading-5 text-neutral-500 ${className}`} data-testid="all-in-note">{text}</p>
}
