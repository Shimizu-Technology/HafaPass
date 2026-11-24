import { act, fireEvent, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import HeroFannedDeck from './HeroFannedDeck'
import BrandVariantSwitcher from './BrandVariantSwitcher'
import { DEFAULT_BRAND_VARIANT, parseBrandVariant } from '../utils/brandVariants'

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
    expect(deck).toHaveTextContent('HåfaPass')
    expect(deck).toHaveTextContent('Your pass to what’s on across Guam')
    const link = within(deck).getByRole('link', { name: /Browse events/i })
    expect(link).toHaveAttribute('href', '/events')
    expect(screen.queryByTestId('hero-deck-controls')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Next featured pass/i })).not.toBeInTheDocument()
    expect(screen.queryByRole('tab')).not.toBeInTheDocument()
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
    expect(within(deck).getAllByRole('tab')).toHaveLength(4)
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

    await user.click(screen.getByRole('tab', { name: /FD Alumni Basketball/i }))
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

  it.each([
    [1, 'HåfaPass · Guam', 'Your pass to', 'what’s on', 'Concerts · Sports · Food · Community'],
    [2, 'Guam · Digital pass', 'HåfaPass', 'Guam’s pass for live events & local nights', 'Island-wide'],
    [3, 'HåfaPass · Guam', 'What’s on', 'across Guam', 'Music · Sports · Markets · Community'],
  ])('renders brand cover variant %i with centered title block, matching ticket body, and Browse events CTA', (variant, pill, line1, line2, detail) => {
    reduceMotion(true)
    render(
      <MemoryRouter>
        <HeroFannedDeck events={sampleEvents} brandVariant={variant} />
      </MemoryRouter>,
    )
    const brandCard = screen.getByTestId('hero-brand-card')
    expect(brandCard).toHaveAttribute('data-brand-variant', String(variant))
    expect(screen.getByTestId('brand-art-frame')).toHaveAttribute('data-brand-variant', String(variant))
    expect(screen.getByTestId('brand-art-pill')).toHaveTextContent(pill)
    const titleBlock = screen.getByTestId('brand-art-title-block')
    expect(titleBlock).toHaveTextContent(line1)
    expect(titleBlock).toHaveTextContent(line2)
    expect(brandCard).toHaveTextContent(detail)
    expect(brandCard).toHaveTextContent('Your pass to what’s on across Guam')
    expect(brandCard).toHaveTextContent('Instant mobile QR tickets')
    expect(brandCard).toHaveTextContent('GU · ADMIT ONE')
    expect(within(brandCard).getByText(/Browse events/i)).toBeInTheDocument()
  })

  it('snaps back to the brand ticket when brandVariant changes', async () => {
    reduceMotion(true)
    const user = userEvent.setup()
    const { rerender } = render(
      <MemoryRouter>
        <HeroFannedDeck events={sampleEvents} brandVariant={1} />
      </MemoryRouter>,
    )
    await user.click(screen.getByRole('button', { name: 'Next featured pass' }))
    expect(screen.getByTestId('hero-fanned-deck')).toHaveAttribute('data-active-index', '1')

    rerender(
      <MemoryRouter>
        <HeroFannedDeck events={sampleEvents} brandVariant={2} />
      </MemoryRouter>,
    )
    expect(screen.getByTestId('hero-fanned-deck')).toHaveAttribute('data-active-index', '0')
    expect(screen.getByTestId('hero-brand-card')).toHaveAttribute('data-brand-variant', '2')
  })

  it('parses ?brand= query params safely and drives the demo BrandVariantSwitcher', async () => {
    expect(parseBrandVariant(null)).toBe(DEFAULT_BRAND_VARIANT)
    expect(parseBrandVariant('invalid')).toBe(DEFAULT_BRAND_VARIANT)
    expect(parseBrandVariant('99')).toBe(DEFAULT_BRAND_VARIANT)
    expect(parseBrandVariant('1')).toBe(1)
    expect(parseBrandVariant('2')).toBe(2)
    expect(parseBrandVariant('3')).toBe(3)

    const onSelect = vi.fn()
    const user = userEvent.setup()
    render(<BrandVariantSwitcher activeVariant={2} onSelect={onSelect} />)
    const nav = screen.getByTestId('brand-variant-switcher')
    const buttons = within(nav).getAllByRole('button')
    expect(buttons).toHaveLength(3)
    expect(buttons[1]).toHaveAttribute('aria-current', 'true')
    await user.click(buttons[2])
    expect(onSelect).toHaveBeenCalledWith(3)
  })
})
