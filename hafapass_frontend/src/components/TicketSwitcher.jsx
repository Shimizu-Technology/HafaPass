import { useLayoutEffect, useRef } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ChevronLeft, ChevronRight } from 'lucide-react'

// Previous/next for a group of tickets: one on screen at a time, so a buyer
// showing four QR codes at the door always knows which one is up.
// `previous` and `next` are { to } links or { onClick } buttons; null at either end.
// Keyboard focus stays on the switcher after paging: on the control used, or on
// the other one when the end of the group disables it. Links remount the
// ticket, so the parent keeps the pending move in `focusRequest` across it.
export default function TicketSwitcher({ position, total, name, previous, next, tone = 'light', label, focusRequest }) {
  const { t } = useTranslation()
  const ownRequest = useRef(null)
  const request = focusRequest || ownRequest
  const controls = { previous: useRef(null), next: useRef(null) }
  useLayoutEffect(() => {
    const side = request.current
    if (!side) return
    request.current = null
    const wanted = controls[side].current
    const target = wanted && !wanted.disabled ? wanted : controls[side === 'next' ? 'previous' : 'next'].current
    if (target && !target.disabled) target.focus()
  })
  const summary = name
    ? t('buyerAccount.ticketPage.ticketPositionNamed', { position, total, name })
    : t('buyerAccount.ticketPage.ticketPosition', { position, total })
  const dark = tone === 'dark'
  const control = `inline-flex min-h-12 min-w-12 shrink-0 items-center justify-center gap-1 rounded-xl border-2 px-3 text-base font-semibold focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 ${dark
    ? 'border-white/70 text-white focus-visible:ring-focus-on-dark focus-visible:ring-offset-brand-950'
    : 'border-brand-700 bg-white text-brand-900 focus-visible:ring-focus'}`
  const disabled = `${control} ${dark ? '!border-white/25 !text-white/50' : '!border-neutral-200 !text-neutral-500'}`
  const render = (side, target, text, icon) => {
    const content = side === 'previous' ? <>{icon}<span className="sr-only sm:not-sr-only">{text}</span></> : <><span className="sr-only sm:not-sr-only">{text}</span>{icon}</>
    const ref = controls[side]
    if (!target) return <button ref={ref} type="button" disabled aria-label={text} className={disabled}>{content}</button>
    const activate = () => { request.current = side; target.onClick?.() }
    if (target.to) return <Link ref={ref} to={target.to} onClick={activate} aria-label={text} className={control}>{content}</Link>
    return <button ref={ref} type="button" onClick={activate} aria-label={text} className={control}>{content}</button>
  }
  return (
    <nav aria-label={label || t('buyerAccount.ticketPage.ticketsInOrder')} className="flex items-center gap-3">
      {render('previous', previous, t('buyerAccount.ticketPage.previousTicket'), <ChevronLeft aria-hidden="true" className="h-5 w-5" />)}
      <p aria-live="polite" className={`min-w-0 flex-1 text-center text-base font-bold leading-snug [overflow-wrap:anywhere] ${dark ? 'text-white' : 'text-neutral-950'}`}>{summary}</p>
      {render('next', next, t('buyerAccount.ticketPage.nextTicket'), <ChevronRight aria-hidden="true" className="h-5 w-5" />)}
    </nav>
  )
}
