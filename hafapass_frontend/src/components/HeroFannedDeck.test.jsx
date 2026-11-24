import { act, fireEvent, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import HeroFannedDeck from './HeroFannedDeck'

const reduceMotion = reduce => vi.stubGlobal('matchMedia', vi.fn(query => ({
  matches: reduce && query === '(prefers-reduced-motion: reduce)',
  addEventListener: vi.fn(),
  removeEventListener: vi.fn(),
})))

const sampleEvents = [
  {
    id: 1,
    slug: 'copa-2027',
    title: 'Copa de Marianas 2027 (demo)',
    is_featured: true,
    starts_at: '2027-01-30T08:00:00+10:00',
    timezone: 'Pacific/Guam',
    venue_name: 'UOG Calvo Field House',
    venue_city: 'Mangilao',
    ticket_types: [
      { id: 11, price_cents: 0, all_in_price_cents: 0, quantity_remaining: 50, on_sale: true },
      { id: 12, price_cents: 1000, all_in_price_cents: 1150, quantity_remaining: 50, on_sale: true },
    ],
  },
  {
    id: 2,
    slug: 'fd-night-1',
    title: 'FD Alumni Basketball — Night 1 (demo)',
    is_featured: true,
    starts_at: '2027-02-12T17:30:00+10:00',
    timezone: 'Pacific/Guam',
    venue_name: 'Phoenix Center Gym',
    venue_city: 'Mangilao',
    ticket_types: [
      { id: 21, price_cents: 1200, all_in_price_cents: 1360, quantity_remaining: 50, on_sale: true },
    ],
  },
  {
    id: 3,
    slug: 'tumon-acoustic',
    title: 'Tumon Bay Acoustic Sessions (demo)',
    starts_at: '2027-02-20T18:00:00+10:00',
    timezone: 'Pacific/Guam',
    venue_name: 'Starfruit Lane Pavilion',
    venue_city: 'Tumon',
    ticket_types: [
      { id: 31, price_cents: 2000, all_in_price_cents: 2220, quantity_remaining: 15, on_sale: true },
    ],
  },
  {
    id: 4,
    slug: 'extra-fourth',
    title: 'Fourth Event Should Not Show',
    starts_at: '2027-03-01T18:00:00+10:00',
    timezone: 'Pacific/Guam',
    venue_name: 'Plaza',
    venue_city: 'Hagåtña',
    ticket_types: [],
  },
]

function Destination() {
  const loc = useLocation()
  return <p>Destination {loc.pathname}</p>
}

const mount = (events = sampleEvents) => render(
  <MemoryRouter>
    <Routes>
      <Route path="/" element={<HeroFannedDeck events={events} />} />
      <Route path="/events" element={<Destination />} />
      <Route path="/events/:slug" element={<Destination />} />
    </Routes>
  </MemoryRouter>,
)

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe('HeroFannedDeck', () => {
  it('renders only the HåfaPass default ticket with no dots or controls when zero events exist', () => {
    reduceMotion(false)
    mount([])
    const deck = screen.getByTestId('hero-fanned-deck')
    expect(deck).toHaveAttribute('data-card-count', '1')
    expect(deck).toHaveAttribute('data-active-index', '0')
    expect(screen.getByTestId('hero-brand-card')).toBeInTheDocument()
    expect(screen.getByTestId('hero-brand-card')).toHaveAttribute('data-brand-variant', '1')
    expect(deck).toHaveTextContent('HåfaPass Guam')
    expect(deck).toHaveTextContent('Tickets for everything happening on Guam')
    const link = within(deck).getByRole('link', { name: /Browse events/i })
    expect(link).toHaveAttribute('href', '/events')
    expect(screen.queryByTestId('hero-deck-controls')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Next featured pass/i })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /^Show / })).not.toBeInTheDocument()
  })

  it('always puts the HåfaPass default ticket first, followed by up to 3 featured events', () => {
    reduceMotion(true)
    mount(sampleEvents)
    const deck = screen.getByTestId('hero-fanned-deck')
    expect(deck).toHaveAttribute('data-card-count', '4')
    expect(deck).toHaveAttribute('data-active-index', '0')
    expect(screen.getByTestId('hero-deck-live')).toHaveTextContent('1 of 4: HåfaPass Guam pass')
    const frontCard = deck.querySelector('[data-front="true"]')
    expect(frontCard).toHaveAttribute('data-card-kind', 'brand')
    expect(deck).not.toHaveTextContent('Fourth Event Should Not Show')
    expect(within(deck).getAllByRole('button', { name: /^Show / })).toHaveLength(4)
  })

  it('supports prev/next buttons, dots, keyboard arrows, and mixed pricing under reduced motion', async () => {
    reduceMotion(true)
    mount(sampleEvents)
    const user = userEvent.setup()
    const deck = screen.getByTestId('hero-fanned-deck')

    await user.click(screen.getByRole('button', { name: 'Next featured pass' }))
    expect(deck).toHaveAttribute('data-active-index', '1')
    expect(screen.getByTestId('hero-deck-live')).toHaveTextContent('2 of 4: Copa de Marianas 2027 (demo)')
    const copaFront = deck.querySelector('[data-front="true"]')
    expect(copaFront).toHaveTextContent('From $11.50')
    expect(copaFront).toHaveTextContent('Free tickets available')

    await user.click(screen.getByRole('button', { name: 'Previous featured pass' }))
    expect(deck).toHaveAttribute('data-active-index', '0')

    await user.click(screen.getByRole('button', { name: /FD Alumni Basketball/i }))
    expect(deck).toHaveAttribute('data-active-index', '2')

    fireEvent.keyDown(deck, { key: 'ArrowRight' })
    expect(deck).toHaveAttribute('data-active-index', '3')

    fireEvent.keyDown(deck, { key: 'ArrowLeft' })
    expect(deck).toHaveAttribute('data-active-index', '2')
  })

  it('reserves stacked skeleton back cards and disabled controls while loading to prevent hero shift', () => {
    reduceMotion(false)
    render(
      <MemoryRouter>
        <HeroFannedDeck events={[]} loading />
      </MemoryRouter>,
    )
    const deck = screen.getByTestId('hero-fanned-deck')
    expect(deck.querySelector('.hero-deck-stage')).toHaveClass('pb-8')
    expect(screen.getAllByTestId('hero-deck-skeleton')).toHaveLength(2)
    expect(screen.getByTestId('hero-deck-controls')).toBeInTheDocument()
    const disabledBtns = within(screen.getByTestId('hero-deck-controls')).getAllByRole('button', { hidden: true })
    expect(disabledBtns.every(btn => btn.disabled)).toBe(true)
  })

  it('keeps back cards opaque (depths 0-2) and only hides depth >= 3 so text never bleeds through', () => {
    reduceMotion(true)
    mount(sampleEvents)
    const deck = screen.getByTestId('hero-fanned-deck')
    const cards = Array.from(deck.querySelectorAll('.hero-deck-card'))
    expect(cards.map(c => [Number(c.dataset.depth), Number(c.style.opacity)])).toEqual([
      [0, 1],
      [1, 1],
      [2, 1],
      [3, 0],
    ])
  })

  it('auto-advances every 6s when motion is allowed, pauses on mouse hover and keyboard focus, and resumes after pointer tap', () => {
    vi.useFakeTimers()
    reduceMotion(false)
    const { unmount } = mount(sampleEvents)
    const deck = screen.getByTestId('hero-fanned-deck')
    expect(deck).toHaveAttribute('data-active-index', '0')
    expect(deck).toHaveAttribute('data-paused', 'false')

    act(() => { vi.advanceTimersByTime(6000) })
    expect(deck).toHaveAttribute('data-active-index', '1')

    // Touch pointerenter must NOT pause hover forever (iOS Safari fix).
    const dispatchPointer = (el, type, pointerType) => {
      const evt = new Event(type, { bubbles: true })
      Object.defineProperty(evt, 'pointerType', { value: pointerType })
      fireEvent(el, evt)
    }
    dispatchPointer(deck, 'pointerover', 'touch')
    expect(deck).toHaveAttribute('data-paused', 'false')

    // Mouse hover pauses auto-advance until pointer leaves.
    dispatchPointer(deck, 'pointerover', 'mouse')
    expect(deck).toHaveAttribute('data-paused', 'true')
    act(() => { vi.advanceTimersByTime(12000) })
    expect(deck).toHaveAttribute('data-active-index', '1')

    dispatchPointer(deck, 'pointerout', 'mouse')
    expect(deck).toHaveAttribute('data-paused', 'false')
    act(() => { vi.advanceTimersByTime(6000) })
    expect(deck).toHaveAttribute('data-active-index', '2')

    // Pointer tap on Next pauses briefly, then auto-resumes after 6s idle.
    const nextBtn = screen.getByRole('button', { name: 'Next featured pass' })
    dispatchPointer(nextBtn, 'pointerdown', 'touch')
    fireEvent.focus(nextBtn)
    fireEvent.click(nextBtn, { detail: 1 })
    expect(deck).toHaveAttribute('data-active-index', '3')
    expect(deck).toHaveAttribute('data-paused', 'true')
    act(() => { vi.advanceTimersByTime(6000) })
    expect(deck).toHaveAttribute('data-paused', 'false')

    // Keyboard focus keeps auto-advance paused until focus leaves the deck.
    fireEvent.keyDown(window, { key: 'Tab' })
    fireEvent.focus(nextBtn)
    expect(deck).toHaveAttribute('data-paused', 'true')
    act(() => { vi.advanceTimersByTime(12000) })
    expect(deck).toHaveAttribute('data-paused', 'true')
    fireEvent.blur(nextBtn, { relatedTarget: document.body })
    expect(deck).toHaveAttribute('data-paused', 'false')
    unmount()

    // Reduced motion disables auto-advance completely.
    reduceMotion(true)
    mount(sampleEvents)
    const reducedDeck = screen.getByTestId('hero-fanned-deck')
    expect(reducedDeck).toHaveAttribute('data-paused', 'true')
    act(() => { vi.advanceTimersByTime(18000) })
    expect(reducedDeck).toHaveAttribute('data-active-index', '0')
  })


  it('restores the visible front after rapid next/previous interruption', () => {
    reduceMotion(false)
    mount()
    fireEvent.click(screen.getByRole('button', { name: 'Next featured pass' }))
    fireEvent.click(screen.getByRole('button', { name: 'Previous featured pass' }))
    const front = screen.getByTestId('hero-fanned-deck').querySelector('[data-front="true"]')
    expect(front.style.opacity).toBe('1')
    expect(front.querySelector('.ticket').style.visibility).toBe('visible')
  })

  it('recovers to an operable brand card when inventory disappears during exit', () => {
    reduceMotion(false)
    const { rerender } = render(<MemoryRouter><HeroFannedDeck events={sampleEvents} /></MemoryRouter>)
    fireEvent.click(screen.getByRole('button', { name: 'Next featured pass' }))
    rerender(<MemoryRouter><HeroFannedDeck events={[]} /></MemoryRouter>)
    const brand = screen.getByTestId('hero-brand-card')
    expect(brand).toBeVisible()
    expect(brand.closest('[data-front]')).toHaveAttribute('data-front', 'true')
    expect(screen.queryByTestId('hero-deck-controls')).not.toBeInTheDocument()
  })

  it('opens the visible event after keyboard Right from the focused brand link', async () => {
    reduceMotion(true)
    const user = userEvent.setup()
    mount()
    screen.getByTestId('hero-brand-card').closest('a').focus()
    await user.keyboard('{ArrowRight}{Enter}')
    expect(screen.getByText('Destination /events/copa-2027')).toBeInTheDocument()
  })

  it('preserves an explicit stop while focus moves elsewhere', () => {
    vi.useFakeTimers()
    reduceMotion(false)
    mount()
    fireEvent.click(screen.getByRole('button', { name: 'Pause event rotation' }))
    fireEvent.blur(screen.getByRole('button', { name: 'Resume event rotation' }), { relatedTarget: document.body })
    act(() => { vi.advanceTimersByTime(24000) })
    expect(screen.getByTestId('hero-fanned-deck')).toHaveAttribute('data-active-index', '0')
  })
})
