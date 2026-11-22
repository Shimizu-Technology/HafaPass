import http from 'k6/http'
import { check, fail } from 'k6'
import { Counter, Rate, Trend } from 'k6/metrics'

const ACKNOWLEDGEMENT = 'I_ACKNOWLEDGE_THIS_CREATES_TEST_ORDERS_IN_AN_ISOLATED_ENVIRONMENT'
const PRODUCTION_HOST_PATTERNS = [
  /(^|\.)hafapass\.com$/i,
  /^hafapass-api\.onrender\.com$/i,
]

const scenarioMode = (__ENV.SCENARIO || 'free_saturation').trim().toLowerCase()
const baseUrl = (__ENV.BASE_URL || '').replace(/\/$/, '')
const orgSlug = (__ENV.ORG_SLUG || '').trim()
const seriesSlug = (__ENV.SERIES_SLUG || '').trim()
const distCode = (__ENV.DIST_CODE || '').trim()

const freeEventSlug = (__ENV.EVENT_SLUG || '').trim()
const freeTicketTypeId = Number(__ENV.TICKET_TYPE_ID || 0)
const freeVus = Number(__ENV.FREE_VUS || 150)
const freeIterations = Number(__ENV.FREE_ITERATIONS || 1)
const freeMaxDuration = __ENV.FREE_MAX_DURATION || '3m'

const paidEventSlug = (__ENV.PAID_EVENT_SLUG || freeEventSlug).trim()
const paidTicketTypeId = Number(__ENV.PAID_TICKET_TYPE_ID || 0)
const paidVus = Number(__ENV.PAID_VUS || 40)
const paidIterations = Number(__ENV.PAID_ITERATIONS || 1)
const paidMaxDuration = __ENV.PAID_MAX_DURATION || '3m'

const sharedNat = String(__ENV.SHARED_NAT || 'true').toLowerCase() !== 'false'
const distributedIpHeaders = String(__ENV.DISTRIBUTED_IP_HEADERS || 'false').toLowerCase() === 'true'
const summaryOut = (__ENV.SUMMARY_OUT || 'fd-championship-rush-summary.json').trim()
const runId = `${Date.now().toString(16)}${Math.floor(Math.random() * 0xffff).toString(16).padStart(4, '0')}`

// Step latency trends (milliseconds)
const eventsIndexLatency = new Trend('rush_events_index_latency', true)
const distLinkLatency = new Trend('rush_dist_link_latency', true)
const eventShowLatency = new Trend('rush_event_show_latency', true)
const freeOrderLatency = new Trend('rush_free_order_latency', true)
const paidHoldLatency = new Trend('rush_paid_hold_latency', true)
const paymentResumeLatency = new Trend('rush_payment_resume_latency', true)

// Outcome counters & rates
const freeOrderSuccess = new Counter('rush_free_order_success')
const freeOrderClean422 = new Counter('rush_free_order_clean_422')
const paidHoldSuccess = new Counter('rush_paid_hold_success')
const paidHoldClean422 = new Counter('rush_paid_hold_clean_422')
const paymentResumeSuccess = new Counter('rush_payment_resume_success')
const throttled429 = new Counter('rush_throttled_429')
const serverErrors5xx = new Counter('rush_server_errors_5xx')
const unexpectedErrors = new Rate('rush_unexpected_errors')

const validScenarios = ['free_saturation', 'paid_holds', 'both']
const runFree = scenarioMode === 'free_saturation' || scenarioMode === 'both'
const runPaid = scenarioMode === 'paid_holds' || scenarioMode === 'both'

const scenarios = {}
if (runFree) {
  scenarios.free_saturation = {
    executor: 'per-vu-iterations',
    exec: 'freeSaturation',
    vus: freeVus,
    iterations: freeIterations,
    maxDuration: freeMaxDuration,
  }
}
if (runPaid) {
  scenarios.paid_holds = {
    executor: 'per-vu-iterations',
    exec: 'paidHolds',
    vus: paidVus,
    iterations: paidIterations,
    maxDuration: paidMaxDuration,
    startTime: runFree ? '5s' : '0s',
  }
}

const thresholds = {
  http_req_failed: ['rate==0'],
  rush_unexpected_errors: ['rate==0'],
  rush_throttled_429: ['count==0'],
  rush_server_errors_5xx: ['count==0'],
}
if (runFree) {
  thresholds.rush_events_index_latency = ['p(95)<=300']
  thresholds.rush_free_order_latency = ['p(95)<=1500']
}
if (runPaid) {
  thresholds.rush_paid_hold_latency = ['p(95)<=1500']
}

export const options = {
  scenarios,
  thresholds,
}

function extractHost(url) {
  const match = String(url).match(/^https?:\/\/([^/:?#]+)/i)
  return match ? match[1].toLowerCase() : ''
}

function buildRequestHeaders(baseHeaders = {}) {
  const headers = Object.assign({}, baseHeaders)
  if (!sharedNat && distributedIpHeaders) {
    const octet3 = Math.floor((__VU - 1) / 250) % 250
    const octet4 = ((__VU - 1) % 250) + 1
    headers['X-Forwarded-For'] = `198.51.${octet3}.${octet4}`
  }
  return headers
}

function buildCheckoutKey(prefix) {
  const raw = `${prefix}-${runId}-${__VU}-${__ITER}`
  let hex = ''
  for (let i = 0; i < raw.length; i += 1) {
    hex += raw.charCodeAt(i).toString(16).padStart(2, '0')
  }
  return hex.padEnd(64, '0').slice(0, 64)
}

function recordHttpStatus(response, expectedStatuses) {
  if (response.status === 429) throttled429.add(1)
  if (response.status >= 500 || response.status === 0) serverErrors5xx.add(1)
  const ok = expectedStatuses.includes(response.status)
  unexpectedErrors.add(!ok)
  return ok
}

function validateLoadFixtureEvent(slug, label) {
  const res = http.get(`${baseUrl}/api/v1/events/${encodeURIComponent(slug)}`)
  if (res.status !== 200) fail(`${label} event lookup failed (${res.status}) for slug "${slug}".`)
  const event = res.json()
  if (!String(event.title || '').startsWith('[LOAD TEST]')) {
    fail(`${label} event title must start with "[LOAD TEST]". Got: "${event.title}".`)
  }
  if (event.status !== 'published') fail(`${label} event must be published.`)
  if (event.assigned_seating) fail(`${label} event must be general admission (not assigned seating).`)
  if ((event.registration_questions || []).some(item => item.required) || (event.waivers || []).some(item => item.required)) {
    fail(`${label} fixture must not have required registration questions or waivers.`)
  }
  return event
}

export function setup() {
  if (__ENV.ISOLATED_LOAD_TARGET_ACK !== ACKNOWLEDGEMENT) {
    fail(`Set ISOLATED_LOAD_TARGET_ACK=${ACKNOWLEDGEMENT} before running against staging.`)
  }
  if (!validScenarios.includes(scenarioMode)) {
    fail(`SCENARIO must be one of ${validScenarios.join(', ')} (got "${scenarioMode}").`)
  }
  if (!baseUrl) fail('BASE_URL is required and must point to an isolated staging API.')

  const host = extractHost(baseUrl)
  if (!host) fail(`BASE_URL "${baseUrl}" is not a valid http(s) URL.`)
  if (PRODUCTION_HOST_PATTERNS.some(pattern => pattern.test(host))) {
    fail(`Refusing to run load test against production host "${host}". Use an isolated staging URL.`)
  }

  const configRes = http.get(`${baseUrl}/api/v1/config`)
  if (configRes.status !== 200) fail(`GET /api/v1/config failed with ${configRes.status}.`)
  const config = configRes.json()
  if (String(config.payment_mode || '').toLowerCase() === 'live') {
    fail('Refusing to run load test against an environment in live payment_mode.')
  }

  let freeEvent = null
  let resolvedOrgSlug = orgSlug
  if (runFree) {
    if (!freeEventSlug || !freeTicketTypeId) {
      fail('EVENT_SLUG and TICKET_TYPE_ID are required for free_saturation.')
    }
    freeEvent = validateLoadFixtureEvent(freeEventSlug, 'Free saturation')
    const freeTicket = (freeEvent.ticket_types || []).find(item => Number(item.id) === freeTicketTypeId)
    if (!freeTicket) fail(`TICKET_TYPE_ID ${freeTicketTypeId} does not belong to event "${freeEventSlug}".`)
    if (Number(freeTicket.price_cents) !== 0 || Number(freeTicket.current_price_cents) !== 0) {
      fail('free_saturation requires a free ($0) test ticket type.')
    }
    if (!freeTicket.on_sale) fail('Free test ticket type is not currently on sale.')
    if (!resolvedOrgSlug && freeEvent.organizer && freeEvent.organizer.slug) {
      resolvedOrgSlug = freeEvent.organizer.slug
    }
  }

  let paidEvent = null
  let paidExpectedTotalCents = null
  if (runPaid) {
    if (!paidEventSlug || !paidTicketTypeId) {
      fail('PAID_EVENT_SLUG (or EVENT_SLUG) and PAID_TICKET_TYPE_ID are required for paid_holds.')
    }
    paidEvent = validateLoadFixtureEvent(paidEventSlug, 'Paid holds')
    const paidTicket = (paidEvent.ticket_types || []).find(item => Number(item.id) === paidTicketTypeId)
    if (!paidTicket) fail(`PAID_TICKET_TYPE_ID ${paidTicketTypeId} does not belong to event "${paidEventSlug}".`)
    if (Number(paidTicket.current_price_cents) <= 0) {
      fail('paid_holds requires a paid (price > 0) test ticket type.')
    }
    if (!paidTicket.on_sale) fail('Paid test ticket type is not currently on sale.')
    paidExpectedTotalCents = Number(paidTicket.all_in_price_cents)
    if (!resolvedOrgSlug && paidEvent.organizer && paidEvent.organizer.slug) {
      resolvedOrgSlug = paidEvent.organizer.slug
    }
  }

  return {
    buyerTermsVersion: config.buyer_terms_version,
    paymentMode: config.payment_mode,
    orgSlug: resolvedOrgSlug,
    seriesSlug,
    distCode,
    freeEventId: freeEvent ? freeEvent.id : null,
    freeEventSlug,
    paidEventId: paidEvent ? paidEvent.id : null,
    paidEventSlug,
    paidExpectedTotalCents,
  }
}

export function freeSaturation(data) {
  const headers = buildRequestHeaders({ Accept: 'application/json' })

  // 1. Browse public events index (cached 15s in MemoryStore)
  const queryParts = ['include_sold_out=true']
  if (data.orgSlug) queryParts.push(`organizer=${encodeURIComponent(data.orgSlug)}`)
  if (data.orgSlug && data.seriesSlug) queryParts.push(`series=${encodeURIComponent(data.seriesSlug)}`)
  const indexRes = http.get(`${baseUrl}/api/v1/events?${queryParts.join('&')}`, {
    headers,
    tags: { operation: 'events_index' },
  })
  eventsIndexLatency.add(indexRes.timings.duration)
  const indexOk = recordHttpStatus(indexRes, [200])
  check(indexRes, { 'events index returns 200': () => indexOk })

  // 2. Optional distribution link landing (partner/QR/social link)
  if (data.distCode) {
    const anonId = `rush-${runId}-${__VU}-${__ITER}`
    const distRes = http.get(
      `${baseUrl}/api/v1/distribution_links/${encodeURIComponent(data.distCode)}?anonymous_id=${encodeURIComponent(anonId)}`,
      { headers, tags: { operation: 'distribution_link' } },
    )
    distLinkLatency.add(distRes.timings.duration)
    const distOk = recordHttpStatus(distRes, [200])
    check(distRes, { 'distribution link returns 200': () => distOk })
  }

  // 3. View target event detail (cached 15s in MemoryStore)
  const showRes = http.get(`${baseUrl}/api/v1/events/${encodeURIComponent(data.freeEventSlug)}`, {
    headers,
    tags: { operation: 'event_show' },
  })
  eventShowLatency.add(showRes.timings.duration)
  const showOk = recordHttpStatus(showRes, [200])
  check(showRes, { 'event show returns 200': () => showOk })

  // 4. Submit free championship-rush order (201 created or clean 422 sold-out)
  const suffix = `free-${runId}-${__VU}-${__ITER}`
  const orderPayload = JSON.stringify({
    event_id: data.freeEventId,
    buyer_name: `Rush Buyer ${__VU}-${__ITER}`,
    buyer_email: `load-${suffix}@example.invalid`,
    line_items: [{ ticket_type_id: freeTicketTypeId, quantity: 1 }],
    expected_total_cents: 0,
    terms_accepted: true,
    terms_version: data.buyerTermsVersion,
  })
  const orderRes = http.post(`${baseUrl}/api/v1/orders`, orderPayload, {
    headers: buildRequestHeaders({ 'Content-Type': 'application/json', Accept: 'application/json' }),
    tags: { operation: 'free_order' },
    responseCallback: http.expectedStatuses(201, 422),
  })
  freeOrderLatency.add(orderRes.timings.duration)
  if (orderRes.status === 201) freeOrderSuccess.add(1)
  if (orderRes.status === 422) freeOrderClean422.add(1)
  const orderOk = recordHttpStatus(orderRes, [201, 422])
  check(orderRes, { 'free order created (201) or clean sold-out (422)': () => orderOk })
}

export function paidHolds(data) {
  const suffix = `paid-${runId}-${__VU}-${__ITER}`
  const orderPayload = JSON.stringify({
    event_id: data.paidEventId,
    buyer_name: `Paid Hold Buyer ${__VU}-${__ITER}`,
    buyer_email: `load-${suffix}@example.invalid`,
    line_items: [{ ticket_type_id: paidTicketTypeId, quantity: 1 }],
    expected_total_cents: data.paidExpectedTotalCents,
    checkout_key: buildCheckoutKey('paid'),
    terms_accepted: true,
    terms_version: data.buyerTermsVersion,
  })
  const holdRes = http.post(`${baseUrl}/api/v1/orders`, orderPayload, {
    headers: buildRequestHeaders({ 'Content-Type': 'application/json', Accept: 'application/json' }),
    tags: { operation: 'paid_hold' },
    responseCallback: http.expectedStatuses(201, 422),
  })
  paidHoldLatency.add(holdRes.timings.duration)
  if (holdRes.status === 201) paidHoldSuccess.add(1)
  if (holdRes.status === 422) paidHoldClean422.add(1)
  const holdOk = recordHttpStatus(holdRes, [201, 422])
  check(holdRes, { 'paid hold created (201) or clean cap/sold-out (422)': () => holdOk })

  if (holdRes.status !== 201) return

  const body = holdRes.json()
  const orderId = body && body.id
  const guestToken = body && body.guest_access_token
  if (!orderId || !guestToken) return

  // Exercise payment_resume on the freshly held pending order (only when order is pending payment)
  if (body.status === 'pending') {
    const resumeRes = http.post(`${baseUrl}/api/v1/orders/${orderId}/payment_resume`, '{}', {
      headers: buildRequestHeaders({
        'Content-Type': 'application/json',
        Accept: 'application/json',
        'X-Guest-Order-Token': guestToken,
      }),
      tags: { operation: 'payment_resume' },
    })
    paymentResumeLatency.add(resumeRes.timings.duration)
    if (resumeRes.status === 200) paymentResumeSuccess.add(1)
    const resumeOk = recordHttpStatus(resumeRes, [200])
    check(resumeRes, { 'payment_resume returns 200': () => resumeOk })
  }
}

function metricCount(data, name) {
  const metric = data.metrics && data.metrics[name]
  return metric && metric.values && typeof metric.values.count === 'number' ? metric.values.count : 0
}

function metricLatency(data, name) {
  const metric = data.metrics && data.metrics[name]
  if (!metric || !metric.values) return null
  const values = metric.values
  return {
    p50_ms: Number((values.med || 0).toFixed(2)),
    p95_ms: Number((values['p(95)'] || 0).toFixed(2)),
    p99_ms: Number((values['p(99)'] || 0).toFixed(2)),
    max_ms: Number((values.max || 0).toFixed(2)),
  }
}

export function handleSummary(data) {
  const summary = {
    scenario: scenarioMode,
    shared_nat: sharedNat,
    distributed_ip_headers: !sharedNat && distributedIpHeaders,
    counts: {
      free_order_success: metricCount(data, 'rush_free_order_success'),
      free_order_clean_422: metricCount(data, 'rush_free_order_clean_422'),
      paid_hold_success: metricCount(data, 'rush_paid_hold_success'),
      paid_hold_clean_422: metricCount(data, 'rush_paid_hold_clean_422'),
      payment_resume_success: metricCount(data, 'rush_payment_resume_success'),
      throttled_429: metricCount(data, 'rush_throttled_429'),
      server_errors_5xx: metricCount(data, 'rush_server_errors_5xx'),
    },
    latencies_ms: {
      events_index: metricLatency(data, 'rush_events_index_latency'),
      distribution_link: metricLatency(data, 'rush_dist_link_latency'),
      event_show: metricLatency(data, 'rush_event_show_latency'),
      free_order: metricLatency(data, 'rush_free_order_latency'),
      paid_hold: metricLatency(data, 'rush_paid_hold_latency'),
      payment_resume: metricLatency(data, 'rush_payment_resume_latency'),
    },
    thresholds_passed: Object.values(data.metrics || {}).every(metric => {
      if (!metric.thresholds) return true
      return Object.values(metric.thresholds).every(result => result.ok)
    }),
  }

  const formatted = JSON.stringify(summary, null, 2)
  const output = { stdout: `${formatted}\n` }
  if (summaryOut) output[summaryOut] = formatted
  return output
}
