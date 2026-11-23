import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ChevronLeft, ChevronRight } from 'lucide-react'

// Previous/next for a group order: one ticket on screen at a time, so a buyer
// showing four QR codes at the door always knows which one is up.
// `previous` and `next` are { to } links or { onClick } buttons; null at either end.
export default function TicketSwitcher({ position, total, name, previous, next, tone = 'light' }) {
  const { t } = useTranslation()
  const label = name
    ? t('buyerAccount.ticketPage.ticketPositionNamed', { position, total, name })
    : t('buyerAccount.ticketPage.ticketPosition', { position, total })
  const dark = tone === 'dark'
  const control = `inline-flex min-h-12 min-w-12 shrink-0 items-center justify-center gap-1 rounded-xl border-2 px-3 text-base font-semibold focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 ${dark
    ? 'border-white/70 text-white focus-visible:ring-focus-on-dark focus-visible:ring-offset-brand-950'
    : 'border-brand-700 bg-white text-brand-900 focus-visible:ring-focus'}`
  const disabled = `${control} ${dark ? '!border-white/25 !text-white/50' : '!border-neutral-200 !text-neutral-500'}`
  const render = (target, text, icon, side) => {
    const content = side === 'prev' ? <>{icon}<span className="sr-only sm:not-sr-only">{text}</span></> : <><span className="sr-only sm:not-sr-only">{text}</span>{icon}</>
    if (!target) return <button type="button" disabled aria-label={text} className={disabled}>{content}</button>
    if (target.to) return <Link to={target.to} replace aria-label={text} className={control}>{content}</Link>
    return <button type="button" onClick={target.onClick} aria-label={text} className={control}>{content}</button>
  }
  return (
    <nav aria-label={t('buyerAccount.ticketPage.ticketsInOrder')} className="flex items-center gap-3">
      {render(previous, t('buyerAccount.ticketPage.previousTicket'), <ChevronLeft aria-hidden="true" className="h-5 w-5" />, 'prev')}
      <p aria-live="polite" className={`min-w-0 flex-1 text-center text-base font-bold leading-snug [overflow-wrap:anywhere] ${dark ? 'text-white' : 'text-neutral-950'}`}>{label}</p>
      {render(next, t('buyerAccount.ticketPage.nextTicket'), <ChevronRight aria-hidden="true" className="h-5 w-5" />, 'next')}
    </nav>
  )
}
