import { useTranslation } from 'react-i18next'
import { allInPriceNoteKey } from '../utils/priceDisclosure'

const DEFAULT_PLATFORM = 'HåfaPass'

// "Sold by <organizer> · Tickets by HåfaPass". The organizer is the seller of
// the ticket; the platform sells as its agent and collects the service fee.
export function SellerLine({ seller, className = '' }) {
  const { t } = useTranslation()
  if (!seller?.seller_name) return null
  return (
    <p className={`text-xs leading-5 text-neutral-600 break-words ${className}`} data-testid="seller-line">
      {t('pricing.sellerLine', { seller: seller.seller_name, platform: seller.ticketing_service || DEFAULT_PLATFORM })}
    </p>
  )
}

// One plain sentence near the prices saying they are all-in and what the
// service fee pays for. Nothing renders for free-only events.
export function AllInPriceNote({ ticketTypes = [], includesProcessing = false, platform = DEFAULT_PLATFORM, className = '' }) {
  const { t } = useTranslation()
  const key = allInPriceNoteKey(ticketTypes, includesProcessing)
  if (!key) return null
  const text = t(key, { platform })
  return <p className={`text-xs leading-5 text-neutral-600 ${className}`} data-testid="all-in-note">{text}</p>
}
