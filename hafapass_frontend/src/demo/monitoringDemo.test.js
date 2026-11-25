import { afterEach, describe, expect, it, vi } from 'vitest'

async function demoClient() {
  vi.resetModules()
  vi.stubEnv('VITE_HAFAPASS_DEMO_DATA', '1')
  vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('Network must not be called in demo mode'))
  return (await import('../api/client')).default
}

describe('demo monitoring data', () => {
  afterEach(() => { vi.unstubAllEnvs(); vi.resetModules(); vi.restoreAllMocks() })

  it('answers the monitoring page with fictional healthy data', async () => {
    const api = await demoClient()
    const data = (await api.get('/admin/monitoring')).data
    expect(data.stripe_webhooks).toMatchObject({ silent: false, failing: false })
    expect(data.summary.on_sale[0].title).toBe('Isla Demo Open (demo)')
    expect(data.test_alert_kinds).toContain('stripe_webhooks_silent')
  })

  it('accepts a test alert without sending anything, and rejects unknown kinds', async () => {
    const api = await demoClient()
    expect((await api.post('/admin/monitoring/test_alert', { kind: 'checkout' })).data).toMatchObject({ sent: true, demo: true })
    await expect(api.post('/admin/monitoring/test_alert', { kind: 'nope' })).rejects.toBeTruthy()
  })
})
