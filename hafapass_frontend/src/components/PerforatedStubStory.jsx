import { useEffect, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { CheckCircle2 } from 'lucide-react'
import useMotionOk from '../hooks/useMotionOk'
import { formatEventDate } from '../utils/eventTime'

// A QR-like pattern for the illustration (21 × 21 modules, three finder
// squares). It encodes nothing, so a phone camera pointed at it does nothing.
const QR_PATH = (() => {
  const finder = (x, y) => [[0, 0], [14, 0], [0, 14]].find(([fx, fy]) => x >= fx && x < fx + 7 && y >= fy && y < fy + 7)
  let path = ''
  for (let y = 0; y < 21; y += 1) {
    for (let x = 0; x < 21; x += 1) {
      const corner = finder(x, y)
      const on = corner
        ? (() => { const dx = x - corner[0]; const dy = y - corner[1]; return dx === 0 || dy === 0 || dx === 6 || dy === 6 || (dx >= 2 && dx <= 4 && dy >= 2 && dy <= 4) })()
        : (x * 7 + y * 13 + x * y) % 5 < 2
      if (on) path += `M${x} ${y}h1v1h-1z`
    }
  }
  return path
})()

const clamp01 = value => Math.min(1, Math.max(0, value))

/**
 * How a HåfaPass ticket works, told by one ticket: as the visitor scrolls,
 * the stub tears away along the perforation to show the QR and the green door
 * check. One rAF-throttled scroll handler writes a single `--tear` value;
 * scrolling back mends the ticket. Nothing is pinned and the scroll speed is
 * the browser's own. Without motion (reduced motion, short screens, before
 * the script runs) the finished state shows: torn stub, QR, admitted.
 */
export default function PerforatedStubStory({ event }) {
  const { t } = useTranslation()
  const motionOk = useMotionOk({ shortScreen: true })
  const root = useRef(null)
  const ticket = useRef(null)

  useEffect(() => {
    const section = root.current
    const visual = ticket.current
    if (!motionOk || !section || !visual) return undefined
    let frame = 0
    const update = () => {
      frame = 0
      const top = visual.getBoundingClientRect().top
      const height = window.innerHeight
      // Whole when the ticket's top is 85% down the screen, torn by the time it reaches 30%.
      const tear = clamp01((height * 0.85 - top) / (height * 0.55))
      visual.style.setProperty('--tear', tear.toFixed(3))
      const step = tear < 0.34 ? '1' : tear < 0.7 ? '2' : '3'
      if (section.dataset.step !== step) section.dataset.step = step
    }
    const schedule = () => { if (!frame) frame = requestAnimationFrame(update) }
    update()
    window.addEventListener('scroll', schedule, { passive: true })
    window.addEventListener('resize', schedule)
    return () => {
      cancelAnimationFrame(frame)
      window.removeEventListener('scroll', schedule)
      window.removeEventListener('resize', schedule)
      visual.style.removeProperty('--tear')
      section.dataset.step = 'done'
    }
  }, [motionOk])

  const steps = [
    [t('pass.home.storyPickTitle'), t('pass.home.storyPickBody')],
    [t('pass.home.storyPassTitle'), t('pass.home.storyPassBody')],
    [t('pass.home.storyDoorTitle'), t('pass.home.storyDoorBody')],
  ]
  return (
    <section ref={root} data-step="done" data-motion={motionOk ? 'on' : 'off'} aria-labelledby="stub-story-heading" className="stub-story grid items-center gap-10 py-12 sm:py-16 md:grid-cols-2 md:gap-16">
      <div>
        <h2 id="stub-story-heading" className="font-display text-2xl font-bold text-neutral-950 sm:text-3xl">{t('pass.home.storyTitle')}</h2>
        <ol className="mt-6 space-y-5">
          {steps.map(([title, body], index) => <li key={title} className="stub-story-step flex gap-4">
            <span aria-hidden="true" className="stub-story-marker flex h-10 w-10 shrink-0 items-center justify-center rounded-full border-2 font-display text-base font-bold">{index + 1}</span>
            <div className="min-w-0">
              <h3 className="font-display text-lg font-bold text-neutral-950">{title}</h3>
              <p className="mt-1 text-base leading-relaxed text-content-muted">{body}</p>
            </div>
          </li>)}
        </ol>
      </div>
      <div aria-hidden="true" className="mx-auto w-full max-w-[19rem] select-none">
        <div ref={ticket} className="ticket stub-story-ticket">
          <div className="ticket-notch ticket-top bg-white px-6 pb-6 pt-5">
            <p className="text-sm font-semibold text-brand-800">HåfaPass</p>
            <p className="mt-1 font-display text-xl font-bold leading-tight text-neutral-950 [overflow-wrap:anywhere]">{event?.title || t('pass.home.storyExampleEvent')}</p>
            {event?.starts_at && <p className="mt-1 text-sm text-content-muted">{formatEventDate(event.starts_at, event.timezone, { weekday: 'short', year: undefined })}</p>}
            <div className="ticket-tear" />
          </div>
          <div className="stub-story-stub ticket-notch ticket-stub bg-white px-6 pb-6 pt-5">
            <svg viewBox="-1 -1 23 23" className="stub-story-qr mx-auto block h-36 w-36" shapeRendering="crispEdges"><path d={QR_PATH} fill="#0f172a" /></svg>
            <p className="stub-story-check mx-auto mt-4 flex w-fit items-center gap-2 rounded-full bg-emerald-700 px-4 py-2 text-base font-semibold text-white">
              <CheckCircle2 className="h-5 w-5" />{t('pass.home.storyAdmitted')}
            </p>
          </div>
        </div>
      </div>
    </section>
  )
}
