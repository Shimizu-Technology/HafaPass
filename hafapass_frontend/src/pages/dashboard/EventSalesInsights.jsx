import { useState } from 'react'
import BarList from '../../components/charts/BarList'
import DailyColumnChart from '../../components/charts/DailyColumnChart'
import { formatDay } from '../../components/charts/chartScale'
import { formatMoneyCents } from '../../utils/money'

const CHANNEL_LABELS = { online: 'Online', box_office: 'Box office', guest_list: 'Guest list' }
const plural = (count, word) => `${count} ${word}${count === 1 ? '' : 's'}`

function Card({ id, title, description, children }) {
  return (
    <section aria-labelledby={id} className="min-w-0 rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6">
      <h2 id={id} className="text-lg font-semibold text-neutral-900">{title}</h2>
      {description && <p className="mt-1 text-sm text-neutral-600">{description}</p>}
      <div className="mt-4">{children}</div>
    </section>
  )
}

function DailySales({ days, timezone, currency }) {
  const [metric, setMetric] = useState('tickets')
  const money = cents => formatMoneyCents(cents, currency)
  const series = days.map(day => ({ date: day.date, value: metric === 'tickets' ? day.tickets : day.amount_cents }))
  const options = [['tickets', 'Tickets'], ['amount', 'Amount charged']]
  return (
    <Card id="sales-over-time-heading" title="Sales over time" description={`Each day runs midnight to midnight in the event's timezone (${timezone || 'event timezone'}). Tickets and amounts count on the day they were bought, before any later refunds or cancellations.`}>
      {days.length === 0 ? (
        <p className="rounded-xl bg-neutral-50 px-4 py-6 text-center text-sm text-neutral-600">No sales yet. Daily sales appear here after the first order.</p>
      ) : (
        <>
          <div role="group" aria-label="Chart measure" className="mb-4 inline-flex rounded-xl border border-neutral-200 bg-neutral-50 p-1">
            {options.map(([value, text]) => (
              <button key={value} type="button" aria-pressed={metric === value} onClick={() => setMetric(value)}
                className={`min-h-10 rounded-lg px-3 text-sm font-medium transition-[background-color,color,box-shadow] duration-150 ease-out-strong focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus ${metric === value ? 'bg-white text-neutral-950 shadow-soft' : 'text-neutral-600 hover:text-neutral-900'}`}>
                {text}
              </button>
            ))}
          </div>
          <DailyColumnChart
            days={series}
            label={metric === 'tickets' ? 'Tickets sold per day' : 'Amount charged per day'}
            integer={metric === 'tickets'}
            unitLabel={metric === 'tickets' ? 'tickets' : undefined}
            formatValue={metric === 'tickets' ? String : money}
          />
          <details className="group mt-3 text-sm">
            <summary className="inline-flex min-h-11 cursor-pointer items-center font-semibold text-brand-700 hover:text-brand-900">View as table</summary>
            <div className="mt-2 max-h-80 overflow-auto rounded-xl border border-neutral-200">
              <table className="w-full text-sm">
                <caption className="sr-only">Daily sales</caption>
                <thead className="sticky top-0 bg-neutral-50 text-xs text-neutral-600">
                  <tr><th scope="col" className="px-3 py-2 text-left font-medium">Day</th><th scope="col" className="px-3 py-2 text-right font-medium">Orders</th><th scope="col" className="px-3 py-2 text-right font-medium">Tickets</th><th scope="col" className="px-3 py-2 text-right font-medium">Amount charged</th></tr>
                </thead>
                <tbody className="divide-y divide-neutral-100 tabular-nums">
                  {days.map(day => (
                    <tr key={day.date}><th scope="row" className="px-3 py-2 text-left font-normal text-neutral-900">{formatDay(day.date, { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' })}</th><td className="px-3 py-2 text-right">{day.orders}</td><td className="px-3 py-2 text-right">{day.tickets}</td><td className="px-3 py-2 text-right">{money(day.amount_cents)}</td></tr>
                  ))}
                </tbody>
              </table>
            </div>
          </details>
        </>
      )}
    </Card>
  )
}

function Traffic({ traffic, acquisitionSources }) {
  const conversion = traffic.conversion || {}
  const sources = (traffic.sources || []).map(source => ({
    key: `${source.source}/${source.medium}`,
    label: source.medium && source.medium !== 'none' ? `${source.source} / ${source.medium}` : source.source,
    value: source.visitors,
    detail: plural(source.orders, 'order'),
  }))
  const tiles = [
    ['Visitors', traffic.visitors],
    ['Started checkout', traffic.checkout_visitors],
    ['Bought tickets', traffic.purchasers],
  ]
  return (
    <Card id="traffic-heading" title="Traffic and sources" description="Anonymous visitor counts from the event page and checkout, and orders credited to each link or campaign. No buyer identity is shown here.">
      <dl className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        {tiles.map(([label, value]) => (
          <div key={label} className="rounded-xl bg-neutral-50 p-3"><dt className="text-xs text-neutral-600">{label}</dt><dd className="mt-1 text-xl font-bold text-neutral-950">{value ?? 0}</dd></div>
        ))}
        <div className="rounded-xl bg-neutral-50 p-3">
          <dt className="text-xs text-neutral-600">Conversion (estimate)</dt>
          {conversion.sufficient_data && Number.isFinite(conversion.rate)
            ? <dd className="mt-1 text-xl font-bold text-neutral-950">{(conversion.rate * 100).toFixed(1)}%</dd>
            : <dd className="mt-1 text-sm text-neutral-700">Needs {conversion.minimum_visitors || 25}+ visitors</dd>}
        </div>
      </dl>
      <p className="mt-3 text-xs text-neutral-600">Conversion is visitors who bought divided by visitors who viewed the event. It is an estimate: private browsing, blocked scripts and shared devices make visitor counts approximate, and door sales are not included.</p>
      <h3 className="mt-5 text-sm font-semibold text-neutral-900">Visitors by source</h3>
      <div className="mt-3">
        <BarList rows={sources} label="Visitors by source" emptyText="No visits recorded yet. Share links with campaign tags to see where buyers come from." />
      </div>
      {acquisitionSources?.length > 0 && (
        <details className="mt-4 text-sm">
          <summary className="inline-flex min-h-11 cursor-pointer items-center font-semibold text-brand-700 hover:text-brand-900">Orders by campaign</summary>
          <div className="mt-2 divide-y divide-neutral-100 rounded-xl border border-neutral-200">
            {acquisitionSources.map(source => (
              <div key={`${source.source}/${source.medium}/${source.campaign}`} className="flex items-center justify-between gap-3 px-4 py-3">
                <span className="min-w-0 break-words">{source.source} / {source.medium}{source.campaign ? ` / ${source.campaign}` : ''}</span>
                <strong className="shrink-0">{plural(source.orders, 'order')}</strong>
              </div>
            ))}
          </div>
        </details>
      )}
    </Card>
  )
}

// Sales analytics for one event: daily sales, ticket types, channels and
// traffic. Older API responses without these fields render empty states.
export default function EventSalesInsights({ stats, currency = 'USD' }) {
  const money = cents => formatMoneyCents(cents, currency)
  const ticketTypes = (stats.tickets_by_type || []).map((type, index) => ({
    key: `${index}:${type.name}`, label: type.name, value: type.sold, detail: money(type.revenue_cents),
  }))
  const channels = (stats.sales_by_channel || []).map(channel => ({
    key: channel.channel, label: CHANNEL_LABELS[channel.channel] || channel.channel, value: channel.tickets,
    detail: `${money(channel.amount_cents)} · ${plural(channel.orders, 'order')}`,
  }))
  return (
    <div className="mb-8 grid min-w-0 gap-6">
      <DailySales days={stats.sales_by_day || []} timezone={stats.timezone} currency={currency} />
      <div className="grid min-w-0 gap-6 lg:grid-cols-2">
        <Card id="ticket-type-sales-heading" title="Sales by ticket type" description="Tickets still valid, with revenue after refunds.">
          <BarList rows={ticketTypes} label="Tickets sold by ticket type" emptyText="No tickets sold yet." />
        </Card>
        <Card id="channel-sales-heading" title="Sales by channel" description="Online checkout, door sales and guest list tickets. Amounts are after refunds.">
          <BarList rows={channels} label="Tickets by sales channel" emptyText="No tickets sold yet." />
        </Card>
      </div>
      <Traffic traffic={stats.traffic || {}} acquisitionSources={stats.acquisition_sources} />
    </div>
  )
}
