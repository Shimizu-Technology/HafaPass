const TIME_ZONE = 'Pacific/Guam'
export const activityDateKey = value => new Intl.DateTimeFormat('en-CA', { timeZone: TIME_ZONE, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(value))

export function activityDay(value, now = new Date()) {
  const key = activityDateKey(value)
  if (key === activityDateKey(now)) return 'Today'
  if (key === activityDateKey(new Date(now.valueOf() - 86400000))) return 'Yesterday'
  return new Intl.DateTimeFormat('en-US', { timeZone: TIME_ZONE, month: 'short', day: 'numeric', ...(key.slice(0, 4) !== activityDateKey(now).slice(0, 4) ? { year: 'numeric' } : {}) }).format(new Date(value))
}

// API record links must stay within the app and contain no URL controls.
export const activityPath = value => typeof value === 'string' && value.startsWith('/') && !value.startsWith('//')
  && !value.includes('\\') && [...value].every(character => character.charCodeAt(0) > 32) ? value : null
