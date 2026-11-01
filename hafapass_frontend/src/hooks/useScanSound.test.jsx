import { act, renderHook } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import useScanSound, { SCANNER_SOUND_KEY } from './useScanSound'

describe('useScanSound', () => {
  afterEach(() => { vi.unstubAllGlobals(); window.localStorage.clear() })

  it('defaults to on and restores a saved Sound off choice', () => {
    expect(renderHook(() => useScanSound()).result.current.soundOn).toBe(true)
    window.localStorage.setItem(SCANNER_SOUND_KEY, 'off')
    expect(renderHook(() => useScanSound()).result.current.soundOn).toBe(false)
  })

  it('stays silent until a tap creates the audio context, and tolerates browsers without Web Audio', () => {
    const created = vi.fn()
    vi.stubGlobal('AudioContext', class { constructor() { created() } })
    const { result } = renderHook(() => useScanSound())
    expect(() => result.current.playScanSound('admit')).not.toThrow()
    expect(created).not.toHaveBeenCalled()
    vi.stubGlobal('AudioContext', undefined)
    expect(() => act(() => result.current.primeSound())).not.toThrow()
  })

  it('turning Sound back on persists and unlocks audio from that tap', () => {
    window.localStorage.setItem(SCANNER_SOUND_KEY, 'off')
    const created = vi.fn()
    vi.stubGlobal('AudioContext', class { constructor() { created(); this.state = 'running' } resume() { return Promise.resolve() } close() { return Promise.resolve() } })
    const { result } = renderHook(() => useScanSound())
    act(() => result.current.toggleSound())
    expect(result.current.soundOn).toBe(true)
    expect(window.localStorage.getItem(SCANNER_SOUND_KEY)).toBe('on')
    expect(created).toHaveBeenCalledTimes(1)
  })
})
