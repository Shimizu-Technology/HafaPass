import { useTranslation } from 'react-i18next'
import { motion, useReducedMotion } from 'framer-motion'

const AVATAR_COLORS = [
  'bg-teal-700', 'bg-accent-700', 'bg-amber-700', 'bg-indigo-700',
  'bg-rose-700', 'bg-emerald-700', 'bg-sky-700', 'bg-purple-700'
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
  const { t } = useTranslation()
  const reducedMotion = useReducedMotion()
  if (!showAttendees || !attendeeCount || attendeeCount === 0) return null

  const maxShow = 8
  const shown = (attendeesPreview || []).slice(0, maxShow)
  const remaining = attendeeCount - shown.length

  return (
    <div className="mb-8">
      <h2 className="text-lg font-semibold text-neutral-900 mb-3">{t('buyer.WhosGoing.whosGoing')}</h2>
      <div className="flex flex-wrap items-center gap-3">
        <div className="flex max-w-full -space-x-2">
          {shown.map((name, i) => (
            <motion.div
              key={`${name}-${i}`}
              initial={false}
              animate={{ opacity: 1, scale: 1 }}
              transition={{ duration: reducedMotion ? 0 : 0.3, delay: reducedMotion ? 0 : i * 0.06 }}
              className={`w-9 h-9 shrink-0 rounded-full flex items-center justify-center text-white text-sm font-bold border-2 border-white ${getColor(name)}`}
              title={name}
            >
              {getInitial(name)}
            </motion.div>
          ))}
          {remaining > 0 && (
            <motion.div
              initial={false}
              animate={{ opacity: 1, scale: 1 }}
              transition={{ duration: reducedMotion ? 0 : 0.3, delay: reducedMotion ? 0 : shown.length * 0.06 }}
              className="w-9 h-9 shrink-0 rounded-full flex items-center justify-center bg-neutral-200 text-neutral-600 text-xs font-bold border-2 border-white"
            >
              +{remaining}
            </motion.div>
          )}
        </div>
        <p className="text-sm text-neutral-600 font-medium break-words">
          {t('buyer.WhosGoing.peopleGoing', { count: attendeeCount })}</p>
      </div>
    </div>
  )
}

export function WhosGoingBadge({ attendeeCount }) {
  const { t } = useTranslation()
  if (!attendeeCount || attendeeCount === 0) return null

  return (
    <div className="flex items-center gap-1.5 text-xs font-medium text-neutral-500">
      <svg className="w-3.5 h-3.5 text-neutral-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M2 9a3 3 0 0 1 0 6v2a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-2a3 3 0 0 1 0-6V7a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2Z" />
        <path d="M13 5v2" /><path d="M13 17v2" /><path d="M13 11v2" />
      </svg>
      <span>{t('buyer.WhosGoing.countGoing', { count: attendeeCount })}</span>
    </div>
  )
}
