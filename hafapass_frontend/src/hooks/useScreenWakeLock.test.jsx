import { act, renderHook, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import useScreenWakeLock from './useScreenWakeLock'

describe('useScreenWakeLock', () => {
  const original = Object.getOwnPropertyDescriptor(navigator, 'wakeLock')
  const mockWakeLock = request => Object.defineProperty(navigator, 'wakeLock', { configurable: true, value: { request } })
  afterEach(() => {
    if (original) Object.defineProperty(navigator, 'wakeLock', original)
    else delete navigator.wakeLock
    vi.restoreAllMocks()
  })

  it('requests only while active and releases when deactivated', async () => {
    vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
    const lock = { release: vi.fn().mockResolvedValue(), addEventListener: vi.fn() }
    const request = vi.fn().mockResolvedValue(lock)
    mockWakeLock(request)
    const { result, rerender, unmount } = renderHook(({ active }) => useScreenWakeLock(active), { initialProps: { active: false } })
    expect(result.current).toEqual({ supported: true, failed: false })
    expect(request).not.toHaveBeenCalled()
    rerender({ active: true })
    await waitFor(() => expect(request).toHaveBeenCalledWith('screen'))
    await waitFor(() => expect(lock.addEventListener).toHaveBeenCalled())
    rerender({ active: false })
    expect(lock.release).toHaveBeenCalledTimes(1)
    act(() => document.dispatchEvent(new Event('visibilitychange')))
    expect(request).toHaveBeenCalledTimes(1)
    unmount()
  })

  it('reacquires after the page becomes visible again', async () => {
    let visibility = 'visible'
    vi.spyOn(document, 'visibilityState', 'get').mockImplementation(() => visibility)
    const first = { release: vi.fn().mockResolvedValue(), addEventListener: vi.fn() }
    const second = { release: vi.fn().mockResolvedValue(), addEventListener: vi.fn() }
    const request = vi.fn().mockResolvedValueOnce(first).mockResolvedValueOnce(second)
    mockWakeLock(request)
    const { unmount } = renderHook(() => useScreenWakeLock(true))
    await waitFor(() => expect(first.addEventListener).toHaveBeenCalled())
    visibility = 'hidden'
    act(() => document.dispatchEvent(new Event('visibilitychange')))
    expect(first.release).toHaveBeenCalledTimes(1)
    visibility = 'visible'
    act(() => document.dispatchEvent(new Event('visibilitychange')))
    await waitFor(() => expect(request).toHaveBeenCalledTimes(2))
    await waitFor(() => expect(second.addEventListener).toHaveBeenCalled())
    unmount()
    expect(second.release).toHaveBeenCalledTimes(1)
  })

  it('reports an unsupported browser', () => {
    delete navigator.wakeLock
    const { result } = renderHook(() => useScreenWakeLock(true))
    expect(result.current).toEqual({ supported: false, failed: false })
  })

  it('reports a refused request while active, and not after deactivation', async () => {
    vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
    mockWakeLock(vi.fn().mockRejectedValue(new Error('Battery saver')))
    const { result, rerender } = renderHook(({ active }) => useScreenWakeLock(active), { initialProps: { active: true } })
    await waitFor(() => expect(result.current.failed).toBe(true))
    expect(result.current.supported).toBe(true)
    rerender({ active: false })
    expect(result.current.failed).toBe(false)
  })
})
