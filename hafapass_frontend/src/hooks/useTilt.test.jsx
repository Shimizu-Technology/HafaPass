import { act, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import useTilt from './useTilt'

// jsdom has no PointerEvent; without it fireEvent drops clientX, pointerId and pointerType.
class TestPointerEvent extends MouseEvent {
  constructor(type, init = {}) { super(type, init); this.pointerId = init.pointerId ?? 1; this.pointerType = init.pointerType ?? 'mouse' }
}

function Surface({ onOpen }) {
  const { ref, handlers } = useTilt({ enabled: true, touch: true })
  return <div data-testid="stage" {...handlers}><a ref={ref} href="#event" onClick={event => { event.preventDefault(); onOpen() }}>Event</a></div>
}
const stage = () => screen.getByTestId('stage')
const link = () => screen.getByRole('link', { name: 'Event' })
const touchDrag = (id = 7) => {
  fireEvent.pointerDown(stage(), { pointerType: 'touch', pointerId: id, clientX: 100, clientY: 100 })
  fireEvent.pointerMove(stage(), { pointerType: 'touch', pointerId: id, clientX: 170, clientY: 102 })
  fireEvent.pointerUp(stage(), { pointerType: 'touch', pointerId: id, clientX: 170, clientY: 102 })
}
// A pointer-generated click, as Chromium sends it: a PointerEvent naming its pointer.
const pointerClick = (pointerId, pointerType) => fireEvent(link(), new TestPointerEvent('click', { bubbles: true, cancelable: true, detail: 1, pointerId, pointerType }))

beforeEach(() => { window.PointerEvent = TestPointerEvent })
afterEach(() => { delete window.PointerEvent; vi.useRealTimers() })

describe('useTilt drag suppression', () => {
  it('swallows only the click produced by the pointer that dragged', () => {
    const open = vi.fn()
    render(<Surface onOpen={open} />)
    touchDrag(7)
    pointerClick(7, 'touch')
    expect(open).not.toHaveBeenCalled()
    pointerClick(7, 'touch')
    expect(open).toHaveBeenCalledOnce()
  })

  it('lets a mouse click through right after a touch drag that produced no click', () => {
    const open = vi.fn()
    render(<Surface onOpen={open} />)
    touchDrag(7)
    // A hybrid device: the mouse presses before the drag's 80 ms window ends.
    fireEvent.pointerDown(stage(), { pointerType: 'mouse', pointerId: 1, clientX: 20, clientY: 20 })
    pointerClick(1, 'mouse')
    expect(open).toHaveBeenCalledOnce()
  })

  it('lets a click from a different pointer through even without a new press', () => {
    const open = vi.fn()
    render(<Surface onOpen={open} />)
    touchDrag(7)
    pointerClick(9, 'touch')
    expect(open).toHaveBeenCalledOnce()
    touchDrag(8)
    pointerClick(8, 'mouse')
    expect(open).toHaveBeenCalledTimes(2)
  })

  it('lets a plain MouseEvent click without pointer metadata through during the suppression window', () => {
    const open = vi.fn()
    render(<Surface onOpen={open} />)
    touchDrag(7)
    fireEvent(link(), new MouseEvent('click', { bubbles: true, cancelable: true, detail: 1 }))
    expect(open).toHaveBeenCalledOnce()
  })

  it('always lets keyboard activation through', () => {
    const open = vi.fn()
    render(<Surface onOpen={open} />)
    touchDrag(7)
    fireEvent.click(link(), { detail: 0 })
    expect(open).toHaveBeenCalledOnce()
  })

  it('forgets the drag once its click window has passed', () => {
    vi.useFakeTimers()
    const open = vi.fn()
    render(<Surface onOpen={open} />)
    touchDrag(7)
    act(() => { vi.advanceTimersByTime(100) })
    pointerClick(7, 'touch')
    expect(open).toHaveBeenCalledOnce()
  })

  it('arms nothing for a vertical press or a cancelled drag', () => {
    const open = vi.fn()
    render(<Surface onOpen={open} />)
    fireEvent.pointerDown(stage(), { pointerType: 'touch', pointerId: 3, clientX: 100, clientY: 100 })
    fireEvent.pointerMove(stage(), { pointerType: 'touch', pointerId: 3, clientX: 102, clientY: 180 })
    fireEvent.pointerUp(stage(), { pointerType: 'touch', pointerId: 3, clientX: 102, clientY: 180 })
    pointerClick(3, 'touch')
    expect(open).toHaveBeenCalledOnce()
    fireEvent.pointerDown(stage(), { pointerType: 'touch', pointerId: 4, clientX: 100, clientY: 100 })
    fireEvent.pointerMove(stage(), { pointerType: 'touch', pointerId: 4, clientX: 170, clientY: 102 })
    fireEvent.pointerCancel(stage(), { pointerType: 'touch', pointerId: 4 })
    pointerClick(4, 'touch')
    expect(open).toHaveBeenCalledTimes(2)
  })
})
