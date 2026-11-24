import { describe, expect, it, vi } from 'vitest'
import { runDemoHandlers } from './registry'
import { json } from './respond'
import * as baseline from './baseline'
import { createDemoStaffState } from '../staff/fixtures'

const ctx = { method: 'get', path: '/x', body: {}, params: new URLSearchParams(), config: {}, state: {} }

describe('demo handler registry', () => {
  it('uses the first handler that answers and skips ones that return undefined', async () => {
    const calls = []
    const handlers = [
      { handle: () => { calls.push('a') } },
      { handle: async () => { calls.push('b'); return json({ from: 'b' }) } },
      { handle: () => { calls.push('c'); return json({ from: 'c' }) } },
    ]
    expect(await runDemoHandlers(ctx, handlers)).toEqual({ status: 200, data: { from: 'b' } })
    expect(calls).toEqual(['a', 'b'])
  })

  it('returns undefined when nothing answers, so the adapter falls through', async () => {
    expect(await runDemoHandlers(ctx, [{ handle: () => undefined }, {}])).toBeUndefined()
  })

  it('reports and skips a handler that throws', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const handlers = [{ handle: () => { throw new Error('broken fixture') } }, { handle: () => json({ ok: true }) }]
    expect(await runDemoHandlers(ctx, handlers)).toEqual({ status: 200, data: { ok: true } })
    expect(warn).toHaveBeenCalled()
    warn.mockRestore()
  })

  it('treats null like undefined', async () => {
    expect(await runDemoHandlers(ctx, [{ handle: () => null }, { handle: () => json({ ok: 1 }) }])).toEqual({ status: 200, data: { ok: 1 } })
  })

  it('lets a feature handler listed after baseline receive organizer/admin writes and unknown event ids', async () => {
    const state = createDemoStaffState()
    const feature = { handle: ({ method, path }) => (
      (method === 'post' && path === '/organizer/events/101/promo_codes') ||
      (method === 'patch' && path === '/admin/payouts/7002') ||
      (method === 'get' && path === '/organizer/events/999999/re_entry') ||
      (method === 'patch' && path === '/organizer_profile')
        ? json({ from: 'feature', method, path }) : undefined
    ) }
    for (const [method, path] of [['post', '/organizer/events/101/promo_codes'], ['patch', '/admin/payouts/7002'], ['get', '/organizer/events/999999/re_entry'], ['patch', '/organizer_profile']]) {
      const result = await runDemoHandlers({ ...ctx, method, path, state }, [baseline, feature])
      expect(result).toEqual({ status: 200, data: { from: 'feature', method, path } })
    }
  })
})
