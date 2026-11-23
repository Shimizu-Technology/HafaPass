import { act, render, renderHook } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import useMotionOk, { SHORT_SCREEN_PX } from './useMotionOk'

const media = reduce => vi.stubGlobal('matchMedia', vi.fn(query => ({
  matches: reduce && query === '(prefers-reduced-motion: reduce)', addEventListener: vi.fn(), removeEventListener: vi.fn(),
})))
const setHeight = height => Object.defineProperty(window, 'innerHeight', { configurable: true, value: height })
const initialHeight = window.innerHeight

afterEach(() => { vi.unstubAllGlobals(); setHeight(initialHeight) })

describe('useMotionOk', () => {
  it('renders the still state first, then allows motion once mounted', () => {
    media(false)
    const seen = []
    function Probe() { seen.push(useMotionOk()); return null }
    render(<Probe />)
    expect(seen[0]).toBe(false)
    expect(seen.at(-1)).toBe(true)
  })

  it('stays still under reduced motion', () => {
    media(true)
    const { result } = renderHook(() => useMotionOk())
    expect(result.current).toBe(false)
  })

  it('keeps scroll moments still on short screens and follows a resize', () => {
    media(false)
    setHeight(SHORT_SCREEN_PX - 1)
    const { result } = renderHook(() => useMotionOk({ shortScreen: true }))
    expect(result.current).toBe(false)
    act(() => { setHeight(844); window.dispatchEvent(new Event('resize')) })
    expect(result.current).toBe(true)
    act(() => { setHeight(500); window.dispatchEvent(new Event('resize')) })
    expect(result.current).toBe(false)
  })

  it('ignores the screen height unless asked', () => {
    media(false)
    setHeight(400)
    const { result } = renderHook(() => useMotionOk())
    expect(result.current).toBe(true)
  })
})
