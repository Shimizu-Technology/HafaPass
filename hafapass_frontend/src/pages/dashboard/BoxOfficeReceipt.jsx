import { useCallback, useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { useTranslation } from 'react-i18next'
import { CheckCircle2, Mail, Printer, QrCode, X } from 'lucide-react'
import QRCode from '../../components/QRCode'
import { formatEventDateTime } from '../../utils/eventTime'
import './boxOfficePrint.css'

const emailInProgress = ['queued', 'sent', 'delivered', 'delayed']
const actionClass = 'btn-secondary min-h-12 justify-center px-4'

export default function BoxOfficeReceipt({ eventId, order, requestApi, current }) {
  const { t } = useTranslation()
  const [receipt, setReceipt] = useState(order.receipt ?? null)
  const [loadError, setLoadError] = useState(false)
  const [email, setEmail] = useState(order.receipt?.email ?? '')
  const [emailOpen, setEmailOpen] = useState(false)
  const [emailError, setEmailError] = useState('')
  const [sending, setSending] = useState(false)
  const [printOpened, setPrintOpened] = useState(false)
  const [qrShown, setQrShown] = useState(false)
  const [activeTicket, setActiveTicket] = useState(0)
  const qrDialog = useRef(null)
  const heading = useRef(null)
  const orderPath = `/organizer/events/${eventId}/box_office/orders/${order.id}`

  const loadReceipt = useCallback(async () => {
    setLoadError(false)
    try {
      const { data } = await requestApi('get', orderPath)
      if (!current()) return
      setReceipt(data)
      setEmail(data.email || '')
    } catch {
      if (current()) setLoadError(true)
    }
  }, [current, orderPath, requestApi])

  useEffect(() => { if (!order.receipt) loadReceipt() }, [order.receipt, loadReceipt])
  useEffect(() => {
    heading.current?.focus({ preventScroll: true })
    heading.current?.scrollIntoView?.({ block: 'nearest' })
  }, [])

  const sendEmail = async event => {
    event.preventDefault()
    if (sending || !current()) return
    setSending(true)
    setEmailError('')
    try {
      const { data } = await requestApi('post', `${orderPath}/email`, { email: email.trim() })
      if (!current()) return
      setReceipt(previous => ({ ...previous, ...data }))
      setEmail(data.email)
      setEmailOpen(false)
    } catch (error) {
      if (current()) setEmailError(error.response?.data?.error || t('boxOfficeReceipt.emailError'))
    } finally {
      if (current()) setSending(false)
    }
  }

  const tickets = receipt?.admissions || []
  const ticket = tickets[activeTicket]
  const headingText = receipt && !['completed', 'partially_refunded'].includes(receipt.status)
    ? t('boxOfficeReceipt.orderUpdated')
    : t('boxOfficeReceipt.saleComplete')
  const emailRecorded = emailInProgress.includes(receipt?.email_status)

  return (
    <section className="mb-6 rounded-xl border border-emerald-200 bg-emerald-50 p-4 sm:p-5" aria-labelledby="box-office-receipt-title">
      <div className="flex items-center gap-2">
        <CheckCircle2 aria-hidden="true" className="h-5 w-5 shrink-0 text-emerald-700" />
        <h3 ref={heading} tabIndex={-1} id="box-office-receipt-title" className="font-semibold text-emerald-950">{headingText}</h3>
      </div>
      {loadError && <div className="mt-3">
        <p role="alert" className="text-sm text-red-800">{t('boxOfficeReceipt.loadError')}</p>
        <button type="button" className={`${actionClass} mt-2`} onClick={loadReceipt}>{t('boxOfficeReceipt.retry')}</button>
      </div>}
      {!loadError && !receipt && <p role="status" className="mt-2 text-sm">{t('boxOfficeReceipt.loading')}</p>}
      {receipt && <>
        <p className="mt-1 break-words text-sm text-emerald-950">
          {receipt.reference} · ${(receipt.total_cents / 100).toFixed(2)}
        </p>
        {tickets.length === 0 && <p className="mt-3 text-sm">{t('boxOfficeReceipt.noTickets')}</p>}
        <div className="mt-4 grid gap-2 sm:flex sm:flex-wrap">
          {tickets.length > 0 && <>
            <button type="button" className={actionClass} onClick={() => { setActiveTicket(0); setQrShown(true); qrDialog.current.showModal() }}>
              <QrCode aria-hidden="true" className="h-4 w-4" /> {t('boxOfficeReceipt.showQr')}
            </button>
            <button type="button" className={actionClass} onClick={() => { setPrintOpened(true); window.print() }}>
              <Printer aria-hidden="true" className="h-4 w-4" /> {t('boxOfficeReceipt.print')}
            </button>
          </>}
          {receipt.email_available && !emailRecorded && <button type="button" className={actionClass} aria-expanded={emailOpen}
            onClick={() => setEmailOpen(value => !value)}>
            <Mail aria-hidden="true" className="h-4 w-4" /> {t('boxOfficeReceipt.email')}
          </button>}
        </div>
        {qrShown && <p role="status" className="mt-2 text-sm text-emerald-950">{t('boxOfficeReceipt.qrShown')}</p>}
        {receipt.email_status === 'suppressed' && <p role="status" className="mt-2 text-sm text-amber-900">
          {t('boxOfficeReceipt.emailUnavailable')}
        </p>}
        {printOpened && <p role="status" className="mt-2 text-sm text-emerald-950">{t('boxOfficeReceipt.printOpened')}</p>}
        {emailRecorded && <p role="status" className="mt-2 break-all text-sm text-emerald-950">
          {t(`boxOfficeReceipt.delivery.${receipt.email_status}`, { email: receipt.email })}
        </p>}
        {emailOpen && <form className="mt-4 max-w-md" onSubmit={sendEmail}>
          <label htmlFor="box-office-receipt-email" className="mb-1 block text-sm font-semibold">{t('boxOfficeReceipt.buyerEmail')}</label>
          <input type="email" required maxLength={254} id="box-office-receipt-email" value={email}
            readOnly={Boolean(receipt.email)} onChange={event => setEmail(event.target.value)}
            className="min-h-12 w-full rounded-lg border border-neutral-300 bg-white px-3 text-base" />
          {emailError && <p role="alert" className="mt-2 text-sm text-red-800">{emailError}</p>}
          <button type="submit" disabled={sending} className="btn-primary mt-3 min-h-12">
            {t(sending ? 'boxOfficeReceipt.queueing' : 'boxOfficeReceipt.queue')}
          </button>
        </form>}
      </>}
      {tickets.length > 0 && <>
        <dialog ref={qrDialog} className="fixed inset-0 m-0 h-dvh max-h-none w-screen max-w-none overflow-y-auto bg-white p-4 text-neutral-950 sm:p-8"
          aria-label={t('boxOfficeReceipt.showQr')}>
          <div className="mx-auto flex min-h-full max-w-md flex-col items-center">
            <button type="button" className={`${actionClass} self-end`} onClick={() => qrDialog.current.close()}>
              <X aria-hidden="true" className="h-4 w-4" /> {t('boxOfficeReceipt.close')}
            </button>
            <div className="my-auto w-full py-4 text-center">
              <p aria-live="polite" className="mb-3 text-sm font-semibold">
                {t('boxOfficeReceipt.ticketPosition', { number: activeTicket + 1, total: tickets.length })}
              </p>
              {ticket && <TicketDetails ticket={ticket} receipt={receipt} t={t} />}
            </div>
            {tickets.length > 1 && <div className="grid w-full grid-cols-2 gap-2">
              <button type="button" className={actionClass} disabled={activeTicket === 0}
                onClick={() => setActiveTicket(index => index - 1)}>{t('boxOfficeReceipt.previous')}</button>
              <button type="button" className={actionClass} disabled={activeTicket === tickets.length - 1}
                onClick={() => setActiveTicket(index => index + 1)}>{t('boxOfficeReceipt.next')}</button>
            </div>}
          </div>
        </dialog>
        {createPortal(
          <div className="box-office-print" aria-hidden="true">
            {tickets.map(admission => <article className="box-office-print-ticket" key={admission.id}>
              <TicketDetails ticket={admission} receipt={receipt} t={t} />
            </article>)}
          </div>,
          document.body,
        )}
      </>}
    </section>
  )
}

function TicketDetails({ ticket, receipt, t }) {
  const { event } = ticket
  return (
    <div className="space-y-1 break-words [overflow-wrap:anywhere]">
      <h4 className="text-xl font-bold">{receipt.event_title}</h4>
      {ticket.pass_night && <p className="font-semibold">{event.title}</p>}
      <p>{formatEventDateTime(event.starts_at, event.timezone || 'Pacific/Guam', { locale: 'en-US' })}</p>
      <p>{[event.venue_name, event.venue_address].filter(Boolean).join(' · ')}</p>
      <p className="font-semibold">{[ticket.tier, ticket.seat].filter(Boolean).join(' · ')}</p>
      {ticket.attendee_name && <p>{ticket.attendee_name}</p>}
      <div className="flex justify-center py-3"><QRCode value={ticket.scan_credential} size={256} className="h-auto max-w-full" /></div>
      <p className="text-sm">{t('boxOfficeReceipt.ticketReference', { reference: receipt.reference, id: ticket.id })}</p>
    </div>
  )
}
