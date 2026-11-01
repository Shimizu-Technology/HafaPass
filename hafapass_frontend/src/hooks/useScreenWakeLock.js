import { useEffect, useState } from 'react'

export const screenWakeLockSupported = () => typeof navigator !== 'undefined' && Boolean(navigator.wakeLock?.request)

// Keeps the screen on while `active`. A late request must never retain a lock
// after deactivation, unmount, or after the document becomes hidden.
// Returns { supported, failed } so callers can suggest a manual screen setting
// when the browser has no Wake Lock API or refused the most recent request.
export default function useScreenWakeLock(active) {
  const [supported] = useState(screenWakeLockSupported)
  const [failed, setFailed] = useState(false)
  useEffect(() => {
    if (!active || !navigator.wakeLock?.request) return undefined
    let current = true
    let sentinel = null
    let pending = false
    let generation = 0
    let retryTimer = null
    let retries = 0
    const clearRetry = () => { clearTimeout(retryTimer); retryTimer = null }
    const release = lock => { try { Promise.resolve(lock?.release()).catch(() => {}) } catch { /* Optional browser feature. */ } }
    const request = async () => {
      if (!current || pending || sentinel || document.visibilityState !== 'visible') return
      const attempt = generation
      pending = true
      try {
        const lock = await navigator.wakeLock.request('screen')
        if (!current || attempt !== generation || document.visibilityState !== 'visible') release(lock)
        else {
          sentinel = lock
          setFailed(false)
          lock.addEventListener?.('release', () => {
            if (sentinel !== lock) return
            sentinel = null
            // Battery/browser policy can release a visible lock. Try once per
            // visibility period, without fighting a persistent power policy.
            if (current && document.visibilityState === 'visible' && retries < 1) {
              retries += 1
              retryTimer = setTimeout(() => { retryTimer = null; request() }, 1000)
            }
          }, { once: true })
        }
      } catch {
        // Denied, unsupported, or low battery: the page remains usable.
        if (current && attempt === generation) setFailed(true)
      } finally {
        pending = false
        if (current && attempt !== generation) request()
      }
    }
    const visibilityChanged = () => {
      clearRetry()
      if (document.visibilityState === 'visible') { retries = 0; request() }
      else { generation += 1; const lock = sentinel; sentinel = null; release(lock) }
    }
    request()
    document.addEventListener('visibilitychange', visibilityChanged)
    return () => {
      current = false
      clearRetry()
      generation += 1
      document.removeEventListener('visibilitychange', visibilityChanged)
      release(sentinel)
      sentinel = null
    }
  }, [active])
  return { supported, failed: Boolean(active && failed) }
}
