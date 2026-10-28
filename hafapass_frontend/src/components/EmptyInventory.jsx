import { Ticket as TicketIcon, ArrowRight } from 'lucide-react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import Ticket from './Ticket'

// Only show after a successful, unfiltered inventory check. A failed request
// or an empty search result does not establish that the marketplace is empty.
export function HostingStub() {
  const { t } = useTranslation()
  return <div className="flex flex-wrap items-center justify-between gap-x-3 px-6 py-3 sm:px-8">
    <span className="text-sm text-content-muted">{t('pass.home.hosting')}</span>
    <Link to="/host" className="ticket-link inline-flex min-h-11 items-center gap-2 rounded-lg text-sm font-semibold text-brand-800">{t('pass.home.sellTickets')}<ArrowRight aria-hidden="true" className="h-4 w-4 shrink-0" /></Link>
  </div>
}

export default function EmptyInventory({ className = '', embedded = false }) {
  const { t } = useTranslation()
  const content = <>
      <TicketIcon aria-hidden="true" className="mb-4 h-8 w-8 text-brand-700" />
      <h2 className="max-w-sm font-display text-2xl font-bold leading-tight sm:text-3xl">{t('pass.home.firstEvents')}</h2>
      <p className="mt-3 max-w-sm leading-relaxed text-content-muted">{t('pass.home.checkBack')}</p>
  </>
  if (embedded) return content
  return <Ticket className={`text-content ${className}`} stub={<HostingStub />}>
    <div className="home-ticket-content home-ticket-empty px-6 py-6 sm:px-8 sm:py-7">{content}</div>
  </Ticket>
}
