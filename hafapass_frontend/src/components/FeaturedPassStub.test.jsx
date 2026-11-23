import { act, fireEvent, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import FeaturedPassStub from './FeaturedPassStub'

const event = { id: 7, slug: 'reef-night', title: 'Reef night', starts_at: '2099-10-20T08:00:00Z', timezone: 'Pacific/Guam',
  venue_name: 'Ypao Beach Park', venue_city: 'Tumon', ticket_types: [{ price_cents: 2500, all_in_price_cents: 2725, quantity_remaining: 9, on_sale: true }] }
function Opened() { return <p>Opened {useLocation().pathname}</p> }
const mount = () => render(<MemoryRouter><Routes>
  <Route path="/" element={<FeaturedPassStub event={event} />} />
  <Route path="/events/:slug" element={<Opened />} />
</Routes></MemoryRouter>)
const reduceMotion = reduce => vi.stubGlobal('matchMedia', vi.fn(query => ({
  matches: reduce && query === '(prefers-reduced-motion: reduce)', addEventListener: vi.fn(), removeEventListener: vi.fn(),
})))
// jsdom has no PointerEvent; without it fireEvent drops clientX and pointerType.
class TestPointerEvent extends MouseEvent {
  constructor(type, init = {}) { super(type, init); this.pointerId = init.pointerId ?? 1; this.pointerType = init.pointerType ?? 'mouse' }
}
const REST = 'rotateX(4deg) rotateY(-9deg)'
const pass = () => screen.getByRole('link')
const box = { left: 0, top: 0, width: 200, height: 300, right: 200, bottom: 300 }

beforeEach(() => { window.PointerEvent = TestPointerEvent })
afterEach(() => { vi.unstubAllGlobals(); delete window.PointerEvent })

describe('FeaturedPassStub', () => {
  it('shows the real event as one link with its date, place and all-in price', () => {
    reduceMotion(false)
    mount()
    expect(pass()).toHaveAttribute('href', '/events/reef-night')
    expect(pass()).toHaveTextContent('Reef night')
    expect(pass()).toHaveTextContent('Guam time')
    expect(pass()).toHaveTextContent('Ypao Beach Park · Tumon')
    expect(pass()).toHaveTextContent('From $27.25')
    // Cover art is decorative; the title names the pass.
    expect(screen.queryByRole('img')).not.toBeInTheDocument()
  })

  it('opens the event from the keyboard', async () => {
    reduceMotion(false)
    mount()
    const user = userEvent.setup()
    await user.tab()
    expect(pass()).toHaveFocus()
    await user.keyboard('{Enter}')
    expect(screen.getByText('Opened /events/reef-night')).toBeInTheDocument()
  })

  it('leans toward a mouse and glides back to rest when it leaves', async () => {
    reduceMotion(false)
    mount()
    const stage = pass().parentElement
    stage.getBoundingClientRect = () => box
    fireEvent.pointerMove(stage, { pointerType: 'mouse', clientX: 200, clientY: 0 })
    await act(() => new Promise(resolve => setTimeout(resolve, 250)))
    expect(pass().style.transform).not.toBe(REST)
    fireEvent.pointerLeave(stage, { pointerType: 'mouse' })
    await act(() => new Promise(resolve => setTimeout(resolve, 1500)))
    expect(pass().style.transform).toBe(REST)
  })

  it('holds its resting pose under reduced motion', async () => {
    reduceMotion(true)
    mount()
    const stage = pass().parentElement
    stage.getBoundingClientRect = () => box
    fireEvent.pointerMove(stage, { pointerType: 'mouse', clientX: 200, clientY: 0 })
    await act(() => new Promise(resolve => setTimeout(resolve, 100)))
    expect(pass().style.transform).toBe(REST)
  })

  it('lets the keyboard open the pass after a drag that produced no click', () => {
    reduceMotion(false)
    mount()
    const stage = pass().parentElement
    fireEvent.pointerDown(stage, { pointerType: 'touch', pointerId: 2, clientX: 100, clientY: 100 })
    fireEvent.pointerMove(stage, { pointerType: 'touch', pointerId: 2, clientX: 170, clientY: 102 })
    fireEvent.pointerUp(stage, { pointerType: 'touch', pointerId: 2, clientX: 170, clientY: 102 })
    // Enter on a focused link is a click with no pointer behind it (detail 0).
    fireEvent.click(pass(), { detail: 0 })
    expect(screen.getByText('Opened /events/reef-night')).toBeInTheDocument()
  })

  it('forgets a cancelled drag, so the next tap opens', () => {
    reduceMotion(false)
    mount()
    const stage = pass().parentElement
    fireEvent.pointerDown(stage, { pointerType: 'touch', pointerId: 4, clientX: 100, clientY: 100 })
    fireEvent.pointerMove(stage, { pointerType: 'touch', pointerId: 4, clientX: 170, clientY: 102 })
    fireEvent.pointerCancel(stage, { pointerType: 'touch', pointerId: 4 })
    fireEvent.click(pass(), { detail: 1 })
    expect(screen.getByText('Opened /events/reef-night')).toBeInTheDocument()
  })

  it('keeps pinch zoom and scrolling while tilting, and leaves touch handling alone without motion', () => {
    reduceMotion(false)
    const view = mount()
    expect(pass().parentElement.style.touchAction).toBe('pan-y pinch-zoom')
    view.unmount()
    reduceMotion(true)
    mount()
    expect(pass().parentElement.getAttribute('style') || '').not.toContain('touch-action')
  })

  it('leaves an up-and-down finger drag to the page and still opens on a tap', () => {
    reduceMotion(false)
    mount()
    const stage = pass().parentElement
    fireEvent.pointerDown(stage, { pointerType: 'touch', pointerId: 1, clientX: 100, clientY: 100 })
    fireEvent.pointerMove(stage, { pointerType: 'touch', pointerId: 1, clientX: 104, clientY: 180 })
    fireEvent.pointerCancel(stage, { pointerType: 'touch', pointerId: 1 })
    expect(pass().style.transform).toBe(REST)
    fireEvent.click(pass())
    expect(screen.getByText('Opened /events/reef-night')).toBeInTheDocument()
  })
})
