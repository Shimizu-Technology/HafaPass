import { useCallback, useEffect, useState } from 'react'
import { AlertTriangle, Loader2, Mail, Search, Send, ShieldCheck } from 'lucide-react'
import apiClient from '../../api/client'

const badge = {
  delivered: 'bg-emerald-100 text-emerald-800',
  sent: 'bg-blue-100 text-blue-800',
  queued: 'bg-neutral-100 text-neutral-700',
  delayed: 'bg-amber-100 text-amber-800',
  failed: 'bg-red-100 text-red-800',
  bounced: 'bg-red-100 text-red-800',
  complained: 'bg-purple-100 text-purple-800',
  suppressed: 'bg-neutral-800 text-white',
}

export default function SupportPage() {
  const [query, setQuery] = useState('')
  const [results, setResults] = useState({ orders: [], tickets: [], events: [] })
  const [deliveries, setDeliveries] = useState([])
  const [loading, setLoading] = useState(false)
  const [message, setMessage] = useState('')

  const loadDeliveries = useCallback(() => {
    apiClient.get('/support/message_deliveries').then(response => setDeliveries(response.data.deliveries))
  }, [])

  useEffect(() => { loadDeliveries() }, [loadDeliveries])

  const search = async (event) => {
    event.preventDefault()
    if (query.trim().length < 3) return
    setLoading(true)
    setMessage('')
    try {
      const response = await apiClient.get('/support/search', { params: { q: query.trim() } })
      setResults(response.data)
    } catch (error) {
      setMessage(error.response?.data?.error || 'Lookup failed')
    } finally {
      setLoading(false)
    }
  }

  const replay = async (delivery) => {
    setMessage('')
    try {
      await apiClient.post(`/support/message_deliveries/${delivery.id}/resend`)
      setMessage(`Delivery #${delivery.id} queued with its original idempotency key.`)
      loadDeliveries()
    } catch (error) {
      setMessage(error.response?.data?.error || 'Replay failed')
    }
  }

  const fulfill = async (order) => {
    setMessage('')
    try {
      await apiClient.post(`/support/message_deliveries/orders/${order.id}/fulfill`)
      setMessage(`A consolidated fulfillment message was queued for ${order.reference}.`)
      loadDeliveries()
    } catch (error) {
      setMessage(error.response?.data?.error || 'Fulfillment resend failed')
    }
  }

  return (
    <main className="min-h-screen bg-neutral-50 px-4 py-8">
      <div className="mx-auto max-w-7xl">
        <div className="flex items-center gap-3">
          <div className="grid h-11 w-11 place-items-center rounded-xl bg-brand-600 text-white"><ShieldCheck className="h-5 w-5" /></div>
          <div><h1 className="text-2xl font-bold text-neutral-950">Support console</h1><p className="text-sm text-neutral-500">Least-privilege lookup, delivery recovery, and audited actions</p></div>
        </div>

        <form onSubmit={search} className="mt-7 flex gap-2" role="search">
          <label htmlFor="support-query" className="sr-only">Order, ticket, attendee, or event lookup</label>
          <input id="support-query" value={query} onChange={event => setQuery(event.target.value)} className="input flex-1" placeholder="Order reference, buyer email, attendee, or event" />
          <button className="btn-primary inline-flex items-center gap-2" disabled={loading || query.trim().length < 3}>{loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <Search className="h-4 w-4" />} Search</button>
        </form>
        {message && <div className="mt-4 rounded-xl border border-brand-200 bg-brand-50 p-3 text-sm text-brand-900" role="status">{message}</div>}

        <section className="mt-8">
          <h2 className="text-lg font-semibold text-neutral-900">Order results</h2>
          <div className="mt-3 grid gap-3 md:grid-cols-2">
            {results.orders.map(order => (
              <article key={order.id} className="rounded-xl border border-neutral-200 bg-white p-4">
                <div className="flex items-start justify-between gap-3"><div><p className="font-mono text-xs text-neutral-500">{order.reference}</p><h3 className="font-semibold text-neutral-900">{order.event_title}</h3></div><span className="rounded-full bg-neutral-100 px-2 py-1 text-xs">{order.status}</span></div>
                <p className="mt-2 text-sm text-neutral-600">{order.buyer_name} · {order.buyer_email} · {order.ticket_count} tickets</p>
                <button onClick={() => fulfill(order)} className="mt-3 inline-flex items-center gap-2 text-sm font-medium text-brand-700"><Send className="h-4 w-4" /> Resend consolidated tickets</button>
              </article>
            ))}
          </div>
        </section>

        <section className="mt-10">
          <div className="flex items-center gap-2"><Mail className="h-5 w-5 text-brand-600" /><h2 className="text-lg font-semibold text-neutral-900">Recent message deliveries</h2></div>
          <div className="mt-3 overflow-x-auto rounded-xl border border-neutral-200 bg-white">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-neutral-200 bg-neutral-50 text-xs uppercase text-neutral-500"><tr><th className="px-4 py-3">Message</th><th className="px-4 py-3">Recipient</th><th className="px-4 py-3">State</th><th className="px-4 py-3">Attempts</th><th className="px-4 py-3">Action</th></tr></thead>
              <tbody className="divide-y divide-neutral-100">
                {deliveries.map(delivery => (
                  <tr key={delivery.id}><td className="px-4 py-3"><p className="font-medium text-neutral-900">{delivery.template.replaceAll('_', ' ')}</p><p className="text-xs text-neutral-500">#{delivery.id}{delivery.provider_id ? ` · ${delivery.provider_id}` : ''}</p></td><td className="px-4 py-3">{delivery.recipient}</td><td className="px-4 py-3"><span className={`rounded-full px-2 py-1 text-xs font-medium ${badge[delivery.status] || badge.queued}`}>{delivery.status}</span>{delivery.last_error && <p className="mt-1 max-w-xs text-xs text-red-700"><AlertTriangle className="mr-1 inline h-3 w-3" />{delivery.last_error}</p>}</td><td className="px-4 py-3">{delivery.attempts}</td><td className="px-4 py-3"><button disabled={delivery.status !== 'failed' || Boolean(delivery.provider_id)} onClick={() => replay(delivery)} className="text-sm font-medium text-brand-700 disabled:text-neutral-300">Replay safely</button></td></tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </main>
  )
}
