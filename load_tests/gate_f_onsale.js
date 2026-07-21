import http from 'k6/http'
import { check, fail } from 'k6'
import { Counter, Rate, Trend } from 'k6/metrics'

const acknowledgement = 'I_ACKNOWLEDGE_THIS_CREATES_TEST_ORDERS_IN_AN_ISOLATED_ENVIRONMENT'
const baseUrl = (__ENV.BASE_URL || '').replace(/\/$/, '')
const eventSlug = __ENV.EVENT_SLUG || ''
const ticketTypeId = Number(__ENV.TICKET_TYPE_ID || 0)
const expectedBuyers = Number(__ENV.EXPECTED_CONCURRENT_BUYERS || 25)
const iterationsPerBuyer = Number(__ENV.ITERATIONS_PER_BUYER || 5)
const maxDuration = __ENV.MAX_DURATION || '5m'
const contentionEventSlug = __ENV.CONTENTION_EVENT_SLUG || ''
const contentionSeatId = Number(__ENV.CONTENTION_EVENT_SEAT_ID || 0)

const checkoutLatency = new Trend('pilot_checkout_latency', true)
const checkoutFailures = new Rate('pilot_checkout_failures')
const contentionAttempts = new Counter('pilot_seat_contention_attempts')
const contentionUnexpected = new Rate('pilot_seat_contention_unexpected')

const scenarios = {
  expected_onsale: {
    executor: 'per-vu-iterations',
    exec: 'expectedOnsale',
    vus: expectedBuyers,
    iterations: iterationsPerBuyer,
    maxDuration,
  },
}
if (contentionSeatId > 0) {
  scenarios.assigned_seat_contention = {
    executor: 'per-vu-iterations',
    exec: 'assignedSeatContention',
    vus: Math.min(expectedBuyers, 50),
    iterations: 1,
    maxDuration: '1m',
  }
}

export const options = {
  scenarios,
  thresholds: {
    pilot_checkout_failures: ['rate<=0.01'],
    pilot_checkout_latency: ['p(95)<=1500'],
    pilot_seat_contention_unexpected: ['rate==0'],
  },
}

export function setup() {
  if (__ENV.ISOLATED_LOAD_TARGET_ACK !== acknowledgement) fail('Set the exact ISOLATED_LOAD_TARGET_ACK from the Gate F runbook.')
  if (!baseUrl || !eventSlug || !ticketTypeId) fail('BASE_URL, EVENT_SLUG, and TICKET_TYPE_ID are required.')

  const eventResponse = http.get(`${baseUrl}/api/v1/events/${eventSlug}`)
  if (eventResponse.status !== 200) fail(`Load-test event lookup failed with ${eventResponse.status}.`)
  const event = eventResponse.json()
  if (!String(event.title).startsWith('[LOAD TEST]')) fail('The target event title must start with [LOAD TEST].')
  if (event.status !== 'published') fail('The isolated load-test event must be published.')

  const ticket = event.ticket_types.find(item => Number(item.id) === ticketTypeId)
  if (!ticket) fail('TICKET_TYPE_ID does not belong to the target event.')
  if (Number(ticket.current_price_cents) !== 0 || Number(ticket.price_cents) !== 0) {
    fail('The load harness refuses paid tickets. Use a free isolated test ticket.')
  }
  if (!ticket.on_sale) fail('The isolated test ticket is not currently on sale.')
  if ((event.registration_questions || []).some(item => item.required) || (event.waivers || []).some(item => item.required)) {
    fail('Use a load fixture without required registration questions or waivers.')
  }
  if (event.assigned_seating) fail('Use a general-admission fixture for EVENT_SLUG and the separate contention fixture for assigned seating.')
  if (Number(ticket.quantity_remaining) < expectedBuyers * iterationsPerBuyer) {
    fail('Free test inventory must cover EXPECTED_CONCURRENT_BUYERS × ITERATIONS_PER_BUYER.')
  }

  if ((contentionSeatId > 0) !== Boolean(contentionEventSlug)) {
    fail('CONTENTION_EVENT_SLUG and CONTENTION_EVENT_SEAT_ID must be supplied together.')
  }
  if (contentionSeatId > 0) {
    const contentionResponse = http.get(`${baseUrl}/api/v1/events/${contentionEventSlug}`)
    if (contentionResponse.status !== 200) fail('Assigned-seat contention event lookup failed.')
    const contentionEvent = contentionResponse.json()
    if (!String(contentionEvent.title).startsWith('[LOAD TEST]') || !contentionEvent.assigned_seating) {
      fail('The contention fixture must be an assigned-seating event whose title starts with [LOAD TEST].')
    }
  }

  const configResponse = http.get(`${baseUrl}/api/v1/config`)
  if (configResponse.status !== 200) fail('Public configuration lookup failed.')
  return { eventId: event.id, buyerTermsVersion: configResponse.json('buyer_terms_version'), contentionEventSlug }
}

export function expectedOnsale(data) {
  const suffix = `${__VU}-${__ITER}-${Date.now()}`
  const payload = JSON.stringify({
    event_id: data.eventId,
    buyer_name: `Load Buyer ${suffix}`,
    buyer_email: `load-${suffix}@example.invalid`,
    line_items: [{ ticket_type_id: ticketTypeId, quantity: 1 }],
    terms_accepted: true,
    terms_version: data.buyerTermsVersion,
  })
  const response = http.post(`${baseUrl}/api/v1/orders`, payload, {
    headers: { 'Content-Type': 'application/json' },
    tags: { operation: 'free_checkout' },
  })
  checkoutLatency.add(response.timings.duration)
  const succeeded = check(response, { 'free checkout created': result => result.status === 201 })
  checkoutFailures.add(!succeeded)
}

export function assignedSeatContention(data) {
  contentionAttempts.add(1)
  const response = http.post(`${baseUrl}/api/v1/events/${data.contentionEventSlug}/seat_holds`, JSON.stringify({
    event_seat_ids: [contentionSeatId],
    accessibility_attested: false,
    source: 'gate_f_load_test',
  }), { headers: { 'Content-Type': 'application/json' }, tags: { operation: 'seat_contention' } })
  const expected = [201, 422].includes(response.status)
  contentionUnexpected.add(!expected)
  check(response, { 'contention is accepted or safely rejected': () => expected })
}

export function handleSummary(data) {
  return {
    stdout: JSON.stringify(data, null, 2),
    'gate-f-load-summary.json': JSON.stringify(data, null, 2),
  }
}
