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

  it('resumes on every tap and replaces a context the browser refuses to resume', async () => {
    const contexts = []
    let refuse = false
    vi.stubGlobal('AudioContext', class {
      constructor() { this.state = 'running'; this.resumes = 0; this.closed = false; contexts.push(this) }
      resume() { this.resumes += 1; return refuse ? Promise.reject(new Error('interrupted')) : Promise.resolve() }
      close() { this.closed = true; return Promise.resolve() }
    })
    const { result } = renderHook(() => useScanSound())
    act(() => result.current.primeSound())
    act(() => result.current.primeSound())
    expect(contexts).toHaveLength(1)
    expect(contexts[0].resumes).toBe(2)
    // After an iOS interruption the old context will not resume.
    refuse = true
    await act(async () => { result.current.primeSound() })
    expect(contexts[0].closed).toBe(true)
    refuse = false
    act(() => result.current.primeSound())
    expect(contexts).toHaveLength(2)
    expect(contexts[1].resumes).toBe(1)
  })
})
