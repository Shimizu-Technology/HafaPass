import { Link } from 'react-router-dom'
import { ArrowRight, Calendar, Download, MapPin } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import Ticket from './Ticket'
import PendingTransfer from './PendingTransfer'
import useTranslatedContent from '../hooks/useTranslatedContent'
import MachineTranslationNotice from './MachineTranslationNotice'
import { formatEventDate, formatEventTime } from '../utils/eventTime'

export default function BuyerTicketPass({ event, ticket, isPast, status, canTransfer, onTransfer, onCancelTransfer, onTransferSettled }) {
  const { t } = useTranslation()
  const content = useTranslatedContent(event)
  const href = `/tickets/${encodeURIComponent(ticket.display_credential)}`
  return <Ticket stub={<div className="px-5 py-3 sm:px-6">
    <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1">
      <div className="flex flex-wrap items-center gap-2">
        {status}
        {isPast && <span className="rounded-full bg-neutral-100 px-2.5 py-1 text-xs font-medium text-neutral-700">{t('buyerAccount.myTicketsPage.past')}</span>}
      </div>
      <div className="flex flex-wrap items-center gap-1">
        {canTransfer && <button type="button" onClick={onTransfer} className="ticket-link inline-flex min-h-11 items-center rounded-lg px-2 text-sm font-semibold text-brand-800">{t('buyerAccount.myTicketsPage.transfer')}</button>}
        <Link to={href} aria-label={`${t('buyerAccount.myTicketsPage.openTicketToDownload')} #${ticket.id}`} title={t('buyerAccount.myTicketsPage.openTicketToDownload')} className="ticket-link inline-flex min-h-11 min-w-11 items-center justify-center rounded-lg text-brand-800"><Download aria-hidden="true" className="h-4 w-4" /></Link>
        <Link to={href} aria-label={`${t('pass.buyer.openTicket')}: ${ticket.ticket_type.name}, #${ticket.id}`} className="ticket-link inline-flex min-h-11 items-center gap-2 rounded-lg px-2 text-sm font-semibold text-brand-800">{t('pass.buyer.openTicket')}<ArrowRight aria-hidden="true" className="h-4 w-4 shrink-0" /></Link>
      </div>
    </div>
    {ticket.admission_allowed !== true && ticket.admission_block_reason && <p className="mt-2 text-sm text-amber-900">{ticket.admission_block_reason}</p>}
    {ticket.status === 'issued' && ticket.pending_transfer && <PendingTransfer transfer={ticket.pending_transfer} timeZone={event.timezone} onCancel={onCancelTransfer} onSettled={onTransferSettled} />}
  </div>}>
    <div className="px-5 py-5 sm:px-6">
      <h2 className="font-display text-xl font-bold leading-snug text-neutral-950"><Link to={`/events/${event.slug}`} className="ticket-link inline-flex min-h-11 items-center rounded-lg">{content.title}</Link></h2>
      <MachineTranslationNotice {...content.notice} />
      <p className="mt-2 flex items-start gap-2 text-sm leading-relaxed text-neutral-600"><Calendar aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" /><span>{formatEventDate(event.starts_at, event.timezone, { weekday: 'short' })} · {formatEventTime(event.starts_at, event.timezone)}</span></p>
      {event.venue_name && <p className="mt-1 flex items-start gap-2 text-sm leading-relaxed text-neutral-600"><MapPin aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" /><span>{event.venue_name}</span></p>}
      <Link to={href} className="ticket-link mt-3 inline-flex min-h-11 flex-col justify-center rounded-lg text-sm text-neutral-700">
        <span className="font-semibold text-neutral-950">{ticket.ticket_type.name}</span>
        {ticket.seat && <span className="font-semibold text-brand-800">{ticket.seat.display_label}</span>}
        {ticket.attendee_name && <span>{ticket.attendee_name}</span>}
      </Link>
    </div>
  </Ticket>
}
