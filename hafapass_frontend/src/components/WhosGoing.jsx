import { motion } from 'framer-motion'

const AVATAR_COLORS = [
  'bg-teal-500', 'bg-coral-500', 'bg-amber-500', 'bg-indigo-500',
  'bg-rose-500', 'bg-emerald-500', 'bg-sky-500', 'bg-purple-500'
]

function hashName(name) {
  let hash = 0
  for (let i = 0; i < name.length; i++) {
    hash = name.charCodeAt(i) + ((hash << 5) - hash)
  }
  return Math.abs(hash)
}

function getInitial(name) {
  return name?.charAt(0)?.toUpperCase() || '?'
}

function getColor(name) {
  return AVATAR_COLORS[hashName(name) % AVATAR_COLORS.length]
}

export default function WhosGoing({ attendeeCount, attendeesPreview, showAttendees }) {
  if (!showAttendees || !attendeeCount || attendeeCount === 0) return null

  const maxShow = 8
  const shown = (attendeesPreview || []).slice(0, maxShow)
  const remaining = attendeeCount - shown.length

  return (
    <div className="mb-8">
      <h2 className="text-lg font-semibold text-neutral-900 mb-3">Who's Going</h2>
      <div className="flex items-center gap-3">
        <div className="flex -space-x-2">
          {shown.map((name, i) => (
            <motion.div
              key={`${name}-${i}`}
              initial={{ opacity: 0, scale: 0.5 }}
              animate={{ opacity: 1, scale: 1 }}
              transition={{ duration: 0.3, delay: i * 0.06 }}
              className={`w-9 h-9 rounded-full flex items-center justify-center text-white text-sm font-bold border-2 border-white ${getColor(name)}`}
              title={name}
            >
              {getInitial(name)}
            </motion.div>
          ))}
          {remaining > 0 && (
            <motion.div
              initial={{ opacity: 0, scale: 0.5 }}
              animate={{ opacity: 1, scale: 1 }}
              transition={{ duration: 0.3, delay: shown.length * 0.06 }}
              className="w-9 h-9 rounded-full flex items-center justify-center bg-neutral-200 text-neutral-600 text-xs font-bold border-2 border-white"
            >
              +{remaining}
            </motion.div>
          )}
        </div>
        <p className="text-sm text-neutral-600 font-medium">
          {attendeeCount} {attendeeCount === 1 ? 'person' : 'people'} going
        </p>
      </div>
    </div>
  )
}

export function WhosGoingBadge({ attendeeCount }) {
  if (!attendeeCount || attendeeCount === 0) return null

  return (
    <div className="flex items-center gap-1.5 text-xs font-medium text-neutral-500">
      <svg className="w-3.5 h-3.5 text-neutral-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M2 9a3 3 0 0 1 0 6v2a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-2a3 3 0 0 1 0-6V7a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2Z" />
        <path d="M13 5v2" /><path d="M13 17v2" /><path d="M13 11v2" />
      </svg>
      <span>{attendeeCount} going</span>
    </div>
  )
}
