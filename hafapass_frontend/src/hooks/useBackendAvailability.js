import { useCallback, useEffect, useRef, useState } from 'react'

const PROBE_TIMEOUT_MS = 7_000
const RETRY_INTERVAL_MS = 30_000

export function useBackendAvailability(healthUrl) {
  const [status, setStatus] = useState('checking')
  const requestId = useRef(0)

  const check = useCallback(async (showChecking = true) => {
    const currentRequest = ++requestId.current
    if (showChecking) setStatus('checking')
    const controller = new AbortController()
    const timeout = window.setTimeout(() => controller.abort(), PROBE_TIMEOUT_MS)

    try {
      const response = await fetch(healthUrl, {
        cache: 'no-store',
        headers: { Accept: 'application/json, text/plain' },
        signal: controller.signal,
      })
      if (requestId.current === currentRequest) setStatus(response.ok ? 'available' : 'unavailable')
    } catch {
      if (requestId.current === currentRequest) setStatus('unavailable')
    } finally {
      window.clearTimeout(timeout)
    }
  }, [healthUrl])

  useEffect(() => {
    void check()
    return () => { requestId.current += 1 }
  }, [check])

  useEffect(() => {
    if (status !== 'unavailable') return undefined
    const interval = window.setInterval(() => void check(false), RETRY_INTERVAL_MS)
    return () => window.clearInterval(interval)
  }, [check, status])

  return { status, retry: () => check() }
}
