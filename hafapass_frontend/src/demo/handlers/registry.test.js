import { describe, expect, it, vi } from 'vitest'
import { runDemoHandlers } from './registry'
import { json } from './respond'

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
})
