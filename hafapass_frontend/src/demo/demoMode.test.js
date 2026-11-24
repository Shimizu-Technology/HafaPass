import { afterEach, describe, expect, it, vi } from 'vitest'

describe('preview-only demo-data mode', () => {
  afterEach(() => {
    vi.unstubAllEnvs()
    vi.resetModules()
    vi.restoreAllMocks()
  })

  it('does not import demo fixtures or override the API adapter when VITE_HAFAPASS_DEMO_DATA is off', async () => {
    vi.resetModules()
    vi.stubEnv('VITE_HAFAPASS_DEMO_DATA', '')
    const fixturesLoaded = vi.fn()
    vi.doMock('./demoFixtures', () => {
      fixturesLoaded()
      return {}
    })
    vi.doMock('./demoApiAdapter', () => {
      fixturesLoaded()
      return { createDemoAdapter: vi.fn() }
    })

    const { default: apiClient } = await import('../api/client')
    const { isDemoDataEnabled } = await import('../utils/demoMode')
    expect(isDemoDataEnabled()).toBe(false)
    expect(fixturesLoaded).not.toHaveBeenCalled()
    expect(typeof apiClient.defaults.adapter).not.toBe('function')

    vi.doUnmock('./demoFixtures')
    vi.doUnmock('./demoApiAdapter')
  })

  it('serves fictional buyer data locally with zero network calls when VITE_HAFAPASS_DEMO_DATA=1', async () => {
    vi.resetModules()
    vi.stubEnv('VITE_HAFAPASS_DEMO_DATA', '1')
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('Network must not be called in demo mode'))

    const { default: apiClient } = await import('../api/client')
    const { DEMO_SAMPLE_ORDER_ID, DEMO_SAMPLE_PASS_ORDER_ID, DEMO_SAMPLE_TICKET_CREDENTIAL } = await import('./demoFixtures')

    const eventsRes = await apiClient.get('/events')
    expect(eventsRes.data.events.length).toBeGreaterThanOrEqual(3)
    expect(eventsRes.data.events[0].title).toBe('Copa de Marianas 2027 (demo)')

    const copaRes = await apiClient.get('/events/copa-de-marianas-2027')
    expect(copaRes.data.venue_name).toBe('UOG Calvo Field House')
    expect(copaRes.data.ticket_types.some(tt => tt.price_cents === 1500 && tt.all_in_price_cents === 1675)).toBe(true)
    expect(copaRes.data.ticket_types.some(tt => tt.price_cents === 0)).toBe(true)
    expect(copaRes.data.ticket_types.some(tt => tt.quantity_remaining === 0)).toBe(true)

    const fdRes = await apiClient.get('/events/fd-alumni-basketball-night-1')
    expect(fdRes.data.ticket_types.some(tt => tt.is_pass && tt.included_events.length === 2)).toBe(true)

    const orgRes = await apiClient.get('/organizers/marianas-grappling-federation-demo')
    expect(orgRes.data.name).toContain('(demo)')
    expect(orgRes.data.events.length).toBeGreaterThan(0)

    const orderRes = await apiClient.get(`/orders/${DEMO_SAMPLE_ORDER_ID}`)
    expect(orderRes.data.status).toBe('completed')
    expect(orderRes.data.tickets.length).toBe(2)

    const passOrderRes = await apiClient.get(`/orders/${DEMO_SAMPLE_PASS_ORDER_ID}`)
    expect(passOrderRes.data.tickets[0].pass_parent).toBe(true)
    expect(passOrderRes.data.tickets[0].child_tickets.length).toBe(2)

    const ticketRes = await apiClient.get(`/tickets/${DEMO_SAMPLE_TICKET_CREDENTIAL}`)
    expect(ticketRes.data.scan_credential).toContain('DEMO')
    expect(ticketRes.data.admission_allowed).toBe(true)

    await expect(apiClient.post('/orders', { event_id: 101 })).rejects.toMatchObject({
      response: { status: 403, data: { error: 'Demo preview: payments are off.' } },
    })

    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('disables Clerk in demo mode even when VITE_CLERK_PUBLISHABLE_KEY is configured', async () => {
    vi.resetModules()
    vi.stubEnv('VITE_HAFAPASS_DEMO_DATA', '1')
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_live_should_be_ignored_in_demo')

    const { isClerkEnabled, clerkPublishableKey } = await import('../utils/demoMode')
    expect(isClerkEnabled()).toBe(false)
    expect(clerkPublishableKey()).toBe('')
  })

  it('uses only fictional starter-list names, (demo) markers, and reserved contact identifiers', async () => {
    const fixtures = await import('./demoFixtures')
    const serialized = JSON.stringify({
      events: fixtures.DEMO_EVENTS,
      organizers: fixtures.DEMO_ORGANIZERS,
      orders: fixtures.DEMO_ORDERS,
      tickets: fixtures.DEMO_TICKETS,
      config: fixtures.buildDemoPublicConfig(),
    })

    for (const event of fixtures.DEMO_EVENTS) {
      expect(event.title).toContain('(demo)')
      expect(event.organizer.business_name).toContain('(demo)')
    }
    const emails = serialized.match(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g) || []
    expect(emails.length).toBeGreaterThan(0)
    for (const email of emails) {
      expect(email).toMatch(/@(example\.(com|org|net)|[a-z0-9.-]+\.test)$/i)
    }
    const phones = serialized.match(/\(671\)\s*\d{3}-\d{4}/g) || []
    expect(phones.length).toBeGreaterThan(0)
    for (const phone of phones) {
      expect(phone).toMatch(/555-01\d\d/)
    }
  })
})
