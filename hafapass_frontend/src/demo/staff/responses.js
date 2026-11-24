// Response builders for the baseline staff handler. Plain functions of the
// in-memory `state.staff`; fictional data only (see ../README.md).
import { canonicalJson, sha256Hex } from '../../utils/admissionStore'
import { DEMO_ORG_ID, DEMO_ORGANIZATION } from './fixtures'

const isoAgo = minutes => new Date(Date.now() - minutes * 60_000).toISOString()

// ---------- Box office ----------
export function boxOfficeSummary(staff) {
  const cash = 24500 + staff.boxOfficeSales.filter(sale => sale.payment_method === 'door_cash').reduce((sum, sale) => sum + sale.total_cents, 0)
  const card = 31200 + staff.boxOfficeSales.filter(sale => sale.payment_method === 'door_card').reduce((sum, sale) => sum + sale.total_cents, 0)
  return {
    total_orders: 18 + staff.boxOfficeSales.length,
    total_revenue_cents: cash + card,
    total_tickets: 41 + staff.boxOfficeSales.reduce((sum, sale) => sum + sale.tickets.length, 0),
    by_payment_method: { door_cash: cash, door_card: card },
  }
}

export function recordBoxOfficeSale(staff, event, body = {}) {
  const lines = Array.isArray(body.line_items) ? body.line_items : []
  const tickets = []
  let total = 0
  lines.forEach(line => {
    const type = event.ticket_types.find(item => String(item.id) === String(line.ticket_type_id))
    const quantity = Math.max(Number(line.quantity) || 0, 0)
    if (!type || !quantity) return
    total += (type.current_price_cents || 0) * quantity
    type.quantity_sold = (type.quantity_sold || 0) + quantity
    type.quantity_remaining = Math.max((type.quantity_remaining || 0) - quantity, 0)
    for (let index = 0; index < quantity; index += 1) tickets.push({ id: 880000 + staff.boxOfficeSales.length * 10 + tickets.length, ticket_type_name: type.name })
  })
  const sale = { id: 770000 + staff.boxOfficeSales.length, payment_method: body.payment_method || 'door_cash', total_cents: total, tickets }
  staff.boxOfficeSales.push(sale)
  return {
    id: sale.id,
    status: 'completed',
    source: 'box_office',
    payment_method: sale.payment_method,
    buyer_name: body.buyer_name || 'Walk-in',
    buyer_email: 'walkin@example.invalid',
    total_cents: total,
    subtotal_cents: total,
    service_fee_cents: 0,
    currency: 'usd',
    tickets: tickets.map(ticket => ({ id: ticket.id, ticket_type_name: ticket.ticket_type_name, qr_code: null })),
    demo: true,
  }
}

// ---------- Organizer finances ----------
const eventFinanceRow = (event, figures) => ({
  id: event.id, title: event.title, slug: event.slug, status: event.status, starts_at: event.starts_at, timezone: event.timezone,
  awaiting_completion: false, discount_cents: 0, refund_cents: 0, platform_fee_cents: 0, platform_processing_fee_cents: 0,
  item_discount_cents: 0, absorbed_fee_cents: 0, refunded_proceeds_cents: 0, door_cash_retained_cents: 0, reserve_cents: 0,
  other_adjustment_cents: 0, unresolved_buyer_liability_cents: 0, negative_balance_cents: 0, in_flight_cents: 0, held_cents: 0,
  settlement: null, settlement_state: 'not_finalized', ...figures,
})

export function organizationFinances(staff) {
  const [open, night1] = staff.events
  const rows = [
    eventFinanceRow(open, {
      gross_cents: 1286500, sales_cents: 1286500, buyer_fee_cents: 142300, organizer_proceeds_cents: 1204000, processing_fee_cents: 38600,
      balance_cents: 1165400, payable_cents: 1165400, paid_cents: 250000, owed_cents: 915400, requestable_cents: 0, payout_state: 'awaiting_statement',
    }),
    eventFinanceRow(night1, {
      gross_cents: 540000, sales_cents: 540000, buyer_fee_cents: 61000, organizer_proceeds_cents: 508000, processing_fee_cents: 16200,
      balance_cents: 491800, payable_cents: 491800, paid_cents: 120000, owed_cents: 371800, requestable_cents: 0, payout_state: 'awaiting_statement',
      status: 'published',
    }),
  ]
  const sum = key => rows.reduce((total, row) => total + (row[key] || 0), 0)
  return {
    organization: { id: DEMO_ORG_ID, name: DEMO_ORGANIZATION.name, slug: DEMO_ORGANIZATION.slug, timezone: 'Pacific/Guam' },
    currency: 'usd',
    totals: {
      gross_cents: sum('gross_cents'), discount_cents: 0, refund_cents: 0, platform_fee_cents: 0, processing_fee_cents: sum('processing_fee_cents'),
      platform_processing_fee_cents: 0, organizer_proceeds_cents: sum('organizer_proceeds_cents'), door_cash_retained_cents: 0,
      payable_cents: sum('payable_cents'), paid_cents: 370000, in_flight_cents: 0, held_cents: 0, owed_cents: sum('owed_cents'),
      negative_balance_cents: 0, requestable_cents: 0, available_to_payout_cents: 0,
    },
    breakdown: {
      sales_cents: sum('sales_cents'), discount_cents: 0, absorbed_fee_cents: 0, refunded_proceeds_cents: 0, proceeds_cents: sum('organizer_proceeds_cents'),
      processing_fee_cents: sum('processing_fee_cents'), door_cash_retained_cents: 0, reserve_cents: 0, adjustment_cents: 0,
      unresolved_buyer_liability_cents: 0, earned_cents: sum('balance_cents'), paid_cents: 370000, in_flight_cents: 0, held_cents: 0,
      balance_cents: sum('balance_cents') - 370000, owed_cents: sum('balance_cents') - 370000, negative_balance_cents: 0,
      buyer_fee_cents: sum('buyer_fee_cents'), refunded_to_buyers_cents: 0, platform_processing_fee_cents: 0,
    },
    orders_without_items_count: 0,
    events: rows,
    payouts: staff.payouts.map(item => ({
      id: item.id, event_id: item.event.id, event_title: item.event.title, settlement_version: item.settlement.version,
      amount_cents: item.amount_cents, withheld_cents: item.withheld_cents, disbursement_cents: item.disbursement_cents, currency: item.currency,
      status: item.status, provider: item.provider, provider_payout_id: item.provider_payout_id, failure_message: null,
      initiated_at: item.created_at, paid_at: item.paid_at, created_at: item.created_at,
    })),
    payouts_count: staff.payouts.length,
    processing_fee_bearers: { platform: 0, organizer: 214, legacy: 0 },
    generated_at: new Date().toISOString(),
  }
}

// ---------- Admin dashboard ----------
export function adminDashboard(staff) {
  return {
    total_events: { published: 3, draft: 1 },
    total_users: { admin: 1, organizer: 4, attendee: 212 },
    total_orders: 214,
    total_revenue_cents: 2184500,
    financials: { gross_cents: 2380000, refund_cents: 38000, fee_cents: 157500, net_cents: 2184500 },
    platform_revenue: { fee_cents: 203300, processing_cost_cents: 69100, net_cents: 134200 },
    open_disputes: 0,
    payouts_needing_reconciliation: staff.payouts.filter(item => ['pending', 'processing', 'held'].includes(item.status)).length,
    open_reconciliation_exceptions: 0,
    operational_signals: [],
    total_tickets_sold: 1480,
    recent_events: staff.events.map(event => ({
      id: event.id, title: event.title, slug: event.slug, status: event.status, category: event.category,
      starts_at: event.starts_at, created_at: event.created_at, organizer_name: DEMO_ORGANIZATION.name,
    })),
    recent_orders: [
      { id: 5001, buyer_name: 'Avery Lindqvist', buyer_email: 'avery@example.invalid', total_cents: 3350, status: 'completed', event_title: staff.events[0].title, event_slug: staff.events[0].slug, created_at: isoAgo(35) },
      { id: 5002, buyer_name: 'Bram Okafor', buyer_email: 'bram@example.invalid', total_cents: 1675, status: 'completed', event_title: staff.events[0].title, event_slug: staff.events[0].slug, created_at: isoAgo(190) },
    ],
    setup_required: [],
    organizers_awaiting_verification: [],
    payout_setups_awaiting_approval: { count: 0, items: [] },
    verified_organizers: [{ profile_id: 9201, business_name: DEMO_ORGANIZATION.name, verified_at: isoAgo(60 * 24 * 40), verified_by: 'demo.staff@example.invalid' }],
    suspended_organizers: [],
  }
}

// ---------- Scanner / door ----------
const DEMO_ATTENDEES = [
  ['Avery Lindqvist', 'Adult Spectator'], ['Bram Okafor', 'Youth Spectator (Ages 5–17)'], ['Calla Yorke', 'Adult Spectator'],
  ['Dashiell Pruitt', 'Child Under 5'], ['Elowen Marsh', 'Matside Bleacher Pass'], ['Fenwick Abara', 'Adult Spectator'],
]

let signingKeys
async function sign(payload) {
  signingKeys ||= crypto.subtle.generateKey({ name: 'RSA-PSS', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify'])
  const keys = await signingKeys
  const digest = await sha256Hex(canonicalJson(payload))
  const signature = await crypto.subtle.sign({ name: 'RSA-PSS', saltLength: 32 }, keys.privateKey, new TextEncoder().encode(digest))
  const publicKey = await crypto.subtle.exportKey('spki', keys.publicKey)
  const base64 = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes)))
  return {
    payload, digest, signature: base64(signature).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, ''),
    algorithm: 'PS256', key_id: await sha256Hex(publicKey), public_key_spki: base64(publicKey),
  }
}

async function demoManifest(staff, event) {
  const admitted = new Set(staff.scans.map(scan => scan.ticket_id))
  const tickets = await Promise.all(DEMO_ATTENDEES.map(async ([name, type], index) => {
    const id = 9500 + index
    return {
      ticket_id: id, code: `HP-T${id}`, credential_hash: await sha256Hex(new TextEncoder().encode(`demo-credential-${id}`)),
      ticket_type: type, seat: null, state: admitted.has(id) ? 'admitted' : 'valid', reversed_admission_action_uuids: [],
      attendee_name: name, ticket_type_name: type, door_check_mode: 'instant', door_alert_label: null, door_instructions: null, door_fields: [],
    }
  }))
  const now = Date.now()
  return sign({
    schema_version: 1,
    event: { id: event.id, title: event.title, status: event.status, venue_name: event.venue_name, starts_at: event.starts_at, ends_at: event.ends_at, timezone: event.timezone },
    version: 1 + staff.scans.length, generated_at: new Date(now).toISOString(), expires_at: new Date(now + 12 * 3_600_000).toISOString(), tickets,
  })
}

const demoDevice = (staff, event) => staff.device || (staff.device = {
  id: 9300 + Number(event.id), identifier: 'demo-device', name: 'Demo door phone', status: 'active', effective: true,
  authorization_expires_at: new Date(Date.now() + 24 * 3_600_000).toISOString(), last_manifest_version: 1, last_manifest_digest: null,
  manifest_downloaded_at: isoAgo(1), last_synced_at: isoAgo(1), last_seen_at: isoAgo(1), last_sequence: 0,
  user: { id: staff.user.id, name: 'Demo Staffer' },
})

const counts = staff => {
  const admitted = staff.scans.length
  return { total: DEMO_ATTENDEES.length, issued: DEMO_ATTENDEES.length - admitted, admitted, cancelled: 0, eligible_unadmitted: DEMO_ATTENDEES.length - admitted, conflicts: 0, rejected: 0, remaining: DEMO_ATTENDEES.length - admitted }
}

export function scannerHandlers(ctx, event, rest) {
  const { method, state: { staff }, body, params } = ctx
  const device = demoDevice(staff, event)
  const deviceBase = `/scanner_devices/${device.id}`
  if (method === 'get' && rest === '/scanner_devices') return { data: [device] }
  if (method === 'post' && rest === '/scanner_devices') return { status: 201, data: device }
  if (method === 'patch' && rest === deviceBase) return { data: device }
  if (method === 'get' && rest === `${deviceBase}/manifest`) return demoManifest(staff, event).then(data => ({ data }))
  if (method === 'get' && rest === '/admissions') {
    return { data: {
      event: { id: event.id, title: event.title, status: event.status, venue_name: event.venue_name, starts_at: event.starts_at, ends_at: event.ends_at, timezone: event.timezone },
      counts: counts(staff), devices: [{ id: device.id, name: device.name, status: 'active', effective: true, staff_name: 'Demo Staffer', last_seen_at: device.last_seen_at, last_synced_at: device.last_synced_at, last_manifest_version: 1 }],
      recent_actions: staff.scans.slice(-10).reverse(), latest_manifest: null, permissions: { can_recover: true, can_reverse: true },
    } }
  }
  if (method === 'get' && rest === '/admissions/search') {
    const query = (params.get('q') || '').trim().toLowerCase()
    if (query.length < 2) return { data: [] }
    return { data: DEMO_ATTENDEES.map(([name, type], index) => ({ id: 9500 + index, code: `HP-T${9500 + index}`, attendee_name: name, ticket_type: type, seat: null, status: 'issued', checked_in_at: null, admission_allowed: true }))
      .filter(ticket => ticket.attendee_name.toLowerCase().includes(query) || ticket.code.toLowerCase().includes(query)) }
  }
  if (method === 'post' && rest === `${deviceBase}/scan`) {
    const ticket = DEMO_ATTENDEES[(Number(body.ticket_id) || 9500) - 9500]
    return { data: { status: 'ready', verification_required: false, ticket: { ticket_id: Number(body.ticket_id), code: `HP-T${body.ticket_id}`, attendee_name: ticket?.[0] || 'Guest', ticket_type_name: ticket?.[1], ticket_type: ticket?.[1], door_check_mode: 'instant', door_fields: [] } } }
  }
  if (method === 'post' && rest === `${deviceBase}/sync`) {
    const actions = Array.isArray(body.actions) ? body.actions : []
    const results = actions.map((action, index) => {
      staff.scans.push({ ...action, ticket_id: action.ticket_id, result: 'accepted', received_at: new Date().toISOString() })
      return { action_uuid: action.action_uuid, ticket_id: action.ticket_id, kind: action.kind, source: action.source, result: 'accepted', reason_code: null, sequence: action.sequence ?? index + 1, occurred_at: action.occurred_at, received_at: new Date().toISOString(), attendee: action.attendee || null }
    })
    return { data: { results, device, summary: counts(staff) } }
  }
  return undefined
}
