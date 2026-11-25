import { DEFAULT_EVENT_TIME_ZONE } from './eventTime'

export const RE_ENTRY_ROLLOVER_HOUR = 5
const CUTOFF_TIME_RE = /^([01]\d|2[0-3]):([0-5]\d)$/

export function localDayString(value = Date.now(), timeZone = DEFAULT_EVENT_TIME_ZONE) {
  const date = value instanceof Date ? value : new Date(value)
  try {
    return new Intl.DateTimeFormat('en-CA', {
      timeZone: timeZone || DEFAULT_EVENT_TIME_ZONE,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
    }).format(date)
  } catch {
    return new Intl.DateTimeFormat('en-CA', {
      timeZone: DEFAULT_EVENT_TIME_ZONE,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
    }).format(date)
  }
}

function localDateTimeParts(value, timeZone = DEFAULT_EVENT_TIME_ZONE) {
  const date = value instanceof Date ? value : new Date(value)
  const tz = timeZone || DEFAULT_EVENT_TIME_ZONE
  const opts = {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }
  let parts
  try {
    parts = new Intl.DateTimeFormat('en-GB', { ...opts, timeZone: tz }).formatToParts(date)
  } catch {
    parts = new Intl.DateTimeFormat('en-GB', { ...opts, timeZone: DEFAULT_EVENT_TIME_ZONE }).formatToParts(date)
  }
  const get = type => Number(parts.find(p => p.type === type)?.value ?? 0)
  return {
    year: get('year'),
    month: get('month'),
    day: get('day'),
    hour: get('hour') % 24,
    minute: get('minute'),
  }
}

function addDaysToIsoDate(dateStr, days) {
  const [y, m, d] = String(dateStr).split('-').map(Number)
  const dt = new Date(Date.UTC(y, m - 1, d + days))
  return `${String(dt.getUTCFullYear()).padStart(4, '0')}-${String(dt.getUTCMonth() + 1).padStart(2, '0')}-${String(dt.getUTCDate()).padStart(2, '0')}`
}

function zonedWallClockToMs(dateStr, hour, minute, timeZone = DEFAULT_EVENT_TIME_ZONE) {
  const [year, month, day] = String(dateStr).split('-').map(Number)
  if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(day)) return Number.NaN
  const targetUtc = Date.UTC(year, month - 1, day, hour, minute, 0)
  let candidate = targetUtc
  for (let pass = 0; pass < 2; pass += 1) {
    const p = localDateTimeParts(candidate, timeZone)
    const renderedUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, 0)
    const diff = renderedUtc - targetUtc
    if (diff === 0) break
    candidate -= diff
  }
  return candidate
}

function isSingleSessionEvent(eventMeta) {
  const startMs = Date.parse(eventMeta?.starts_at || '')
  if (!Number.isFinite(startMs)) return false
  const endMs = Date.parse(eventMeta?.ends_at || '')
  return !Number.isFinite(endMs) || (endMs - startMs) <= 24 * 3_600_000
}

function singleSessionStartAnchorMs(eventMeta) {
  const startMs = Date.parse(eventMeta?.starts_at || '')
  const doorsMs = Date.parse(eventMeta?.doors_open_at || '')
  if (Number.isFinite(doorsMs) && Number.isFinite(startMs) && doorsMs < startMs) return doorsMs
  return startMs
}

export function eventRolloverHour(eventMeta = null) {
  if (Number.isInteger(eventMeta?.re_entry_rollover_hour)) return eventMeta.re_entry_rollover_hour
  if (isSingleSessionEvent(eventMeta)) {
    const anchorMs = singleSessionStartAnchorMs(eventMeta)
    const { hour } = localDateTimeParts(anchorMs, eventMeta?.timezone)
    if (hour < RE_ENTRY_ROLLOVER_HOUR) return hour
  }
  return RE_ENTRY_ROLLOVER_HOUR
}

// Mirrors Event#occupancy_day_for on the backend:
// Single-session events (<= 24 h, or missing ends_at treated as start + 24 h) keep one
// service day across midnight and past 05:00; multi-day events roll over at 05:00 local time.
export function serviceDayString(value = Date.now(), eventMeta = null) {
  const tz = eventMeta?.timezone || DEFAULT_EVENT_TIME_ZONE
  const ms = value instanceof Date ? value.getTime() : (typeof value === 'number' ? value : Date.parse(value))
  const effectiveMs = Number.isFinite(ms) ? ms : Date.now()
  if (isSingleSessionEvent(eventMeta)) {
    const startMs = Date.parse(eventMeta.starts_at)
    const endMs = Date.parse(eventMeta?.ends_at || '')
    const windowStart = singleSessionStartAnchorMs(eventMeta) - 6 * 3_600_000
    const windowEnd = Number.isFinite(endMs) ? (endMs + 6 * 3_600_000) : (startMs + 24 * 3_600_000)
    if (effectiveMs >= windowStart && effectiveMs <= windowEnd) {
      return localDayString(startMs, tz)
    }
  }
  return localDayString(effectiveMs - RE_ENTRY_ROLLOVER_HOUR * 3_600_000, tz)
}

export function formatGateTime(isoOrMs, timeZone = DEFAULT_EVENT_TIME_ZONE) {
  if (!isoOrMs) return null
  const date = isoOrMs instanceof Date ? isoOrMs : new Date(isoOrMs)
  if (!Number.isFinite(date.getTime())) return null
  try {
    return new Intl.DateTimeFormat('en-US', {
      timeZone: timeZone || DEFAULT_EVENT_TIME_ZONE,
      hour: 'numeric',
      minute: '2-digit',
    }).format(date)
  } catch {
    return new Intl.DateTimeFormat('en-US', {
      timeZone: DEFAULT_EVENT_TIME_ZONE,
      hour: 'numeric',
      minute: '2-digit',
    }).format(date)
  }
}

export function formatCutoffTime(hhmm) {
  const match = CUTOFF_TIME_RE.exec(String(hhmm || '').trim())
  if (!match) return null
  const hour24 = Number(match[1])
  const minute = match[2]
  const period = hour24 >= 12 ? 'PM' : 'AM'
  const hour12 = hour24 % 12 || 12
  return `${hour12}:${minute} ${period}`
}

// Mirrors Event#re_entry_cutoff_for_day on the backend so client and server agree
// before, during, and after single-session or multi-day events.
export function cutoffTimestampMs(dayStr, eventMeta) {
  const cutoffTime = eventMeta?.re_entry_cutoff_time
  const match = CUTOFF_TIME_RE.exec(String(cutoffTime || '').trim())
  if (!match || !dayStr) return null

  const tz = eventMeta?.timezone || DEFAULT_EVENT_TIME_ZONE
  const cutHour = Number(match[1])
  const cutMin = Number(match[2])

  if (isSingleSessionEvent(eventMeta)) {
    const startMs = Date.parse(eventMeta.starts_at)
    if (dayStr === localDayString(startMs, tz)) {
      const anchorMs = singleSessionStartAnchorMs(eventMeta)
      const anchorDateStr = localDayString(anchorMs, tz)
      let candidate = zonedWallClockToMs(anchorDateStr, cutHour, cutMin, tz)
      if (Number.isFinite(candidate) && candidate < anchorMs) {
        candidate = zonedWallClockToMs(addDaysToIsoDate(anchorDateStr, 1), cutHour, cutMin, tz)
      }
      return Number.isFinite(candidate) ? candidate : null
    }
  }

  const targetDateStr = cutHour < RE_ENTRY_ROLLOVER_HOUR ? addDaysToIsoDate(dayStr, 1) : dayStr
  const cutoffMs = zonedWallClockToMs(targetDateStr, cutHour, cutMin, tz)
  return Number.isFinite(cutoffMs) ? cutoffMs : null
}

export function isCutoffPassed(nowMs, eventMeta, dayStr = null) {
  const day = dayStr || serviceDayString(nowMs, eventMeta)
  const cutoffMs = cutoffTimestampMs(day, eventMeta)
  return Number.isFinite(cutoffMs) && nowMs > cutoffMs
}

export function effectiveLocalTicketState(manifestTicket, localState, eventMeta, nowMs = Date.now()) {
  const today = serviceDayString(nowMs, eventMeta)

  const manifestTs = Math.max(
    Date.parse(manifestTicket?.last_entry_at || '') || 0,
    Date.parse(manifestTicket?.last_exit_at || '') || 0,
  )
  const localTs = Date.parse(localState?.occurred_at || '') || 0
  const useLocal = Boolean(localState && localTs >= manifestTs && localState.occupancy_state)

  const occupancyDay = useLocal
    ? (localState.occupancy_day || (localTs ? serviceDayString(localTs, eventMeta) : null))
    : (manifestTicket?.occupancy_day || (manifestTs ? serviceDayString(manifestTs, eventMeta) : null))

  const sameDay = Boolean(occupancyDay && occupancyDay === today)
  const rawState = useLocal ? localState.occupancy_state : (manifestTicket?.occupancy_state || (manifestTicket?.state === 'admitted' ? 'inside' : 'outside'))
  const rawReEntryCount = useLocal ? Number(localState.re_entry_count || 0) : Number(manifestTicket?.re_entry_count || 0)
  const lastEntryAt = useLocal ? (localState.last_entry_at || manifestTicket?.last_entry_at || null) : (manifestTicket?.last_entry_at || null)
  const lastEntryGate = useLocal ? (localState.last_entry_gate || manifestTicket?.last_entry_gate || null) : (manifestTicket?.last_entry_gate || null)

  return {
    today,
    enteredToday: sameDay && (Boolean(lastEntryAt) || rawState === 'inside' || manifestTicket?.state === 'admitted' || localState?.status === 'accepted' || localState?.status === 'pending' || localState?.status === 'exited' || localState?.status === 'exited_pending'),
    occupancyState: sameDay ? rawState : 'outside',
    reEntryCount: sameDay ? rawReEntryCount : 0,
    lastEntryAt: sameDay ? lastEntryAt : null,
    lastEntryGate: sameDay ? lastEntryGate : null,
  }
}

export function evaluateLocalReEntry({ kind = 'admit', manifestTicket, localState, eventMeta, nowMs = Date.now() }) {
  const mode = eventMeta?.re_entry_mode || 'off'
  const tz = eventMeta?.timezone || DEFAULT_EVENT_TIME_ZONE
  if (mode === 'off') return { allowed: true, isReEntry: false, reEntryNumber: 0 }

  // Base non-admitted blocks still apply
  if (manifestTicket?.state && !['valid', 'admitted'].includes(manifestTicket.state)) {
    return { allowed: false, type: 'error', reasonCode: manifestTicket.state }
  }

  const effective = effectiveLocalTicketState(manifestTicket, localState, eventMeta, nowMs)

  if (kind === 'exit') {
    if (mode !== 'exit_scan') {
      return { allowed: false, type: 'error', reasonCode: 're_entry_exit_not_used' }
    }
    if (effective.occupancyState !== 'inside') {
      return { allowed: false, type: 'warning', reasonCode: 'not_inside', details: { occupancy_state: effective.occupancyState } }
    }
    return { allowed: true, isReEntry: false, reEntryNumber: effective.reEntryCount }
  }

  // Entry scan
  if (mode === 'exit_scan') {
    if (effective.occupancyState === 'inside') {
      return {
        allowed: false,
        type: 'warning',
        reasonCode: 'already_inside',
        details: {
          prior_entry_at: effective.lastEntryAt,
          prior_gate_name: effective.lastEntryGate,
        },
      }
    }
    if (effective.enteredToday) {
      if (isCutoffPassed(nowMs, eventMeta, effective.today)) {
        return {
          allowed: false,
          type: 'error',
          reasonCode: 're_entry_cutoff_passed',
          details: { cutoff_time: eventMeta?.re_entry_cutoff_time, timezone: tz },
        }
      }
      const maxCount = eventMeta?.re_entry_max_count
      if (maxCount != null && effective.reEntryCount >= Number(maxCount)) {
        return {
          allowed: false,
          type: 'error',
          reasonCode: 're_entry_limit_reached',
          details: { re_entry_count: effective.reEntryCount, re_entry_max_count: Number(maxCount) },
        }
      }
      return { allowed: true, isReEntry: true, reEntryNumber: effective.reEntryCount + 1 }
    }
    return { allowed: true, isReEntry: false, reEntryNumber: 0 }
  }

  // Cool-down mode
  if (!effective.enteredToday) {
    return { allowed: true, isReEntry: false, reEntryNumber: 0 }
  }

  const cooldownMin = Number(eventMeta?.re_entry_cooldown_minutes || 15)
  const lastEntryMs = Date.parse(effective.lastEntryAt || '')
  if (Number.isFinite(lastEntryMs)) {
    const elapsedMs = nowMs - lastEntryMs
    const cooldownMs = cooldownMin * 60_000
    if (elapsedMs < cooldownMs) {
      const elapsedMinutes = Math.max(0, Math.floor(elapsedMs / 60_000))
      const remainingMinutes = Math.max(1, Math.ceil((cooldownMs - elapsedMs) / 60_000))
      return {
        allowed: false,
        type: 'warning',
        reasonCode: 'cooldown_active',
        details: {
          prior_entry_at: effective.lastEntryAt,
          prior_gate_name: effective.lastEntryGate,
          cooldown_minutes: cooldownMin,
          elapsed_minutes: elapsedMinutes,
          remaining_minutes: remainingMinutes,
          retry_after_at: new Date(lastEntryMs + cooldownMs).toISOString(),
        },
      }
    }
  }

  if (isCutoffPassed(nowMs, eventMeta, effective.today)) {
    return {
      allowed: false,
      type: 'error',
      reasonCode: 're_entry_cutoff_passed',
      details: { cutoff_time: eventMeta?.re_entry_cutoff_time, timezone: tz },
    }
  }
  const maxCount = eventMeta?.re_entry_max_count
  if (maxCount != null && effective.reEntryCount >= Number(maxCount)) {
    return {
      allowed: false,
      type: 'error',
      reasonCode: 're_entry_limit_reached',
      details: { re_entry_count: effective.reEntryCount, re_entry_max_count: Number(maxCount) },
    }
  }

  return { allowed: true, isReEntry: true, reEntryNumber: effective.reEntryCount + 1 }
}

export function formatReEntryFeedback(reasonCode, details = {}, timezone = DEFAULT_EVENT_TIME_ZONE) {
  const gateTime = formatGateTime(details?.prior_entry_at, timezone)
  const gateName = details?.prior_gate_name

  switch (reasonCode) {
    case 'already_inside': {
      const whenWhere = [gateTime ? `at ${gateTime}` : null, gateName ? `at ${gateName}` : null].filter(Boolean).join(' ')
      return {
        type: 'warning',
        soundKind: 'already_inside',
        headline: 'Already inside',
        message: whenWhere ? `Already inside — scanned in ${whenWhere}` : 'Already inside',
        detail: 'This ticket is already checked in. Have the guest scan out at Exit first, or ask a scanner lead.',
        overridable: true,
      }
    }
    case 'not_inside':
      return {
        type: 'warning',
        soundKind: 'refuse',
        headline: 'Not inside',
        message: 'Not inside — cannot scan out',
        detail: 'This ticket has not scanned in yet or already scanned out.',
        overridable: true,
      }
    case 'cooldown_active': {
      const elapsed = details?.elapsed_minutes
      const remaining = details?.remaining_minutes
      const elapsedText = elapsed != null ? (elapsed === 0 ? 'just now' : `${elapsed} min ago`) : 'recently'
      const waitText = remaining != null ? `wait ${remaining} min` : 'wait'
      return {
        type: 'warning',
        soundKind: 'already_inside',
        headline: 'Wait to re-enter',
        message: `Scanned ${elapsedText} — ${waitText}`,
        detail: `${gateName ? `Last scanned at ${gateName}${gateTime ? ` (${gateTime})` : ''}. ` : ''}Cool-down is ${details?.cooldown_minutes || 15} min between entries.`,
        overridable: true,
      }
    }
    case 're_entry_limit_reached':
      return {
        type: 'error',
        soundKind: 'refuse',
        headline: 'Re-entry limit reached',
        message: 'Re-entry limit reached',
        detail: details?.re_entry_max_count
          ? `Used ${details.re_entry_count ?? details.re_entry_max_count} of ${details.re_entry_max_count} allowed re-entries.`
          : 'This ticket has used all allowed re-entries.',
        overridable: true,
      }
    case 're_entry_cutoff_passed': {
      const cutoffTime = formatCutoffTime(details?.cutoff_time) || formatGateTime(details?.cutoff_at, timezone)
      return {
        type: 'error',
        soundKind: 'refuse',
        headline: 'Re-entry closed',
        message: cutoffTime ? `Re-entry cutoff passed (${cutoffTime})` : 'Re-entry cutoff passed',
        detail: 'Re-entry is closed for today. Ask a scanner lead for exceptions.',
        overridable: true,
      }
    }
    case 'admit_before_latest_exit': {
      const exitTime = formatGateTime(details?.last_exit_at, timezone)
      return {
        type: 'warning',
        soundKind: 'already_inside',
        headline: 'Out-of-order offline scan',
        message: exitTime ? `Ticket already exited at ${exitTime}` : 'Offline entry predates a recorded exit',
        detail: 'Flagged for scanner lead review; the guest remains marked outside.',
        overridable: true,
      }
    }
    case 're_entry_disabled':
    case 're_entry_exit_not_used':
      return {
        type: 'error',
        soundKind: 'refuse',
        headline: 'Exit scan not enabled',
        message: 'Exit scan is not enabled for this event',
        detail: 'Switch back to Entry mode or check the event’s re-entry setting.',
        overridable: false,
      }
    default:
      return null
  }
}
