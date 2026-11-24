import { matchesGuamWindow } from '../utils/guamDiscoveryWindow'
import { AxiosError } from 'axios'
import {
  DEMO_CATEGORIES,
  DEMO_COLLECTIONS,
  DEMO_EVENTS,
  DEMO_ORGANIZERS,
  DEMO_ORDERS,
  DEMO_TICKETS,
  DEMO_VENUES,
  buildDemoPublicConfig,
} from './demoFixtures'
import { lowestPurchasablePrice } from '../utils/ticketPricing'

function ok(config, data, status = 200) {
  return Promise.resolve({
    data,
    status,
    statusText: status === 200 ? 'OK' : 'Created',
    headers: { 'content-type': 'application/json', 'x-hafapass-demo': '1' },
    config,
  })
}

function fail(config, status, data, message = `Demo API error ${status}`) {
  return Promise.reject(new AxiosError(
    message,
    status >= 500 ? 'ERR_BAD_RESPONSE' : 'ERR_BAD_REQUEST',
    config,
    null,
    { data, status, statusText: String(status), headers: { 'content-type': 'application/json' }, config },
  ))
}

function parseBody(raw) {
  if (!raw) return {}
  if (typeof raw === 'string') {
    try { return JSON.parse(raw) } catch { return {} }
  }
  return raw
}

function normalizePath(config) {
  const rawUrl = String(config.url || '/')
  const [pathnameOnly, inlineQuery] = rawUrl.split('?')
  const path = pathnameOnly.startsWith('/') ? pathnameOnly : `/${pathnameOnly}`
  const search = new URLSearchParams(inlineQuery || '')
  if (config.params && typeof config.params === 'object') {
    Object.entries(config.params).forEach(([key, value]) => {
      if (value !== undefined && value !== null && value !== '') search.set(key, String(value))
    })
  }
  return { path: path.replace(/\/+$/, '') || '/', params: search }
}

function paginate(items, params) {
  const page = Math.max(Number(params.get('page')) || 1, 1)
  const perPage = Math.max(Number(params.get('per_page')) || 12, 1)
  const totalCount = items.length
  const totalPages = Math.max(1, Math.ceil(totalCount / perPage))
  const start = (page - 1) * perPage
  const slice = items.slice(start, start + perPage)
  return {
    items: slice,
    meta: {
      current_page: page,
      total_pages: totalPages,
      total_count: totalCount,
      prev_page: page > 1 ? page - 1 : null,
      next_page: page < totalPages ? page + 1 : null,
    },
  }
}

function filterEvents(params) {
  let results = [...DEMO_EVENTS]
  const q = (params.get('q') || params.get('search') || '').trim().toLowerCase()
  const category = (params.get('category') || '').trim().toLowerCase()
  const village = (params.get('village') || '').trim().toLowerCase()
  const price = (params.get('price') || '').trim().toLowerCase()
  const dateFrom = params.get('date_from')
  const dateTo = params.get('date_to')
  const windowFilter = params.get('window')

  if (q) {
    results = results.filter(event => [
      event.title,
      event.short_description,
      event.description,
      event.venue_name,
      event.venue_city,
      event.organizer?.business_name,
    ].some(field => String(field || '').toLowerCase().includes(q)))
  }
  if (category && category !== 'all') {
    results = results.filter(event => event.category === category)
  }
  if (village) {
    results = results.filter(event => String(event.venue_city || '').toLowerCase() === village)
  }
  if (price === 'free') {
    results = results.filter(event => lowestPurchasablePrice(event.ticket_types) === 0)
  } else if (price === 'under_25') {
    results = results.filter(event => {
      const low = lowestPurchasablePrice(event.ticket_types)
      return low !== null && low < 2500
    })
  } else if (price === 'under_50') {
    results = results.filter(event => {
      const low = lowestPurchasablePrice(event.ticket_types)
      return low !== null && low < 5000
    })
  }
  if (dateFrom) {
    results = results.filter(event => String(event.starts_at || '').slice(0, 10) >= dateFrom)
  }
  if (dateTo) {
    results = results.filter(event => String(event.starts_at || '').slice(0, 10) <= dateTo)
  }
  if (['tonight', 'weekend'].includes(windowFilter)) {
    results = results.filter(event => matchesGuamWindow(event.starts_at, windowFilter))
  }
  return results
}

export function createDemoAdapter() {
  return async function demoAdapter(config) {
    const method = String(config.method || 'get').toLowerCase()
    const { path, params } = normalizePath(config)
    const body = parseBody(config.data)
    const serverNow = new Date().toISOString()

    if (method === 'get' && path === '/health') {
      return ok(config, { status: 'ok', demo: true, server_now: serverNow })
    }

    if (method === 'get' && path === '/config') {
      return ok(config, buildDemoPublicConfig())
    }

    if (method === 'get' && path === '/event_categories') {
      return ok(config, { categories: DEMO_CATEGORIES, server_now: serverNow })
    }

    if (method === 'get' && path === '/events') {
      const filtered = filterEvents(params)
      const { items, meta } = paginate(filtered, params)
      return ok(config, { events: items, meta, server_now: serverNow })
    }

    const eventMatch = path.match(/^\/events\/([^/]+)$/)
    if (method === 'get' && eventMatch) {
      const slug = decodeURIComponent(eventMatch[1])
      const event = DEMO_EVENTS.find(item => item.slug === slug || String(item.id) === slug)
      if (!event) return fail(config, 404, { error: 'Event not found' })
      return ok(config, { ...event, server_now: serverNow })
    }

    const organizerMatch = path.match(/^\/organizers\/([^/]+)$/)
    if (method === 'get' && organizerMatch) {
      const slug = decodeURIComponent(organizerMatch[1])
      const organizer = DEMO_ORGANIZERS[slug]
      if (!organizer) return fail(config, 404, { error: 'Organizer not found' })
      const orgEvents = DEMO_EVENTS.filter(event => event.organizer?.slug === slug)
      const { items, meta } = paginate(orgEvents, params)
      return ok(config, { ...organizer, events: items, meta, server_now: serverNow })
    }

    const venueMatch = path.match(/^\/venues\/([^/]+)$/)
    if (method === 'get' && venueMatch) {
      const slug = decodeURIComponent(venueMatch[1])
      const venue = DEMO_VENUES[slug]
      if (!venue) return fail(config, 404, { error: 'Venue not found' })
      const venueEvents = DEMO_EVENTS.filter(event => event.venue?.slug === slug)
      const { items, meta } = paginate(venueEvents, params)
      return ok(config, { ...venue, events: items, meta, server_now: serverNow })
    }

    if (method === 'get' && path === '/marketplace_collections') {
      return ok(config, { collections: DEMO_COLLECTIONS, server_now: serverNow })
    }

    const collectionMatch = path.match(/^\/marketplace_collections\/([^/]+)$/)
    if (method === 'get' && collectionMatch) {
      const slug = decodeURIComponent(collectionMatch[1])
      const collection = DEMO_COLLECTIONS.find(item => item.slug === slug)
      if (!collection) return fail(config, 404, { error: 'Collection not found' })
      const { items, meta } = paginate(collection.events, params)
      return ok(config, { ...collection, events: items, meta, server_now: serverNow })
    }

    const orderMatch = path.match(/^\/orders\/([^/]+)$/)
    if (method === 'get' && orderMatch) {
      const id = decodeURIComponent(orderMatch[1])
      const order = DEMO_ORDERS[id]
      if (!order) return fail(config, 404, { error: 'Order not found' })
      return ok(config, { ...order, server_now: serverNow })
    }

    const ticketMatch = path.match(/^\/tickets\/([^/]+)$/)
    if (method === 'get' && ticketMatch) {
      const credential = decodeURIComponent(ticketMatch[1])
      const ticket = DEMO_TICKETS[credential]
      if (!ticket) return fail(config, 404, { error: 'Ticket not found' })
      return ok(config, { ...ticket, server_now: serverNow })
    }

    if (method === 'post' && path === '/marketplace_funnel_events') {
      return ok(config, { recorded: true, demo: true }, 201)
    }

    if (method === 'post' && path === '/promo_codes/validate') {
      const code = String(body.code || '').trim().toUpperCase()
      if (code === 'DEMO10') {
        const subtotal = Number(body.subtotal_cents) || 0
        const discount = Math.round(subtotal * 0.1)
        return ok(config, {
          valid: true,
          code: 'DEMO10',
          promo_code_id: 999,
          description: '10% demo preview discount',
          discount_cents: discount,
        })
      }
      return ok(config, { valid: false, error: 'Try demo code DEMO10 in this preview.' })
    }

    if (method === 'post' && path === '/orders') {
      return fail(config, 403, { error: 'Demo preview: payments are off.' })
    }

    if (method === 'post' && path === '/order_lookup') {
      return ok(config, { sent: true, demo: true })
    }

    const waitlistMatch = path.match(/^\/events\/([^/]+)\/waitlist$/)
    if (method === 'post' && waitlistMatch) {
      return ok(config, {
        id: 9901,
        position: 14,
        status: 'waiting',
        email: body.email || 'guest@example.com',
        management_token: 'demo-waitlist-token',
      }, 201)
    }
    if (method === 'delete' && waitlistMatch) {
      return ok(config, { removed: true })
    }

    const waitlistStatusMatch = path.match(/^\/events\/([^/]+)\/waitlist\/status$/)
    if (method === 'get' && waitlistStatusMatch) {
      return ok(config, { entries: [{ id: 9901, position: 14, status: 'waiting' }] })
    }

    if (method === 'post' && /^\/orders\/[^/]+\/resend$/.test(path)) {
      return ok(config, { requested: true, demo: true })
    }

    if (method === 'post' && /^\/me\/(event_favorites|organizer_follows|event_reminders|event_referrals)$/.test(path)) {
      return fail(config, 401, { error: 'Sign-in is disabled in demo preview.' })
    }

    // Never fall through to the real network in demo mode.
    return fail(config, 404, { error: `Endpoint ${method.toUpperCase()} ${path} is not available in demo preview.` })
  }
}
