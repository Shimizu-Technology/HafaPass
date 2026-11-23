import { useEffect, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { CheckCircle2 } from 'lucide-react'
import useMotionOk from '../hooks/useMotionOk'
import { formatEventDate } from '../utils/eventTime'

// Deterministic 21x21 non-scannable QR tiles with scatter poses (Tåno + Tåsi
// jigsaw feel, native to tickets). Finder corners settle first, then inner
// data modules wave diagonally into place.
const QR_SIZE = 21
const QR_TILES = (() => {
  const tiles = []
  const finder = (x, y) => [[0, 0], [14, 0], [0, 14]].find(([fx, fy]) => x >= fx && x < fx + 7 && y >= fy && y < fy + 7)
  let seed = 4219
  const rand = () => {
    seed = (seed * 1664525 + 1013904223) >>> 0
    return seed / 4294967296
  }
  for (let y = 0; y < QR_SIZE; y += 1) {
    for (let x = 0; x < QR_SIZE; x += 1) {
      const c = finder(x, y)
      const isFinder = Boolean(c)
      const on = c
        ? (x - c[0] === 0 || y - c[1] === 0 || x - c[0] === 6 || y - c[1] === 6 || (x - c[0] >= 2 && x - c[0] <= 4 && y - c[1] >= 2 && y - c[1] <= 4))
        : ((x * 7 + y * 13 + x * y) % 5 < 2)
      if (!on) continue
      const order = isFinder ? 0.05 + rand() * 0.15 : 0.18 + ((x + y) / (2 * QR_SIZE)) * 0.55 + rand() * 0.12
      tiles.push({
        gx: x,
        gy: y,
        isFinder,
        sx: x + (rand() - 0.5) * 14,
        sy: y + (rand() - 0.5) * 14,
        rot: (rand() - 0.5) * 2.4,
        start: Math.min(0.75, order),
        end: Math.min(0.98, order + 0.22),
      })
    }
  }
  return tiles
})()

const FOLLOW_MS = 80
const clamp01 = value => Math.min(1, Math.max(0, value))
const easeOut = t => 1 - Math.pow(1 - t, 3)
const easeInOut = t => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2)

function drawQrCanvas(canvas, progress) {
  if (!canvas) return
  let ctx
  try { ctx = canvas.getContext('2d') } catch { return }
  if (!ctx) return
  const w = canvas.width
  const pad = 12
  const cell = (w - pad * 2) / QR_SIZE
  ctx.clearRect(0, 0, w, w)
  for (const tile of QR_TILES) {
    const t = clamp01((progress - tile.start) / (tile.end - tile.start))
    const e = easeInOut(t)
    const cx = pad + (tile.sx + (tile.gx - tile.sx) * e + 0.5) * cell
    const cy = pad + (tile.sy + (tile.gy - tile.sy) * e + 0.5) * cell
    const rot = tile.rot * (1 - easeOut(t))
    const scale = 0.65 + 0.35 * e
    const alpha = 0.18 + 0.82 * Math.min(1, t * 1.6)
    ctx.save()
    ctx.globalAlpha = alpha
    ctx.translate(cx, cy)
    if (rot !== 0) ctx.rotate(rot)
    ctx.fillStyle = t < 0.85 ? (tile.isFinder ? '#0b6563' : '#0d9e96') : '#0f172a'
    const s = cell * scale * 0.96
    ctx.fillRect(-s / 2, -s / 2, s, s)
    ctx.restore()
  }
}

/**
 * Pinned 1.4svh scroll-driven "Tear → Assemble QR → Admitted" story.
 * Uses native scrolling with 80ms exponential smoothing and direct transform
 * writes (no inherited CSS variable recalculation). Falls back cleanly to the
 * unpinned finished state under reduced motion or short screens (<560px).
 */
export default function PerforatedStubStory({ event }) {
  const { t } = useTranslation()
  const motionOk = useMotionOk({ shortScreen: true })
  const sectionRef = useRef(null)
  const stickyRef = useRef(null)
  const stubRef = useRef(null)
  const perfRipRef = useRef(null)
  const scanBeamRef = useRef(null)
  const admitRef = useRef(null)
  const progressRef = useRef(null)
  const canvasRef = useRef(null)

  useEffect(() => {
    const section = sectionRef.current
    const sticky = stickyRef.current
    if (!section || !sticky) return undefined

    const stepNodes = Array.from(section.querySelectorAll('.stub-story-step'))

    const renderAt = p => {
      const rip = clamp01((p - 0.22) / 0.34)
      const tear = easeOut(clamp01((p - 0.28) / 0.42))
      const qrP = clamp01((p - 0.14) / 0.56)
      const scan = clamp01((p - 0.66) / 0.22)
      const admit = easeOut(clamp01((p - 0.80) / 0.16))

      if (perfRipRef.current) perfRipRef.current.style.transform = `scaleX(${rip.toFixed(3)})`
      if (stubRef.current) stubRef.current.style.transform = `translate3d(0, ${(tear * 24).toFixed(2)}px, 0) rotate(${(tear * 2.4).toFixed(2)}deg)`
      if (progressRef.current) progressRef.current.style.transform = `scaleX(${Math.max(0.04, p).toFixed(3)})`

      drawQrCanvas(canvasRef.current, qrP)

      if (scanBeamRef.current) {
        if (scan > 0 && scan < 1) {
          scanBeamRef.current.style.opacity = String((Math.sin(scan * Math.PI) * 0.95).toFixed(3))
          scanBeamRef.current.style.transform = `translate3d(0, ${(scan * 140).toFixed(1)}px, 0)`
        } else {
          scanBeamRef.current.style.opacity = '0'
        }
      }

      if (admitRef.current) {
        admitRef.current.style.opacity = String(admit.toFixed(3))
        admitRef.current.style.transform = `translate3d(0, ${((1 - admit) * 8).toFixed(1)}px, 0) scale(${(0.92 + admit * 0.08).toFixed(3)})`
      }

      const activeIdx = p < 0.34 ? 0 : p < 0.74 ? 1 : 2
      const stepVal = p >= 0.96 && !motionOk ? 'done' : String(activeIdx + 1)
      if (section.dataset.step !== stepVal) section.dataset.step = stepVal
      stepNodes.forEach((el, idx) => {
        el.dataset.active = String(idx === activeIdx)
        el.dataset.done = String(idx < activeIdx || p >= 0.96)
      })
    }

    if (!motionOk) {
      section.dataset.mode = 'still'
      section.dataset.step = 'done'
      renderAt(1)
      section.dataset.step = 'done'
      return undefined
    }

    section.dataset.mode = 'live'
    const measureProgress = () => {
      const travel = section.offsetHeight - sticky.offsetHeight
      if (travel <= 0) return 1
      const pinnedAt = parseFloat(window.getComputedStyle(sticky).top) || 0
      return clamp01((pinnedAt - section.getBoundingClientRect().top) / travel)
    }

    let target = measureProgress()
    let shown = target
    let raf = 0
    let last = 0
    renderAt(shown)

    const tick = now => {
      const step = 1 - Math.exp(-(now - last) / FOLLOW_MS)
      last = now
      shown += (target - shown) * step
      if (Math.abs(target - shown) < 0.0008) shown = target
      renderAt(shown)
      raf = shown === target ? 0 : requestAnimationFrame(tick)
    }

    const onScroll = () => {
      target = measureProgress()
      if (!raf) {
        last = performance.now()
        raf = requestAnimationFrame(tick)
      }
    }

    window.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('resize', onScroll)
    return () => {
      cancelAnimationFrame(raf)
      window.removeEventListener('scroll', onScroll)
      window.removeEventListener('resize', onScroll)
      section.dataset.mode = 'still'
      section.dataset.step = 'done'
    }
  }, [motionOk])

  const steps = [
    [t('pass.home.storyPickTitle'), t('pass.home.storyPickBody')],
    [t('pass.home.storyPassTitle'), t('pass.home.storyPassBody')],
    [t('pass.home.storyDoorTitle'), t('pass.home.storyDoorBody')],
  ]

  return (
    <section
      ref={sectionRef}
      data-testid="perforated-stub-story"
      data-mode={motionOk ? 'live' : 'still'}
      data-step="done"
      data-motion={motionOk ? 'on' : 'off'}
      aria-labelledby="stub-story-heading"
      className="stub-story-pinned mt-8"
    >
      <div ref={stickyRef} className="stub-story-sticky">
        <div className="stub-story-inner grid w-full max-w-5xl items-center gap-6 md:grid-cols-2 md:gap-14">
          <div>
            <p className="text-xs font-bold uppercase tracking-[0.08em] text-brand-700">How HåfaPass works</p>
            <h2 id="stub-story-heading" className="mt-2 font-display text-2xl font-bold leading-tight text-neutral-950 sm:text-3xl">{t('pass.home.storyTitle')}</h2>
            <ol className="stub-story-steps mt-5 space-y-3">
              {steps.map(([title, body], index) => (
                <li key={title} className="stub-story-step flex gap-3.5 rounded-2xl border border-transparent px-3.5 py-3" data-active={index === 2 ? 'true' : 'false'} data-done="true">
                  <span aria-hidden="true" className="stub-story-marker flex h-9 w-9 shrink-0 items-center justify-center rounded-full border-2 font-display text-sm font-bold">{index + 1}</span>
                  <div className="min-w-0">
                    <h3 className="font-display text-base font-bold text-neutral-950 sm:text-lg">{title}</h3>
                    <p className="stub-story-body mt-1 text-sm leading-relaxed text-content-muted">{body}</p>
                  </div>
                </li>
              ))}
            </ol>
            <div aria-hidden="true" className="mt-4 h-1 overflow-hidden rounded-full bg-neutral-200">
              <div ref={progressRef} className="h-full w-full origin-left bg-brand-500" style={{ transform: 'scaleX(1)' }} />
            </div>
          </div>

          <div aria-hidden="true" className="mx-auto w-full max-w-[19.5rem] select-none pb-7">
            <div className="ticket stub-story-ticket">
              <div className="ticket-notch ticket-top relative z-[2] !bg-brand-950 px-5 pb-5 pt-5 text-white shadow-card">
                <p className="text-[11px] font-bold uppercase tracking-[0.1em] text-brand-300">HåfaPass · Digital Pass</p>
                <p className="mt-1.5 font-display text-lg font-bold leading-tight [overflow-wrap:anywhere]">{event?.title || t('pass.home.storyExampleEvent')}</p>
                {event?.starts_at && <p className="mt-1 text-xs text-brand-100">{formatEventDate(event.starts_at, event.timezone, { weekday: 'short', year: undefined })}</p>}
                <div className="stub-perf-track">
                  <div ref={perfRipRef} className="stub-perf-rip" style={{ transform: 'scaleX(1)' }} />
                </div>
              </div>
              <div ref={stubRef} className="stub-story-stub-live ticket-notch ticket-stub relative z-[1] border border-t-0 border-neutral-200 bg-white px-5 pb-5 pt-5 text-center shadow-card" style={{ transform: 'translate3d(0, 24px, 0) rotate(2.4deg)' }}>
                <div className="relative mx-auto h-36 w-36 overflow-hidden rounded-xl border border-neutral-200 bg-white p-2 sm:h-40 sm:w-40">
                  <canvas ref={canvasRef} width={280} height={280} className="block h-full w-full" />
                  <div ref={scanBeamRef} className="stub-scan-beam" style={{ opacity: 0 }} />
                </div>
                <p ref={admitRef} className="mx-auto mt-3.5 inline-flex items-center gap-2 rounded-full bg-emerald-700 px-4 py-1.5 text-sm font-bold text-white" style={{ opacity: 1, transform: 'translate3d(0, 0, 0) scale(1)' }}>
                  <CheckCircle2 className="h-4 w-4" />
                  {t('pass.home.storyAdmitted')}
                </p>
                <p className="mt-1.5 text-xs tabular-nums text-content-muted">Avery Lindqvist · Ticket HP-DEMO</p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}
