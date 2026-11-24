import { useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { formatMoneyCents } from '../../utils/money'

export default function OpenDoorCheckouts({ path, requestApi, onOpen }) {
  const { t } = useTranslation()
  const [expanded, setExpanded] = useState(false)
  const [orders, setOrders] = useState(null)
  const [failed, setFailed] = useState(false)
  const requestVersion = useRef(0)

  const load = async () => {
    const version = ++requestVersion.current
    setFailed(false)
    setOrders(null)
    try {
      const { data } = await requestApi('get', path)
      if (requestVersion.current === version) setOrders(data.orders)
    } catch {
      if (requestVersion.current === version) setFailed(true)
    }
  }

  return (
    <section className="rounded-xl border border-neutral-200 bg-white p-4">
      <button type="button" className="btn-secondary min-h-12" aria-expanded={expanded}
        aria-controls="open-door-checkouts" onClick={() => {
          if (!expanded) load()
          setExpanded(!expanded)
        }}>
        {t('boxOfficeCard.openCheckouts')}
      </button>
      {expanded && <div id="open-door-checkouts" className="mt-3">
        {failed ? <>
          <p role="alert">{t('boxOfficeCard.checkoutListError')}</p>
          <button type="button" className="btn-secondary mt-2 min-h-12" onClick={load}>{t('boxOfficeCard.refresh')}</button>
        </> : !orders ? <p role="status">{t('boxOfficeCard.loading')}</p>
          : orders.length === 0 ? <p>{t('boxOfficeCard.noCheckouts')}</p>
            : <ul className="divide-y divide-neutral-200">
              {orders.map(order => (
                <li key={order.id} className="flex flex-wrap items-center justify-between gap-2 py-3">
                  <div className="min-w-0 break-words [overflow-wrap:anywhere]">
                    <p className="font-medium">{order.buyer_name}</p>
                    <p className="text-sm text-neutral-600">{order.reference} · {formatMoneyCents(order.total_cents)}</p>
                    <p className="text-sm text-neutral-600">{t(`boxOfficeCard.state.${order.status}`)}</p>
                  </div>
                  <button type="button" className="btn-secondary min-h-12" onClick={() => onOpen(order.id)}>
                    {t(order.status === 'paid' ? 'boxOfficeCard.showTickets' :
                      order.payment_method === 'door_card_link' ? 'boxOfficeCard.showPaymentQr' : 'boxOfficeCard.openCheckout')}
                  </button>
                </li>
              ))}
            </ul>}
      </div>}
    </section>
  )
}
