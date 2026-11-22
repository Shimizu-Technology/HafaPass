import { useEffect, useRef } from 'react'
import apiClient from '../api/client'
import { getServerNow } from '../utils/serverClock'

// Re-check every 60s so laptop sleep or late clock syncs never miss a cutoff.
const MAX_TIMER_MS = 60_000

function cutoffMilliseconds(value) {
  const millis = Date.parse(value)
  // Round any microseconds up to the first eligible JavaScript timer tick.
  return millis + Number(/\.\d{3}\d*[1-9]\d*Z$/.test(value))
}

export default function usePricingScheduleRefresh(event, url, onRefresh) {
  const lastAutomaticRefresh = useRef(null)
  useEffect(() => {
    if (!url || !event?.server_now) return
    const schedules = (event.ticket_types || []).map(ticket => ticket.pricing_schedule).filter(Boolean)
    if (!schedules.length) return

    const controller = new AbortController()
    const snapshotTime = Date.parse(event.pricing_as_of || event.server_now)
    const cutoff = Math.min(...schedules.flatMap(schedule => {
      const scheduledChanges = [
        schedule.active_tier?.tier_type === 'time_based' ? schedule.active_tier.ends_at : null,
        schedule.next_tier?.starts_at,
      ].map(cutoffMilliseconds).filter(Number.isFinite)
      const salesBoundaries = [schedule.sales_start_at, schedule.sales_end_at]
        .map(cutoffMilliseconds).filter(value => value > snapshotTime)
      return [...scheduledChanges, ...salesBoundaries]
    }))
    let timeout
    let refreshing = false

    async function refresh(automaticKey = null) {
      if (refreshing || controller.signal.aborted) return
      refreshing = true
      try {
        const { data } = await apiClient.get(url, { signal: controller.signal })
        if (!controller.signal.aborted && data.slug === event.slug) {
          if (automaticKey) lastAutomaticRefresh.current = automaticKey
          onRefresh(data)
        }
      } catch {
        // Keep the current quote. A focus or visibility change can retry.
      } finally {
        refreshing = false
      }
    }

    function scheduleRefresh() {
      if (!Number.isFinite(cutoff)) return
      const delay = Math.ceil(cutoff - getServerNow())
      if (delay <= 0) {
        const key = `${url}:${cutoff}`
        if (lastAutomaticRefresh.current !== key) void refresh(key)
      } else {
        timeout = window.setTimeout(scheduleRefresh, Math.min(delay, MAX_TIMER_MS))
      }
    }

    const refreshWhenVisible = () => {
      if (!document.hidden) void refresh()
    }
    window.addEventListener('focus', refreshWhenVisible)
    document.addEventListener('visibilitychange', refreshWhenVisible)
    scheduleRefresh()
    return () => {
      controller.abort()
      window.clearTimeout(timeout)
      window.removeEventListener('focus', refreshWhenVisible)
      document.removeEventListener('visibilitychange', refreshWhenVisible)
    }
  }, [event, url, onRefresh])
}
