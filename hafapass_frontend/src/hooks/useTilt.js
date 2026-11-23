import { useCallback, useEffect, useRef } from 'react'

// The pose eases toward its target: the remaining distance falls by e every FOLLOW_MS.
const FOLLOW_MS = 110
const SETTLE_DEG = 0.02
// A press must travel this far sideways before a finger takes over the tilt.
const DRAG_SLOP = 6
// The click a dragging gesture itself produces arrives right after the let-go.
const DRAG_CLICK_MS = 80
const REST_FLAT = Object.freeze({ x: 0, y: 0 })
const clamp = (value, limit) => Math.max(-limit, Math.min(limit, value))

/**
 * A card that leans toward a mouse pointer and, with `touch`, follows a
 * sideways finger drag, then glides back to its resting pose when let go
 * (modelled on tano-y-tasi's SpinBox). While enabled, the surface keeps
 * vertical scrolling and pinch zoom (`touch-action: pan-y pinch-zoom`);
 * disabled, the browser's own touch handling is untouched. Only the click a
 * dragging gesture produces is swallowed; keyboard and assistive-technology
 * activation always go through. The pose is written straight to the
 * element's transform from one rAF loop that stops once settled; React never
 * re-renders per frame. Disabled, the card holds its resting pose.
 */
export default function useTilt({ enabled, max = 8, rest = REST_FLAT, touch = false }) {
  const ref = useRef(null)
  const sheenRef = useRef(null)
  const pose = useRef({ x: rest.x, y: rest.y, tx: rest.x, ty: rest.y })
  const frame = useRef(0)
  const drag = useRef(null)
  const dragged = useRef(false)
  const forget = useRef(0)
  const clearDragged = useCallback(() => {
    clearTimeout(forget.current)
    dragged.current = false
  }, [])

  const paint = useCallback(() => {
    const { x, y } = pose.current
    if (ref.current) ref.current.style.transform = `rotateX(${Number(x.toFixed(2))}deg) rotateY(${Number(y.toFixed(2))}deg)`
    // The highlight slides opposite the lean, like light across foil.
    if (sheenRef.current) sheenRef.current.style.transform = `translateX(${(-(y - rest.y) / max * 35).toFixed(1)}%)`
  }, [max, rest.y])

  const stop = useCallback(() => {
    cancelAnimationFrame(frame.current)
    frame.current = 0
  }, [])

  const run = useCallback(() => {
    if (frame.current) return
    let last = performance.now()
    const tick = now => {
      const dt = Math.min(now - last, 64)
      last = now
      const state = pose.current
      const follow = 1 - Math.exp(-dt / FOLLOW_MS)
      state.x += (state.tx - state.x) * follow
      state.y += (state.ty - state.y) * follow
      const settled = Math.abs(state.tx - state.x) < SETTLE_DEG && Math.abs(state.ty - state.y) < SETTLE_DEG
      if (settled) { state.x = state.tx; state.y = state.ty }
      paint()
      frame.current = settled && !drag.current ? 0 : requestAnimationFrame(tick)
    }
    frame.current = requestAnimationFrame(tick)
  }, [paint])

  const aim = useCallback((x, y) => {
    pose.current.tx = x
    pose.current.ty = y
    run()
  }, [run])
  const settle = useCallback(() => aim(rest.x, rest.y), [aim, rest.x, rest.y])

  // Turning motion off mid-glide snaps to the resting pose at once.
  useEffect(() => {
    if (enabled) return undefined
    stop()
    drag.current = null
    Object.assign(pose.current, { x: rest.x, y: rest.y, tx: rest.x, ty: rest.y })
    paint()
    return undefined
  }, [enabled, paint, rest.x, rest.y, stop])
  useEffect(() => () => { stop(); clearTimeout(forget.current) }, [stop])

  // A let-go keeps the drag's flag only long enough to swallow its own click;
  // a cancelled press produces no click, so nothing is left to swallow.
  function release(event, cancelled = false) {
    if (drag.current?.id !== event.pointerId) return
    drag.current = null
    settle()
    clearTimeout(forget.current)
    if (cancelled || !dragged.current) { dragged.current = false; return }
    forget.current = window.setTimeout(() => { dragged.current = false }, DRAG_CLICK_MS)
  }

  const handlers = !enabled ? {} : {
    onPointerMove: event => {
      if (event.pointerType === 'mouse') {
        const rect = event.currentTarget.getBoundingClientRect()
        if (!rect.width || !rect.height) return
        const px = ((event.clientX - rect.left) / rect.width) * 2 - 1
        const py = ((event.clientY - rect.top) / rect.height) * 2 - 1
        aim(rest.x - clamp(py, 1) * max * 0.75, rest.y + clamp(px, 1) * max)
        return
      }
      const state = drag.current
      if (!state || state.id !== event.pointerId) return
      const dx = event.clientX - state.x
      const dy = event.clientY - state.y
      if (!state.moved) {
        if (Math.abs(dx) < DRAG_SLOP) return
        // A mostly vertical press is a scroll; leave it to the page.
        if (Math.abs(dy) > Math.abs(dx)) { drag.current = null; return }
        state.moved = true
        dragged.current = true
      }
      aim(rest.x - clamp(dy * 0.12, max), rest.y + clamp(dx * 0.22, max * 1.6))
    },
    onPointerLeave: event => { if (event.pointerType === 'mouse') settle() },
    onPointerDown: event => {
      if (!touch || event.pointerType === 'mouse' || drag.current) return
      drag.current = { id: event.pointerId, x: event.clientX, y: event.clientY, moved: false }
      clearDragged()
    },
    onPointerUp: event => release(event),
    onPointerCancel: event => release(event, true),
    onLostPointerCapture: event => release(event, true),
    // A drag that ends over a link must not follow it. Keyboard and assistive
    // technology clicks report no pointer (detail 0) and always go through.
    onClickCapture: event => {
      const swallow = dragged.current && event.detail !== 0
      clearDragged()
      if (!swallow) return
      event.preventDefault()
      event.stopPropagation()
    },
    style: touch ? { touchAction: 'pan-y pinch-zoom' } : undefined,
  }

  return { ref, sheenRef, handlers }
}
