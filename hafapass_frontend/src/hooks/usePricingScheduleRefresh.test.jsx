import { act, renderHook } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import { syncServerClock } from '../utils/serverClock'
import usePricingScheduleRefresh from './usePricingScheduleRefresh'

vi.mock('../api/client', () => ({ default: { get: vi.fn() } }))

afterEach(() => {
  vi.useRealTimers()
  vi.resetAllMocks()
})

it('refreshes once at a shared cutoff in server time and resyncs on focus or visibility', async () => {
  vi.useFakeTimers({ toFake: ['Date', 'performance', 'setTimeout', 'clearTimeout'] })
  vi.setSystemTime(new Date('2099-05-01T00:00:00Z'))
  const serverNow = '2027-05-01T13:58:59.000Z'
  const cutoff = '2027-05-01T13:59:00.000500Z'
  syncServerClock(serverNow)
  const event = { slug: 'reunion', server_now: serverNow, ticket_types: [
    { pricing_schedule: { active_tier: { tier_type: 'time_based', ends_at: cutoff }, next_tier: { starts_at: cutoff } } },
    { pricing_schedule: { next_tier: { starts_at: cutoff } } },
  ] }
  const updated = { ...event, server_now: cutoff }
  apiClient.get.mockResolvedValue({ data: updated })
  const apply = vi.fn()
  const { rerender } = renderHook(props => usePricingScheduleRefresh(props, '/events/reunion', apply), { initialProps: event })

  await act(async () => { await vi.advanceTimersByTimeAsync(1000) })
  expect(apiClient.get).not.toHaveBeenCalled()
  await act(async () => { await vi.advanceTimersByTimeAsync(1) })
  expect(apiClient.get).toHaveBeenCalledTimes(1)
  expect(apply).toHaveBeenCalledWith(updated)
  rerender({ ...event })
  expect(apiClient.get).toHaveBeenCalledTimes(1)
  await act(async () => {
    window.dispatchEvent(new Event('focus'))
    document.dispatchEvent(new Event('visibilitychange'))
  })
  expect(apiClient.get).toHaveBeenCalledTimes(2)
})
