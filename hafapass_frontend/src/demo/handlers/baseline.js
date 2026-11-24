// Baseline staff handler: just enough fictional data for the organizer, admin,
// box-office and scanner screens to load. Feature workers add their own files
// beside this one; they should not edit it.
import { json, created } from './respond'
import { organizationFinances, adminDashboard, boxOfficeSummary, recordBoxOfficeSale, scannerHandlers } from '../staff/responses'

const eventIdOf = path => path.match(/^\/organizer\/events\/(\d+)(?:\/|$)/)?.[1]
const paginate = (items, params, perPage = 20) => {
  const page = Math.max(Number(params.get('page')) || 1, 1)
  const per = Math.max(Number(params.get('per_page')) || perPage, 1)
  const pages = Math.max(1, Math.ceil(items.length / per))
  return {
    items: items.slice((page - 1) * per, page * per),
    meta: { current_page: page, total_pages: pages, total_count: items.length, prev_page: page > 1 ? page - 1 : null, next_page: page < pages ? page + 1 : null },
  }
}

export async function handle(ctx) {
  const { method, path, params, body, state } = ctx
  const { staff } = state

  if (method === 'get' && path === '/me') return json(staff.user)
  if (method === 'get' && path === '/organizer/organizations') return json([staff.organization])
  if (method === 'get' && path === '/organizer/organization') return json(staff.organization)
  if (method === 'get' && path === '/organizer_profile') return json(staff.profile)
  if (method === 'get' && path === '/organizer/connected_accounts') return json([])
  if (method === 'get' && path === '/organizer/card_present_account') return json({ status: 'not_configured', configured: false })

  if (method === 'get' && path === '/organizer/events') {
    let events = staff.events
    const q = (params.get('q') || '').trim().toLowerCase()
    if (q) events = events.filter(event => `${event.title} ${event.venue_name}`.toLowerCase().includes(q))
    if (params.get('status')) events = events.filter(event => event.status === params.get('status'))
    const { items, meta } = paginate(events, params)
    return json({ events: items, meta })
  }
  if (method === 'get' && path === '/organizer/events/summary') {
    const upcoming = staff.events.filter(event => event.status === 'published')
    const next = upcoming[0]
    return json({
      upcoming_events_count: upcoming.length,
      tickets_sold: 1480,
      next_event: next && { id: next.id, title: next.title, starts_at: next.starts_at, timezone: next.timezone },
      revenue_cents: 2184500,
    })
  }
  const eventId = eventIdOf(path)
  if (eventId) {
    const event = staff.events.find(item => String(item.id) === eventId)
    const rest = path.replace(`/organizer/events/${eventId}`, '') || ''
    // Unknown event ids fall through so feature handlers (or the adapter's
    // friendly 404) can answer them.
    if (!event) return undefined
    if (method === 'get' && rest === '') return json(event)
    if (method === 'get' && rest === '/box_office/summary') return json(boxOfficeSummary(staff))
    if (method === 'post' && rest === '/box_office') return created(recordBoxOfficeSale(staff, event, body))
    const scanner = await scannerHandlers(ctx, event, rest)
    if (scanner !== undefined) return { status: 200, ...scanner }
  }

  if (method === 'get' && path === '/organizer/finances') return json(organizationFinances(staff))

  if (method === 'get' && path === '/admin/dashboard') return json(adminDashboard(staff))
  if (method === 'get' && path === '/admin/payouts') {
    let payouts = staff.payouts
    if (params.get('status')) payouts = payouts.filter(item => item.status === params.get('status'))
    const { items, meta } = paginate(payouts, params)
    const counts = staff.payouts.reduce((totals, item) => ({ ...totals, [item.status]: (totals[item.status] || 0) + 1 }), {})
    return json({ payouts: items, status_counts: counts, meta })
  }
  if (method === 'get' && path === '/admin/balance_adjustments') {
    return json({ balance_adjustments: [], meta: paginate([], params).meta })
  }

  return undefined
}
