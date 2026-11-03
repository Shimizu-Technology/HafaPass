import { useEffect, useRef } from 'react'

const CHECK_MS = 2500
// Two checks with no new frame means the picture is frozen, not just still.
const STALLED_CHECKS = 2
// Stop retrying a camera that keeps failing; staff can tap Start camera.
const MAX_RESTARTS = 3
const RESTART_WINDOW_MS = 60_000

function liveTrack(video) {
  const stream = video?.srcObject
  const track = typeof stream?.getVideoTracks === 'function' ? stream.getVideoTracks()[0] : null
  return track && track.readyState === 'live' && !track.muted ? track : null
}

// A locked phone, an incoming call or a backgrounded tab can end the camera
// track or freeze the video without any error. While scanning, check the
// camera whenever the page is visible again and every few seconds, and
// restart it instead of leaving door staff with a frozen frame.
export default function useCameraRecovery({ scanning, videoRef, restart, onGiveUp }) {
  const restarts = useRef([])
  const handlers = useRef({ restart, onGiveUp })
  handlers.current = { restart, onGiveUp }

  useEffect(() => {
    if (!scanning) return undefined
    // Cleared on cleanup, so a check or play() rejection that settles after
    // staff stop the camera, switch events or leave can't restart anything.
    let active = true
    let playing = false
    let lastTime = null
    let stalled = 0

    const recover = () => {
      if (!active) return
      const now = Date.now()
      restarts.current = restarts.current.filter(time => now - time < RESTART_WINDOW_MS)
      if (restarts.current.length >= MAX_RESTARTS) {
        handlers.current.onGiveUp?.()
        return
      }
      restarts.current.push(now)
      handlers.current.restart()
    }

    const check = () => {
      if (!active || playing) return
      if (document.visibilityState !== 'visible') { lastTime = null; stalled = 0; return }
      const video = videoRef.current
      // Wait for the first stream instead of judging a camera still starting.
      if (!video?.srcObject) return
      if (!liveTrack(video) || video.ended) { recover(); return }
      if (video.paused) {
        // A paused but live stream usually just needs play() again. One
        // attempt at a time, and only for the stream that was paused.
        const stream = video.srcObject
        const attempt = video.play?.()
        if (!attempt?.then) return
        playing = true
        attempt.then(
          () => { playing = false },
          () => {
            playing = false
            if (active && videoRef.current?.srcObject === stream) recover()
          },
        )
        return
      }
      if (lastTime !== null && video.currentTime === lastTime) stalled += 1
      else stalled = 0
      lastTime = video.currentTime
      if (stalled >= STALLED_CHECKS) { stalled = 0; lastTime = null; recover() }
    }

    const onVisible = () => { lastTime = null; stalled = 0; check() }
    document.addEventListener('visibilitychange', onVisible)
    window.addEventListener('pageshow', onVisible)
    const timer = window.setInterval(check, CHECK_MS)
    return () => {
      active = false
      document.removeEventListener('visibilitychange', onVisible)
      window.removeEventListener('pageshow', onVisible)
      window.clearInterval(timer)
    }
  }, [scanning, videoRef])
}
