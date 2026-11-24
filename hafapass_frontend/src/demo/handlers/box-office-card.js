import { json, notFound, unprocessable } from './respond'
import { boxOfficeSummary } from '../staff/responses'

const methods = ['door_card_link', 'door_card_keyed']
const demoSaleDelay = 6000
const eventPath = '/organizer/events/101'

function stateFor(sale) {
  if (sale.status === 'waiting' && Date.now() >= sale.paidAt) return 'paid'
  return sale.status
}

function view(sale, event) {
  const status = stateFor(sale)
  const pending = status === 'waiting'
  return {
    id: sale.id,
    reference: `DEMO-DOOR-CARD-${sale.id}`,
    buyer_name: sale.buyerName,
    payment_method: sale.method,
    status,
    pending,
    total_cents: sale.total,
    expires_at: pending ? sale.expiresAt : null,
    checkout_url: pending ? `${window.location.origin}/door-payment?result=finished&demo=1` : null,
    can_email_link: sale.canEmail && sale.method === 'door_card_link',
    can_email_tickets: sale.canEmail,
    ticket_email_status: sale.ticketEmailStatus,
    link_email_status: sale.emailStatus,
    tickets: status === 'paid' ? sale.tiers.map((tier, index) => ({
      id: sale.id * 1000 + index,
      scan_credential: `fictional-door-card-admission-${sale.id}-${index}`,
      tier,
      event: event.title,
    })) : [],
  }
}

export async function handle({ method, path, body, config, params, state }) {
  if (path !== eventPath && !path.startsWith(`${eventPath}/`)) return undefined
  const event = state.staff.events.find(item => item.id === 101)
  if (!event) return undefined
  if (method === 'get' && path === eventPath) {
    event.online_door_card_enabled = true
    for (const type of event.ticket_types) {
      const price = type.current_price_cents ?? type.price_cents
      type.service_fee_cents = price > 0 ? Math.round(price * 0.05) + 60 : 0
    }
    return undefined // Preserve the staff event response and any other feature fields.
  }

  const demo = state.boxOfficeCard ||= {
    attempts: new Map(),
    sales: new Map([
      [789998, { id: 789998, status: 'waiting', method: 'door_card_link', buyerName: 'Buyer · Lantern demo',
        paidAt: Infinity, stripePaid: true, expiresAt: new Date(Date.now() + 35 * 60_000).toISOString(),
        total: 1323, canEmail: true, tiers: ['Admission'] }],
      [789999, { id: 789999, status: 'paid', method: 'door_card_keyed', buyerName: 'Buyer · Reef demo',
        total: 1323, canEmail: true, tiers: ['Admission'] }],
    ]),
  }
  if (method === 'get' && path === `${eventPath}/box_office/summary`) {
    const summary = boxOfficeSummary(state.staff)
    for (const sale of demo.sales.values()) {
      if (stateFor(sale) !== 'paid') continue
      summary.total_orders += 1
      summary.total_tickets += sale.tiers.length
      summary.total_revenue_cents += sale.total
      summary.by_payment_method[sale.method] = (summary.by_payment_method[sale.method] || 0) + sale.total
    }
    return json(summary)
  }

  const match = path.match(/^\/organizer\/events\/101\/box_office_card_sales(?:\/(\d+)(\/email)?)?$/)
  if (!match) return undefined
  const [, id, emailAction] = match

  if (method === 'get' && !id) {
    return json({ orders: [...demo.sales.values()].map(sale => view(sale, event))
      .filter(sale => sale.status === 'waiting' || sale.status === 'paid')
      .map(({ id, reference, buyer_name, status, payment_method, total_cents }) => ({
        id, reference, buyer_name, status, payment_method, total_cents,
      })) })
  }

  if (method === 'post' && !id) {
    if (!methods.includes(body.payment_method)) return unprocessable('Choose a demo payment method.')
    const key = config.headers?.get?.('Idempotency-Key')
    if (key && demo.attempts.has(key)) return json(view(demo.attempts.get(key), event))
    const sale = {
      id: 790000 + demo.sales.size,
      method: body.payment_method,
      status: 'waiting',
      expiresAt: new Date(Date.now() + 35 * 60_000).toISOString(),
      paidAt: Date.now() + demoSaleDelay,
      canEmail: Boolean(body.buyer_email),
      buyerName: 'Buyer · Checkout demo',
      emailStatus: null,
      tiers: [],
      total: 0,
    }
    for (const line of body.line_items || []) {
      const type = event.ticket_types.find(item => item.id === Number(line.ticket_type_id))
      if (!type) continue
      const quantity = Math.min(40, Math.max(0, Number(line.quantity) || 0))
      sale.tiers.push(...Array.from({ length: quantity }, () => type.name))
      sale.total += ((type.current_price_cents ?? type.price_cents ?? 0) + (type.service_fee_cents ?? 0)) * quantity
    }
    if (!sale.tiers.length) return unprocessable('Select at least one demo admission.')
    demo.sales.set(sale.id, sale)
    if (key) demo.attempts.set(key, sale)
    return json(view(sale, event))
  }

  const sale = demo.sales.get(Number(id))
  const checked = params?.get('check_provider') === '1'
  if (!sale) {
    // Demo storage is memory-only. A reopened preview clears the fictional
    // reservation and lets the tester start another sale.
    if (method === 'get' && Number(id) >= 790000) return json({ ...view({
      id: Number(id), method: 'door_card_link', status: 'expired', total: 0, tiers: [],
    }, event), payment_checked: checked })
    return notFound()
  }
  if (method === 'get' && !emailAction) {
    const result = view(sale, event)
    if (checked && result.pending && sale.stripePaid) {
      sale.paidAt = Math.min(sale.paidAt, Date.now() + demoSaleDelay)
      return json({ ...result, status: 'confirming', pending: false, checkout_url: null, payment_checked: true })
    }
    return json({ ...result, payment_checked: checked })
  }
  if (method === 'delete' && !emailAction) {
    if (stateFor(sale) === 'waiting') sale.status = 'cancelled'
    return json(view(sale, event))
  }
  if (method === 'post' && emailAction && sale.canEmail && stateFor(sale) === 'paid') {
    sale.ticketEmailStatus = 'queued'
    return json({ ticket_email_status: sale.ticketEmailStatus }, 202)
  }
  if (method === 'post' && emailAction && sale.canEmail && sale.method === 'door_card_link' && stateFor(sale) === 'waiting') {
    sale.emailStatus = 'queued'
    return json({ link_email_status: sale.emailStatus }, 202)
  }
  return undefined
}
