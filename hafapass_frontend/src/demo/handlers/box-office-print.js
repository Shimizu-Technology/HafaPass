import { created, json, notFound, unprocessable } from './respond'
import { recordBoxOfficeSale } from '../staff/responses'

const fictionalEmail = 'player@example.invalid'
// The demo keeps its data in memory, which a reload wipes. Keep completed
// box-office receipts for this tab so a reload can show them again, as the
// real API does. Preview-only convenience; storage failures are ignored.
const STORAGE_KEY = 'hafapass-demo:box-office-receipts'
const MAX_STORED = 20

function loadStoredReceipts() {
  try {
    const stored = JSON.parse(window.sessionStorage.getItem(STORAGE_KEY) || '[]')
    return new Map(Array.isArray(stored) ? stored.filter(entry => Array.isArray(entry) && entry.length === 2) : [])
  } catch {
    return new Map()
  }
}

function saveStoredReceipts(orders) {
  try {
    window.sessionStorage.setItem(STORAGE_KEY, JSON.stringify([...orders].slice(-MAX_STORED)))
  } catch {
    // Storage can be unavailable (private mode, quota); the demo still works in memory.
  }
}

export async function handle({ method, path, body, state, config }) {
  const match = path.match(/^\/organizer\/events\/(\d+)\/box_office(?:\/orders\/(\d+)(\/email)?)?$/)
  if (!match) return undefined

  const [, eventId, orderId, emailAction] = match
  const event = state.staff.events.find(item => String(item.id) === eventId)
  if (!event) return undefined
  const fixtures = state.boxOfficePrint ||= { orders: loadStoredReceipts(), attempts: new Map() }

  if (method === 'post' && !orderId && body.payment_method === 'door_cash') {
    const key = config.headers?.get?.('Idempotency-Key')
    if (key && fixtures.attempts.has(key)) return json(fixtures.attempts.get(key))
    const buyer = {
      ...body,
      buyer_name: body.buyer_name ? 'Player 1' : '',
      buyer_email: body.buyer_email ? fictionalEmail : '',
    }
    const order = recordBoxOfficeSale(state.staff, event, buyer)
    const receipt = {
      id: order.id,
      event_id: event.id,
      reference: `DEMO-BOX-OFFICE-PRINT-${order.id}`,
      status: order.status,
      total_cents: order.total_cents,
      event_title: event.title,
      email: buyer.buyer_email || null,
      email_available: true,
      email_status: buyer.buyer_email ? 'queued' : null,
      admissions: order.tickets.map((ticket, index) => ({
        id: order.id * 1000 + index,
        scan_credential: `fictional-print-ticket-${order.id}-${index}`,
        tier: ticket.ticket_type_name,
        attendee_name: buyer.buyer_name || null,
        event: { title: event.title, starts_at: event.starts_at, timezone: event.timezone, venue_name: event.venue_name },
      })),
    }
    const result = { ...order, receipt }
    fixtures.orders.delete(order.id)
    fixtures.orders.set(order.id, receipt)
    saveStoredReceipts(fixtures.orders)
    if (key) fixtures.attempts.set(key, result)
    return created(result)
  }

  if (!orderId) return undefined
  const receipt = fixtures.orders.get(Number(orderId))
  if (!receipt || String(receipt.event_id) !== eventId) return notFound()
  if (method === 'get' && !emailAction) return json(receipt)
  if (method === 'post' && emailAction) {
    if (!body.email) return unprocessable('Enter a fictional buyer email.')
    receipt.email = fictionalEmail
    receipt.email_status = 'queued'
    saveStoredReceipts(fixtures.orders)
    return json({ email: receipt.email, email_status: receipt.email_status }, 202)
  }
  return undefined
}
