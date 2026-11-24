import { useCallback, useEffect, useRef, useState } from 'react'
import { ExternalLink, Mail, QrCode, RefreshCw } from 'lucide-react'
import { QRCodeSVG } from 'qrcode.react'
import { useTranslation } from 'react-i18next'
import QRCode from '../../components/QRCode'
import { formatPlatformDateTime } from '../../utils/eventTime'
import { formatMoneyCents } from '../../utils/money'

const buttons = 'btn-secondary min-h-12 justify-center gap-2'
const activeEmail = ['queued', 'sent', 'delivered', 'delayed']

export default function BoxOfficeCardSale({ path, initial, requestApi, current, retrySetup, onPaid, onNext, recovery = false }) {
  const { t } = useTranslation()
  const [sale, setSale] = useState(initial)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [selectedTicket, setSelectedTicket] = useState(0)
  const refreshInFlight = useRef(false)
  const actionInFlight = useRef(false)
  const generation = useRef(0)
  const heading = useRef(null)
  const loaded = Boolean(sale)
  const paidRefreshed = useRef(false)

  const update = useCallback(async (action = 'refresh', quiet = false) => {
    const refreshing = action === 'refresh'
    if (!current() || actionInFlight.current || (refreshing && refreshInFlight.current)) return
    const inFlight = refreshing ? refreshInFlight : actionInFlight
    inFlight.current = true
    const version = ++generation.current
    const canApply = () => version === generation.current && current()
    if (!quiet) setBusy(true)
    setError('')
    try {
      if (action === 'setup') {
        const data = await retrySetup()
        if (canApply()) setSale(data)
      } else if (action === 'email') {
        const { data } = await requestApi('post', `${path}/email`, {})
        if (canApply()) setSale(previous => ({ ...previous, ...data }))
      } else {
        const { data } = await requestApi(action === 'cancel' ? 'delete' : 'get', path)
        if (canApply()) setSale(data)
      }
    } catch (problem) {
      if (!canApply()) return
      if ([403, 404].includes(problem.response?.status)) setSale(null)
      setError(problem.response?.data?.error || t('boxOfficeCard.connectionError'))
    } finally {
      inFlight.current = false
      if (canApply() && !quiet) setBusy(false)
    }
  }, [current, path, requestApi, retrySetup, t])

  useEffect(() => {
    if (!loaded) return
    heading.current?.focus({ preventScroll: true })
  }, [loaded])

  useEffect(() => {
    if (sale?.status) heading.current?.scrollIntoView?.({ block: 'start' })
  }, [sale?.status])

  useEffect(() => {
    if (initial) return
    update()
  }, [initial, update])

  useEffect(() => {
    if (sale?.status === 'paid' && !paidRefreshed.current) {
      paidRefreshed.current = true
      onPaid()
    }
  }, [onPaid, sale?.status])

  useEffect(() => {
    if (sale && !sale.pending) return
    const refreshIfVisible = () => { if (!document.hidden) update('refresh', true) }
    const timer = window.setInterval(refreshIfVisible, 4000)
    document.addEventListener('visibilitychange', refreshIfVisible)
    return () => {
      window.clearInterval(timer)
      document.removeEventListener('visibilitychange', refreshIfVisible)
    }
  }, [sale, update])

  if (!sale) {
    return <section className="rounded-xl border border-neutral-200 bg-white p-4">
      {error
        ? <p role="alert" className="text-sm text-red-800">{error}</p>
        : <p role="status">{t('boxOfficeCard.loading')}</p>}
      {recovery && <button type="button" className={`${buttons} mt-3`} onClick={onNext}>{t('boxOfficeCard.closeRecovery')}</button>}
      {error && <button type="button" className={`${buttons} mt-3`} disabled={busy} onClick={() => update()}>
        {t('boxOfficeCard.refresh')}
      </button>}
    </section>
  }

  const buyerPhone = sale.payment_method === 'door_card_link'
  const ticket = sale.tickets?.[selectedTicket]
  const titleKey = sale.status === 'paid' && !ticket ? 'paidUnavailable' : sale.status

  return (
    <section className="space-y-4 rounded-xl border border-neutral-200 bg-white p-4 sm:p-6" aria-labelledby="door-checkout-status">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="text-sm font-semibold text-neutral-600">{t(buyerPhone ? 'boxOfficeCard.link' : 'boxOfficeCard.keyed')}</p>
          <h3 ref={heading} tabIndex={-1} id="door-checkout-status" aria-live="polite"
            className="mt-1 scroll-mt-28 text-xl font-bold text-neutral-950">
            {t(`boxOfficeCard.state.${titleKey}`)}
          </h3>
          <p className="mt-1 text-sm text-neutral-600">{sale.reference}</p>
        </div>
        <p className="text-xl font-semibold text-neutral-950">{formatMoneyCents(sale.total_cents)}</p>
      </div>

      {sale.pending && <>
        {sale.status === 'failed' && <p className="rounded-lg bg-amber-50 p-3 text-sm text-amber-950">
          {t('boxOfficeCard.declined')}
        </p>}
        {sale.checkout_url && (buyerPhone ? (
          <div className="space-y-2 rounded-xl bg-neutral-50 p-4 text-center">
            <p className="font-semibold text-neutral-950">{t('boxOfficeCard.scanToPay')}</p>
            <div className="flex justify-center">
              <QRCodeSVG value={sale.checkout_url} size={230} marginSize={4} level="M" title={t('boxOfficeCard.qrLabel')}
                role="img" aria-label={t('boxOfficeCard.qrLabel')} className="h-auto max-w-full rounded-lg" />
            </div>
            <p className="text-sm text-neutral-600">{t('boxOfficeCard.buyerScan')}</p>
          </div>
        ) : (
          <div className="space-y-3">
            <p className="text-sm text-neutral-700">{t('boxOfficeCard.keyedHelp')}</p>
            <a href={sale.checkout_url} target="_blank" rel="noopener noreferrer" className="btn-primary min-h-12 gap-2">
              {t('boxOfficeCard.openStripe')} <ExternalLink aria-hidden="true" className="h-4 w-4" />
            </a>
          </div>
        ))}
        {sale.can_retry_setup && retrySetup && <button type="button" className={buttons} disabled={busy} onClick={() => update('setup')}>
          {t('boxOfficeCard.retrySetup')}
        </button>}
        {sale.expires_at && <p className="text-sm text-neutral-600">{t('boxOfficeCard.expiresAt', { time: formatPlatformDateTime(sale.expires_at) })}</p>}
        {sale.checkout_url && sale.can_email_link && (activeEmail.includes(sale.link_email_status) ? (
          <p role="status" className="text-sm text-neutral-700">{t('boxOfficeCard.emailQueued')}</p>
        ) : (
          <button type="button" className={buttons} disabled={busy} onClick={() => update('email')}>
            <Mail aria-hidden="true" className="h-4 w-4" /> {t('boxOfficeCard.emailLink')}
          </button>
        ))}
      </>}

      {sale.status === 'paid' && sale.can_email_tickets && (
        activeEmail.includes(sale.ticket_email_status)
          ? <p role="status" className="text-sm text-neutral-700">{t('boxOfficeCard.ticketEmailQueued')}</p>
          : <button type="button" className={buttons} disabled={busy} onClick={() => update('email')}>
            <Mail aria-hidden="true" className="h-4 w-4" /> {t('boxOfficeCard.emailTickets')}
          </button>
      )}
      {sale.status === 'expired' && <p className="text-sm text-neutral-700">{t('boxOfficeCard.expiredHelp')}</p>}
      {ticket && <div className="space-y-2 rounded-xl border border-neutral-200 p-4 text-center">
        <p className="break-words font-semibold [overflow-wrap:anywhere]">{ticket.tier}</p>
        <p className="break-words text-sm text-neutral-600 [overflow-wrap:anywhere]">{ticket.event}</p>
        <div className="flex justify-center"><QRCode value={ticket.scan_credential} size={220} className="h-auto max-w-full" /></div>
        <p className="text-sm">{t('boxOfficeCard.ticketPosition', { number: selectedTicket + 1, total: sale.tickets.length })}</p>
        {sale.tickets.length > 1 && <div className="grid grid-cols-2 gap-2">
          <button type="button" className={buttons} disabled={selectedTicket === 0} onClick={() => setSelectedTicket(index => index - 1)}>
            {t('boxOfficeCard.previous')}
          </button>
          <button type="button" className={buttons} disabled={selectedTicket === sale.tickets.length - 1} onClick={() => setSelectedTicket(index => index + 1)}>
            {t('boxOfficeCard.next')}
          </button>
        </div>}
      </div>}

      {error && <p role="alert" className="break-words text-sm text-red-800">{error}</p>}
      <div className="flex flex-wrap gap-2">
        {sale.pending ? <>
          <button type="button" className={buttons} disabled={busy} onClick={() => update()}>
            <RefreshCw aria-hidden="true" className="h-4 w-4" /> {t('boxOfficeCard.refresh')}
          </button>
          <button type="button" className={buttons} disabled={busy} onClick={() => update('cancel')}>
            {t('boxOfficeCard.cancel')}
          </button>
        </> : (
          <button type="button" className="btn-primary min-h-12 gap-2" onClick={onNext}>
            <QrCode aria-hidden="true" className="h-4 w-4" /> {t(recovery ? 'boxOfficeCard.closeRecovery' : 'boxOfficeCard.nextSale')}
          </button>
        )}
        {sale.status === 'expired' && <button type="button" className={buttons} disabled={busy} onClick={() => update()}>
          <RefreshCw aria-hidden="true" className="h-4 w-4" /> {t('boxOfficeCard.refresh')}
        </button>}
        {recovery && sale.pending && <button type="button" className={buttons} onClick={onNext}>
          {t('boxOfficeCard.closeRecovery')}
        </button>}
      </div>
    </section>
  )
}
