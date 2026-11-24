import { afterEach, describe, expect, it, vi } from 'vitest'

async function demoClient() {
  vi.resetModules()
  vi.stubEnv('VITE_HAFAPASS_DEMO_DATA', '1')
  vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('Network must not be called in demo mode'))
  return (await import('../api/client')).default
}

describe('demo staff data', () => {
  afterEach(() => { vi.unstubAllEnvs(); vi.resetModules(); vi.restoreAllMocks() })

  it('answers the staff shells with fictional data and no network', async () => {
    const api = await demoClient()
    const me = (await api.get('/me')).data
    expect(me.role).toBe('admin')
    expect(me.email).toMatch(/example\.invalid$/)
    const organizations = (await api.get('/organizer/organizations')).data
    expect(organizations[0]).toMatchObject({ name: 'Isla Demo Sports League', role: 'owner' })
    expect(organizations[0].permissions.manage_payout_settings).toBe(true)
    const events = (await api.get('/organizer/events')).data
    expect(events.events.length).toBeGreaterThanOrEqual(3)
    expect((await api.get('/organizer/events/101/box_office/summary')).data.total_tickets).toBeGreaterThan(0)
    expect((await api.get('/organizer/finances')).data.totals.gross_cents).toBeGreaterThan(0)
    expect((await api.get('/admin/dashboard')).data.recent_events.length).toBeGreaterThan(0)
    expect((await api.get('/admin/payouts')).data.payouts.length).toBeGreaterThanOrEqual(1)
  })

  it('serves a signed scanner manifest the door screen can verify', async () => {
    const api = await demoClient()
    const device = (await api.post('/organizer/events/101/scanner_devices', { identifier: 'x' })).data
    const manifest = (await api.get(`/organizer/events/101/scanner_devices/${device.id}/manifest`)).data
    const { verifyManifestEnvelope } = await import('../utils/admissionStore')
    await expect(verifyManifestEnvelope(manifest)).resolves.toBeDefined()
    expect(manifest.payload.tickets.length).toBeGreaterThan(0)
  })

  it('keeps box-office sales in memory only', async () => {
    const api = await demoClient()
    const before = (await api.get('/organizer/events/101/box_office/summary')).data.total_tickets
    await api.post('/organizer/events/101/box_office', { payment_method: 'door_cash', line_items: [{ ticket_type_id: 1011, quantity: 2 }] })
    expect((await api.get('/organizer/events/101/box_office/summary')).data.total_tickets).toBe(before + 2)
  })

  it('gives unknown organizer changes a friendly demo success and unknown reads a 404', async () => {
    const api = await demoClient()
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    expect((await api.post('/organizer/something_new', {})).data).toMatchObject({ demo: true })
    await expect(api.get('/organizer/something_new')).rejects.toMatchObject({ response: { status: 404, data: { error: expect.stringContaining('demo preview') } } })
  })

  it('lets a registered handler answer before the built-in routes', async () => {
    vi.resetModules()
    vi.stubEnv('VITE_HAFAPASS_DEMO_DATA', '1')
    vi.doMock('./handlers/index', async () => {
      const baseline = await import('./handlers/baseline')
      return { DEMO_HANDLERS: [{ handle: ({ path }) => (path === '/events' ? { status: 200, data: { events: ['mine'] } } : undefined) }, baseline] }
    })
    const api = (await import('../api/client')).default
    expect((await api.get('/events')).data.events).toEqual(['mine'])
    expect((await api.get('/me')).data.role).toBe('admin')
    vi.doUnmock('./handlers/index')
  })

  it('installs the demo staff identity as a ready auth context', async () => {
    vi.resetModules()
    vi.stubEnv('VITE_HAFAPASS_DEMO_DATA', '1')
    const client = await import('../api/client')
    const { installDemoStaffSession } = await import('./staff/session')
    installDemoStaffSession()
    expect(client.getApiAuthContext()).toMatchObject({ ready: true, userId: 'demo_staff_user' })
    expect(window.localStorage.getItem('hafapass_scanner_user_id')).toBe('demo_staff_user')
    window.localStorage.clear()
  })
})
