// Guam has a fixed UTC+10 offset. Compare calendar days, not rolling 7-day windows.
const dayMs = 86400000
const guamDay = value => Math.floor((new Date(value).getTime() + 10 * 3600000) / dayMs)
export function matchesGuamWindow(startsAt, window, now = new Date()) {
  const today = guamDay(now)
  const day = guamDay(startsAt)
  if (!Number.isFinite(day)) return false
  if (window === 'tonight') return day === today
  if (window === 'weekend') {
    const weekday = new Date(today * dayMs).getUTCDay()
    const friday = today + (weekday === 0 ? -2 : weekday === 6 ? -1 : (5 - weekday + 7) % 7)
    return day >= friday && day < friday + 3
  }
  return true
}
