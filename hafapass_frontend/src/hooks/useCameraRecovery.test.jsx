import { act, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import useCameraRecovery from './useCameraRecovery'

function fakeVideo({ readyState = 'live', muted = false } = {}) {
  const track = { readyState, muted }
  return { track, srcObject: { getVideoTracks: () => [track] }, paused: false, ended: false, currentTime: 0, play: vi.fn(() => Promise.resolve()) }
}

function setVisibility(state) {
  Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => state })
  document.dispatchEvent(new Event('visibilitychange'))
}

beforeEach(() => { vi.useFakeTimers(); setVisibility('visible') })
afterEach(() => vi.useRealTimers())

it('restarts the camera when the track ended while the phone was locked', () => {
  const video = fakeVideo()
  const restart = vi.fn()
  renderHook(() => useCameraRecovery({ scanning: true, videoRef: { current: video }, restart }))
  setVisibility('hidden')
  video.track.readyState = 'ended'
  act(() => setVisibility('visible'))
  expect(restart).toHaveBeenCalledTimes(1)
})

it('restarts a frozen picture after two checks without a new frame', () => {
  const video = fakeVideo()
  const restart = vi.fn()
  renderHook(() => useCameraRecovery({ scanning: true, videoRef: { current: video }, restart }))
  act(() => vi.advanceTimersByTime(2500))
  video.currentTime = 1
  act(() => vi.advanceTimersByTime(2500))
  expect(restart).not.toHaveBeenCalled()
  act(() => vi.advanceTimersByTime(5000))
  expect(restart).toHaveBeenCalledTimes(1)
})

it('resumes a paused live stream without restarting it', () => {
  const video = fakeVideo()
  video.paused = true
  const restart = vi.fn()
  renderHook(() => useCameraRecovery({ scanning: true, videoRef: { current: video }, restart }))
  act(() => setVisibility('visible'))
  expect(video.play).toHaveBeenCalled()
  expect(restart).not.toHaveBeenCalled()
})

it('gives up after repeated failures so staff can restart by hand', () => {
  const video = fakeVideo({ readyState: 'ended' })
  const restart = vi.fn()
  const onGiveUp = vi.fn()
  renderHook(() => useCameraRecovery({ scanning: true, videoRef: { current: video }, restart, onGiveUp }))
  act(() => vi.advanceTimersByTime(2500 * 4))
  expect(restart).toHaveBeenCalledTimes(3)
  expect(onGiveUp).toHaveBeenCalled()
})

it('does nothing while the camera is off or the page is hidden', () => {
  const video = fakeVideo({ readyState: 'ended' })
  const restart = vi.fn()
  const { rerender } = renderHook(({ scanning }) => useCameraRecovery({ scanning, videoRef: { current: video }, restart }), { initialProps: { scanning: false } })
  act(() => vi.advanceTimersByTime(10000))
  setVisibility('hidden')
  rerender({ scanning: true })
  act(() => vi.advanceTimersByTime(10000))
  expect(restart).not.toHaveBeenCalled()
})

it('ignores a play() rejection that settles after the camera was stopped or replaced', async () => {
  const video = fakeVideo()
  video.paused = true
  let rejectPlay
  video.play = vi.fn(() => new Promise((_, reject) => { rejectPlay = reject }))
  const restart = vi.fn()
  const { rerender } = renderHook(({ scanning }) => useCameraRecovery({ scanning, videoRef: { current: video }, restart }), { initialProps: { scanning: true } })
  act(() => setVisibility('visible'))
  expect(video.play).toHaveBeenCalledTimes(1)
  act(() => vi.advanceTimersByTime(2500 * 3))
  expect(video.play).toHaveBeenCalledTimes(1)
  rerender({ scanning: false })
  await act(async () => { rejectPlay(new Error('interrupted')) })
  expect(restart).not.toHaveBeenCalled()
})

it('ignores a play() rejection for a stream that has since been replaced', async () => {
  const video = fakeVideo()
  video.paused = true
  let rejectPlay
  video.play = vi.fn(() => new Promise((_, reject) => { rejectPlay = reject }))
  const restart = vi.fn()
  renderHook(() => useCameraRecovery({ scanning: true, videoRef: { current: video }, restart }))
  act(() => setVisibility('visible'))
  video.srcObject = { getVideoTracks: () => [{ readyState: 'live', muted: false }] }
  await act(async () => { rejectPlay(new Error('interrupted')) })
  expect(restart).not.toHaveBeenCalled()
})
