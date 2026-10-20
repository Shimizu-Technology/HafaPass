// Small scale helpers for the organizer charts. No chart library: the charts
// are single-series columns and bars, so a few lines of math are enough.

// A round axis maximum at or above `max`, e.g. 37 -> 40, 1840 -> 2000.
export function niceMax(max) {
  if (!Number.isFinite(max) || max <= 0) return 1
  const exponent = Math.floor(Math.log10(max))
  const base = 10 ** exponent
  const step = [1, 2, 2.5, 5, 10].find(multiplier => multiplier * base >= max)
  return step * base
}

function niceStep(rough, integer) {
  const exponent = Math.floor(Math.log10(rough))
  const base = 10 ** exponent
  const multipliers = integer ? [1, 2, 5, 10] : [1, 2, 2.5, 5, 10]
  const step = multipliers.find(multiplier => multiplier * base >= rough) * base
  return integer ? Math.max(1, Math.round(step)) : step
}

// Round ticks from 0 up to the first step at or above `max`. Whole-number
// axes (ticket counts) never get fractional ticks.
export function axisTicks(max, { count = 4, integer = false } = {}) {
  const safeMax = Number.isFinite(max) && max > 0 ? max : 1
  const step = niceStep(niceMax(safeMax) / count, integer)
  const top = Math.max(step, Math.ceil(safeMax / step) * step)
  const ticks = []
  for (let value = 0; value <= top + step / 1000; value += step) ticks.push(integer ? Math.round(value) : Number(value.toPrecision(12)))
  return ticks
}

// Compact axis label: 0 / 950 / 1.2K / 3M.
export function compactNumber(value) {
  return new Intl.NumberFormat('en-US', { notation: 'compact', maximumFractionDigits: 1 }).format(value)
}

// A YYYY-MM-DD calendar day (already in the event's timezone) as "Oct 3".
// UTC keeps the browser's own timezone from shifting the day.
export function formatDay(day, options = { month: 'short', day: 'numeric' }) {
  const date = new Date(`${day}T00:00:00Z`)
  if (Number.isNaN(date.getTime())) return day
  return date.toLocaleDateString('en-US', { ...options, timeZone: 'UTC' })
}

// Indexes of the x-axis labels to show: always the first and last, plus
// evenly spaced ones in between, never more than `maxLabels`.
export function labelIndexes(length, maxLabels) {
  if (length <= 0) return []
  if (length <= maxLabels) return Array.from({ length }, (_, index) => index)
  const slots = Math.max(2, maxLabels)
  const indexes = new Set([0, length - 1])
  for (let slot = 1; slot < slots - 1; slot += 1) indexes.add(Math.round((slot * (length - 1)) / (slots - 1)))
  return [...indexes].sort((a, b) => a - b)
}
